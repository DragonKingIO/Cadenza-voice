# Changelog

What changed in each version, for people who use Cadenza. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).
Each release is also published, with its package and checksum, on
[GitHub Releases](https://github.com/DragonKingIO/Cadenza-voice/releases).

## [Unreleased]

## [1.0.0] - 2026-10-06

The first public build, released as an **early preview**: it is used every day on the maintainer's Mac but has not been tested on
many setups yet.

### Voice input

- Hold a shortcut, speak, and let go: the text is typed at the cursor in the app you are using. If it cannot be typed, it is kept
  so you can copy it.
- Left Option is the default hold key. Right Option, another shortcut (a key with at least two modifiers, or a function key),
  or "tap to start, tap to stop" can be chosen instead.
- Local recognition with SenseVoice (recommended), FireRedASR2 (experimental) and Parakeet (experimental), run by
  sherpa-onnx. Models are downloaded inside the app and checked against their SHA-256 before use.
- "Compare models with my voice": record a sentence and see how each downloaded model transcribes it.
- Apple's built-in speech recognition.
- Optional cloud recognition with your own account: iFLYTEK, Volcengine, Tencent Cloud, Alibaba Cloud, Baidu and Deepgram.
  Audio is sent only after you agree for that provider; if the network fails, a local model can take over.

### Screenshots and text recognition (new, still being tested)

- Capture an area or a window, mark it up with ten editable tools, pin it on screen, save or copy it.
- Recognize the text and QR codes in the picture. Apple Vision, locally, by default; Baidu, Tencent Cloud and Google Cloud
  Vision are optional, with your own keys and per-provider consent.

### For developers and hardware

- An optional local API on `127.0.0.1`, off by default: start and stop recordings, send audio from your own device, receive text,
  and, if you allow it, type the result into the front app. Each device gets its own revocable token and permissions.

### Privacy

- No account, no server, no analytics, no crash reports. Recordings and transcripts are not written to disk or to logs. Keys
  live in the macOS Keychain. A "never go online" switch hides everything that could connect.
- Update check: only when you press "Check for updates", or once a week if you agree to it. It reads GitHub's public release
  information and never downloads or installs anything by itself.

### Known limitations

- Not notarized. A downloaded copy needs System Settings → Privacy & Security → **Open Anyway** the first time, and macOS asks
  for its permissions again after each update.
- macOS 26 or later on Apple silicon only.
- Compatibility with every app is not verified. Of the cloud providers, only iFLYTEK and Deepgram were tested online, with
  synthesized speech; the others were tested against recorded request shapes. Screenshot capture has not yet been checked by a
  person on more than one Mac and display setup.
- Interface languages: English and Simplified Chinese.

### If you used a development build

- The internal identifiers changed from the old name to Cadenza (Bundle ID `local.cadenza.app`, Keychain service and support
  folder `Cadenza`). The first launch moves your settings, models and saved keys across; macOS may ask once to read the old
  keys, and the permissions must be granted again.

[Unreleased]: https://github.com/DragonKingIO/Cadenza-voice/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/DragonKingIO/Cadenza-voice/releases/tag/v1.0.0
