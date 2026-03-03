import Foundation
import Network

/// Minimal HTTP server that serves an OpenAI-compatible chat completions API
class HTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    private weak var llamaState: LlamaState?

    var isRunning: Bool { listener != nil }

    init(port: UInt16 = 8080) {
        self.port = port
    }

    func start(llamaState: LlamaState) throws {
        self.llamaState = llamaState
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.start(queue: .global(qos: .userInitiated))
        print("HTTP Server started on port \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        print("HTTP Server stopped")
    }

    func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            self.routeRequest(request, connection: connection)
        }
    }

    private func routeRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Bad Request\"}")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Bad Request\"}")
            return
        }

        let method = parts[0]
        let path = parts[1]

        // CORS headers for all responses
        if method == "OPTIONS" {
            sendResponse(connection: connection, status: "200 OK", body: "", extraHeaders: [
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET, POST, OPTIONS",
                "Access-Control-Allow-Headers: Content-Type, Authorization"
            ])
            return
        }

        switch path {
        case "/":
            sendResponse(connection: connection, status: "200 OK", body: "Crucible LLM Server is running")
        case "/v1/models", "/api/tags":
            handleModels(connection: connection)
        case "/v1/chat/completions":
            if method == "POST" {
                handleChatCompletion(request: request, connection: connection)
            } else {
                sendResponse(connection: connection, status: "405 Method Not Allowed", body: "{\"error\":\"Method Not Allowed\"}")
            }
        default:
            sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Not Found\"}")
        }
    }

    private func handleModels(connection: NWConnection) {
        let response = """
        {"object":"list","data":[{"id":"local","object":"model","created":0,"owned_by":"local"}]}
        """
        sendResponse(connection: connection, status: "200 OK", body: response, contentType: "application/json")
    }

    private func handleChatCompletion(request: String, connection: NWConnection) {
        // Extract JSON body from HTTP request
        guard let bodyStart = request.range(of: "\r\n\r\n")?.upperBound else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"No body\"}", contentType: "application/json")
            return
        }

        let bodyString = String(request[bodyStart...])
        guard let bodyData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Invalid JSON\"}", contentType: "application/json")
            return
        }

        // Build prompt using ChatML format (works with Qwen, Gemma, most chat models)
        var prompt = ""
        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            let content = msg["content"] as? String ?? ""
            prompt += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"

        let maxTokens = json["max_tokens"] as? Int ?? 500

        // Run inference on a background thread
        Task {
            guard let llamaState = await self.llamaState else {
                self.sendResponse(connection: connection, status: "500 Internal Server Error",
                                  body: "{\"error\":\"No model loaded\"}", contentType: "application/json")
                return
            }

            let result = await llamaState.completeForAPI(text: prompt, maxTokens: maxTokens)

            let responseJSON: [String: Any] = [
                "id": "chatcmpl-\(UUID().uuidString.prefix(8))",
                "object": "chat.completion",
                "created": Int(Date().timeIntervalSince1970),
                "model": "local",
                "choices": [[
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": result
                    ],
                    "finish_reason": "stop"
                ]]
            ]

            if let jsonData = try? JSONSerialization.data(withJSONObject: responseJSON),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                self.sendResponse(connection: connection, status: "200 OK", body: jsonString, contentType: "application/json")
            } else {
                self.sendResponse(connection: connection, status: "500 Internal Server Error",
                                  body: "{\"error\":\"Failed to serialize response\"}", contentType: "application/json")
            }
        }
    }

    private func sendResponse(connection: NWConnection, status: String, body: String,
                              contentType: String = "text/plain", extraHeaders: [String] = []) {
        var headers = "HTTP/1.1 \(status)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(body.utf8.count)\r\n"
        headers += "Access-Control-Allow-Origin: *\r\n"
        headers += "Connection: close\r\n"
        for header in extraHeaders {
            headers += "\(header)\r\n"
        }
        headers += "\r\n"

        let responseData = (headers + body).data(using: .utf8)!
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
