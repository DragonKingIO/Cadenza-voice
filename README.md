<p align="center">
  <img src="cadenza/docs/branding/social-preview/cadenza-en.png" alt="Cadenza: Speak where you type" width="720">
</p>

# Cadenza · 随言

**Speak where you type.** Open-source voice typing for macOS that runs on your Mac.

[简体中文](README.zh-CN.md) · [Website and documentation](https://dragonkingio.github.io/cadenza-site/)

<!-- Intro video: when it exists, put a poster image that links to it here (hosting advice: cadenza/docs/MEDIA.md). -->

Hold a shortcut, speak, release. Cadenza recognizes your speech and types the text where your cursor is. By default
recognition happens **on this Mac** with a local model; nothing is uploaded unless you choose a cloud service and agree to
it. If the text cannot be typed, the app keeps it so you can copy it.

> **Status: early development.** It works day to day on the maintainer's Mac, but it has not been tested on many setups.
> Compatibility with every app is not verified. Bug reports are very welcome.

## Why Cadenza

- **Private by design.** No account, no server, no analytics, no crash reporting. Audio stays on this Mac with local
  recognition. Cloud services receive audio only after your explicit consent for that provider. Service keys live in the
  macOS Keychain. A "never go online" switch hides everything that could connect.
- **Local models you can compare.** SenseVoice (recommended), FireRedASR2 and Parakeet run through
  [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), downloaded inside the app with checksum verification. "Compare
  models with my voice" lets you pick the one that suits your voice. Recordings stay in memory.
- **Bring your own cloud service, optionally.** iFLYTEK, Volcengine, Tencent Cloud, Alibaba Cloud, Baidu and Deepgram, with
  your own credentials. When the network fails, recognition can continue with a local model.
- **Works with hardware.** An optional, off-by-default API on `127.0.0.1` lets your own pendant, glasses or button send audio
  and receive text. See [Local API](cadenza/docs/LOCAL-API.md) and
  [hardware integration](cadenza/docs/HARDWARE-INTEGRATION.md).
- **Open and measured.** Accuracy changes are justified with a repeatable benchmark ([ACCURACY.md](cadenza/docs/ACCURACY.md)).
- English and Simplified Chinese interface.

## See it

Everything below is the real settings window.

**Choose where recognition happens.** Local models run on your Mac and nothing is uploaded. "Compare models with my voice"
appears once a model is downloaded.

<p align="center"><img src="cadenza/docs/images/settings-local-en.png" alt="Settings, Local models tab: SenseVoice (recommended), FireRedASR2 and Parakeet" width="640"></p>

**Tune it.** Language, number formatting, voice-detection sensitivity and CPU use, all processed on this Mac.

<p align="center"><img src="cadenza/docs/images/settings-tuning-en.png" alt="Settings, Recognition settings tab" width="640"></p>

## Install

There is no release yet. Build it yourself; it takes a few minutes and needs macOS 26 on Apple silicon with the Xcode
Command Line Tools:

```sh
git clone https://github.com/DragonKingIO/Cadenza-voice.git && cd Cadenza-voice
./cadenza/tools/fetch-sherpa-onnx.sh     # optional: the library for local models
./cadenza/build.sh --stage-only          # creates cadenza/build/stage.noindex/Cadenza.app.zip
```

Unzip it and open the app. A copy you built yourself opens normally. Releases you download are signed ad hoc and not
notarized, so macOS blocks the first launch: open System Settings → Privacy & Security, scroll to the message about the app and
choose **Open Anyway** (since macOS 15, right-click → Open no longer bypasses this). Because each ad hoc build is a new
identity, macOS asks again for the permissions below after you rebuild or update. Full instructions:
[Developing Cadenza](cadenza/docs/DEVELOPING.md).

**Platforms:** macOS 26 or later on Apple silicon only. See [Platforms](cadenza/docs/PLATFORMS.md) for why, and what could be
reused for a port.

| Permission | Why |
|---|---|
| Microphone | Capture speech while you record |
| Accessibility | Find the text field and type the result |
| Input Monitoring | Detect the global shortcut |
| Speech Recognition | Only if you use Apple's built-in recognition |

## What is and is not verified

Local recognition with SenseVoice is exercised with a benchmark and in daily use. Cloud providers other than iFLYTEK and
Deepgram have only been tested with fake transports, and iFLYTEK and Deepgram only with synthesized speech. A protocol
implementation does not promise that your account, region or plan will work. Provider names are descriptive labels, not
endorsements, and Cadenza is not affiliated with them.

## Privacy

Read the [privacy notice](cadenza/PRIVACY.md) and [terms](cadenza/TERMS.md). Logs hold state, errors and text lengths; the
code does not write audio or transcripts to them, and you can turn logging off.

## Contributing

Everyone is welcome: code, documentation, model evaluations on your own voice, and bug reports. Start with
[CONTRIBUTING.md](CONTRIBUTING.md) and the [development guide](cadenza/docs/DEVELOPING.md). Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md), and report security problems privately as described in [SECURITY.md](SECURITY.md).
Naming rules are in [BRAND.md](BRAND.md).

## License

[MIT](cadenza/LICENSE). Third-party components and models are listed in
[THIRD_PARTY_NOTICES.md](cadenza/THIRD_PARTY_NOTICES.md).
