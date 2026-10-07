# Changelog

What changed in each version, for people who use Cadenza. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).
Each release is also published, with its package and checksum, on
[GitHub Releases](https://github.com/DragonKingIO/Cadenza-voice/releases).

## [Unreleased]

## [1.1.0] - 2026-10-07

Still an **early preview**.

### Compatibility
- One package for Apple silicon **and Intel** Macs, and the minimum system is now **macOS 14** (it was macOS 26). Where an interface exists only on newer systems, the app uses a plain alternative: the round trial button has an ordinary disc instead of Liquid Glass before macOS 26, and menu subtitles are appended to the item title before macOS 14.4.
- Verified: the whole self-test suite on Apple silicon with macOS 26, and the Intel half of the package under Rosetta (except Apple Vision text recognition, which Rosetta cannot run). **Not yet verified on a real Intel Mac or on macOS 14 and 15.**

### Recording bar
- The bar is see-through glass in light mode, and matches the Settings preview in dark mode.
- An optional character style (Settings) shows a short animation for writing, thinking, alerts and errors instead of the waveform. The animations were made with Dots Lab by Guillaume and are used with the author's permission; they are not covered by the MIT license (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).

### Text recognition
- On-device recognition models: download, select and delete a PP-OCR model set in Settings → Text Recognition, like the speech models. It runs through the onnxruntime library that is already linked, reads Chinese and English text lines, and falls back to Apple Vision when it cannot run. Two sets are built in: PP-OCRv5 mobile (about 21.5 MB, recommended) and the earlier PP-OCRv4 mobile (about 15.6 MB), which can miss the spaces between English words.

### Fixed
- Cancelling a model download no longer leaves an empty staging folder behind.

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

[Unreleased]: https://github.com/DragonKingIO/Cadenza-voice/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/DragonKingIO/Cadenza-voice/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/DragonKingIO/Cadenza-voice/releases/tag/v1.0.0
