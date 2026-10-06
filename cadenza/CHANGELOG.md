# Changelog

This file follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). No public v0.1.0 release has been verified in this checkout.

## [Unreleased]

### Added

- Screenshot and text recognition: ten editable mark-up tools, eight-swatch colour row, colour loupe, QR codes, pin windows, and a separate Text Recognition page (Apple Vision, or Baidu / Tencent / Google Cloud Vision with your own keys and per-provider consent, falling back to the Mac).
- Isolated trigger state machine with an injected clock and 37 passing deterministic tests. It is not integrated into the application.
- English and Simplified Chinese documentation, brand rules, contribution guidelines, and localization drafts for a later integration stage.

### Changed

- The settings tab "Engines" is now "Speech" (语音识别) so it is not confused with "Text Recognition" (文字识别).
- Documentation distinguishes implemented provider protocols from live-service acceptance, and records consent and privacy verification limits.
