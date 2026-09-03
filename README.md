# GroqVoice

Push-to-talk dictation for macOS. Hold a key, speak, release — the text lands in whatever
you were typing in. Speech is recognized **on the Mac itself** (NVIDIA Parakeet TDT v3 via
[FluidAudio](https://github.com/FluidInference/FluidAudio), CoreML / Neural Engine), so it
works offline, needs no account and answers in a fraction of a second. Russian, English,
Latvian and 22 more languages, mixed within one phrase.

Optional: a second key that pastes a **translation** of what you said, an LLM **task mode**
("задание: переведи это на английский…"), transcript clean-up, and Whisper via
[Groq](https://groq.com) as an alternative cloud engine. LLM features run against Groq or
any OpenAI-compatible server (Ollama on the same Mac included).

→ **[macos/README.md](macos/README.md)** — features, settings, vocabulary, build & install.

```bash
cd macos && ./build-app.sh && ditto GroqVoice.app /Applications/GroqVoice.app && open /Applications/GroqVoice.app
```

Requires macOS 14+ on Apple Silicon and the Xcode Command Line Tools to build.

## Windows

This repository started as a fork of [abirzgals/GroqVoice](https://github.com/abirzgals/GroqVoice),
a Windows tray app doing the same job through the Groq API. The C# sources in the repository
root are that app, kept as upstream left them; see the upstream README for Windows downloads
and documentation.

## License

MIT
