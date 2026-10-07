<p align="center">
  <img src="cadenza/docs/branding/social-preview/cadenza-en.png" alt="Cadenza: Speak where you type" width="640">
</p>

<p align="center">
  <b>Speak where you type.</b><br>
  Open-source voice input for macOS. Recognition runs locally.
</p>

<p align="center">
  <a href="https://dragonkingio.github.io/cadenza-site/">Website</a> ·
  <a href="https://dragonkingio.github.io/cadenza-site/getting-started/">Documentation</a> ·
  <a href="https://dragonkingio.github.io/cadenza-site/download/">Download</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-MIT-185c53" alt="License: MIT">
  <img src="https://img.shields.io/badge/macOS-26%2B-185c53" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Apple%20silicon-only-185c53" alt="Apple silicon only">
  <img src="https://img.shields.io/badge/status-early%20preview-3fa597" alt="Status: early preview">
</p>

<!-- Intro video: drag the MP4 into a GitHub issue/PR comment box to get a user-attachments URL, then put it on its own line here. Never commit the MP4 (cadenza/docs/MEDIA.md). -->

Hold a key (Left Option by default), speak, and let go: the text appears where your cursor is. Many voice input services
upload every recording to the vendor's servers. Cadenza recognizes speech locally by default, and because it is open
source, anyone can check what leaves your computer.

## Features

- **Local by default.** SenseVoice (recommended), FireRedASR2 and Parakeet run locally through
  [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). Models are downloaded inside the app and checked. "Compare models
  with my voice" shows which one understands you best.
- **Your own cloud service, if you want one.** iFLYTEK, Volcengine, Tencent Cloud, Alibaba Cloud, Baidu and Deepgram, with
  your own keys. Audio is sent only after you agree, provider by provider. If the network fails, a local model can take over.
- **Screenshots and text recognition** *(new, still being tested)*. Capture an area, mark it up or pin it on screen, and copy
  the text or QR code inside. Apple Vision reads the text locally by default.
  [More](cadenza/docs/SCREENSHOT.md)
- **For developers and AI hardware.** An optional local API on `127.0.0.1` (off by default) lets your own programs, pendants or
  glasses send audio and get text back, with a separate, revocable token per device.
  [Local API](cadenza/docs/LOCAL-API.md) · [Hardware integration](cadenza/docs/HARDWARE-INTEGRATION.md)
- **Private by design.** No account, no server, no analytics, no crash reports. Recordings and transcripts are not written to
  disk or to logs; keys live in the macOS Keychain. A "never go online" switch hides everything that could connect.
- **Measured.** Changes to recognition are justified with a repeatable benchmark. [Accuracy](cadenza/docs/ACCURACY.md)

## Get started

There is no release yet, so build it yourself. It takes a few minutes and needs macOS 26 or later on Apple silicon, with the
Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/DragonKingIO/Cadenza-voice.git && cd Cadenza-voice
./cadenza/tools/fetch-sherpa-onnx.sh     # the library for local models
./cadenza/build.sh --stage-only          # creates cadenza/build/stage.noindex/Cadenza.app.zip
```

Unzip it, open the app, and allow the permissions it asks for:

| Permission | Why |
|---|---|
| Microphone | Capture your voice while you record |
| Accessibility | Type the result into the text field |
| Input Monitoring | Detect the global shortcut |
| Speech Recognition | Only for Apple's built-in recognition |
| Screen & System Audio Recording | Only for screenshots |

A copy you built yourself opens normally. Releases will be signed ad hoc and **not notarized** (the project has no budget for an
Apple Developer ID), so macOS blocks the first launch of a downloaded copy: open System Settings → Privacy & Security and choose
**Open Anyway**. Next steps: [Getting started](https://dragonkingio.github.io/cadenza-site/getting-started/) ·
[Development guide](cadenza/docs/DEVELOPING.md).

## Status

Early preview. It is used every day on the maintainer's Mac but has not been tested on many setups, and compatibility with
every app is not verified. Local recognition with SenseVoice is covered by the benchmark and daily use. Of the cloud providers,
iFLYTEK and Deepgram were tested online with synthesized speech; the others only with fake transports. Provider names are
descriptive labels, not endorsements, and Cadenza is not affiliated with them. Only macOS is supported
([why](cadenza/docs/PLATFORMS.md)); ports are welcome as separate projects.

## Contributing

Code, documentation, translations, model evaluations on your own voice and bug reports are all welcome. Start with
[CONTRIBUTING.md](CONTRIBUTING.md). Every change is reviewed against the privacy contract described there. Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md), and report security problems privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](cadenza/LICENSE). Privacy notice: [PRIVACY.md](cadenza/PRIVACY.md) · Terms: [TERMS.md](cadenza/TERMS.md) ·
Third-party components and models: [THIRD_PARTY_NOTICES.md](cadenza/THIRD_PARTY_NOTICES.md).
