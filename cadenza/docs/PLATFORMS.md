# Platforms

**Cadenza runs on macOS 26 or later, on Apple silicon. That is the only supported platform**, and the project does not plan
to add Windows or Linux itself in the near term.

## Why only macOS

The product is the hold-to-talk experience: a global shortcut, a menu bar item, finding the focused text field and typing
into it, and storing credentials safely. All of it is built on macOS-only APIs (AppKit and SwiftUI, the Accessibility API,
CGEvent, the Keychain, AVAudioEngine). Rewriting that for another system is a new application, not a recompile.

## What is reusable

| Piece | Where | Notes |
|---|---|---|
| Local speech models and the inference library | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Runs on Linux, Windows and macOS. The model list, sizes and checksums are in `docs/models-manifest.example.json`. |
| Trigger state machine | `cadenza/trigger-state-machine/` | A dependency-free Swift package with its own tests; today it declares macOS only, but it imports nothing platform specific. |
| Accuracy benchmark idea | `docs/ACCURACY.md`, `src/AccuracyBenchmark.swift` | Corpus, conditions and character error rate scoring, easy to reimplement. |
| Cloud provider wire formats | `src/ASRWire.swift` and the provider files | Documented protocols (WebSocket or HTTP). |
| Local API protocol | `docs/LOCAL-API.md` | Loopback only today, so a client must run on the same Mac. Network access for other devices is only a plan, not built. |

## What a port would need

- **Windows:** a low-level keyboard hook for the global shortcut, text insertion with `SendInput` or UI Automation, a tray
  icon, Credential Manager, WASAPI audio.
- **Linux:** PipeWire audio, a global shortcut (easy on X11, no general mechanism on Wayland), and text insertion. On
  Wayland the realistic route is an input method framework (IBus or fcitx5) rather than synthetic key events.

## If you want to build a port

Ports are welcome **as separate projects** that reuse the pieces above. Open a "Feature request" issue to tell us, so that
we can link it from the README. The Cadenza maintainers cannot promise to maintain or test a port. The privacy contract in
[CONTRIBUTING.md](../../CONTRIBUTING.md) is a good baseline for any of them.
