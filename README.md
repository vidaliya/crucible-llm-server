# CrucibleLLM

Run custom GGUF language models locally on iPad and iPhone. Serve them through an OpenAI-compatible HTTP API. No cloud, no subscription, no data leaves your device.

## Features

- **Local inference** — runs GGUF models on-device with Metal GPU acceleration via llama.cpp
- **OpenAI-compatible API** — serves `/v1/chat/completions` so any client that speaks OpenAI can talk to your iPad
- **HuggingFace downloads** — browse and download models directly in the app
- **Server mode** — toggle the HTTP server on/off, see your IP and port in the UI
- **Default models** — ships with Gemma 3 4B and Qwen 3.5 4B in the download list
- **Zero cloud** — your model, your device, your data

## Quick Start

1. Sideload `CrucibleLLM.ipa` via [AltStore](https://altstore.io/) or [AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux)
2. Open the app, go to **View Models**, download a model (or paste a HuggingFace GGUF URL)
3. Tap the model to load it
4. Tap **Start Server**
5. The app shows your IP and port — you're serving

## API Usage

```bash
curl http://YOUR_IPAD_IP:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [
      {"role": "system", "content": "Be concise."},
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "max_tokens": 100
  }'
```

Works with any OpenAI-compatible client — point it at `http://YOUR_IPAD_IP:8080` as the base URL.

## Building from Source

The app builds on GitHub Actions using a macOS runner with Xcode:

1. Fork this repo
2. Push to trigger the `Build iOS IPA` workflow
3. Download the IPA artifact from the Actions run
4. Sideload to your device via AltStore

The workflow builds the llama.cpp xcframework from source, then compiles the iOS app. No local macOS machine needed.

## Known Limitations

- **Memory pressure** — iPads with 8GB RAM can crash on long prompts with large models. Use Q4_K_M quantization and keep context sizes reasonable.
- **Foreground only** — iOS suspends background apps. The server only works while the app is in the foreground with the screen on.
- **Single request** — inference is single-threaded. Concurrent API requests queue behind the active one.

## Architecture

- Swift + SwiftUI frontend
- llama.cpp via xcframework for inference (Metal-accelerated)
- Network.framework HTTP server (no external dependencies)
- ChatML prompt formatting with `/no_think` support for reasoning models

## Created By

[Crucible](https://github.com/vidaliya) — built on a Tuesday because we needed an iOS Ollama and nobody had made one.

## License

MIT
