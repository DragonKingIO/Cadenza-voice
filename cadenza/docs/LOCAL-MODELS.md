# Local models — developer notes

Users download, select and delete models in **Settings → Speech → Local**. Models are never bundled. This file covers how it fits together, how to host an update list, and how to add a model.

## Pieces

| File | Role |
|---|---|
| `src/LocalModelCatalog.swift` | Data types, the built-in list, validation of untrusted lists, signature check, language pick |
| `src/LocalModelDownloader.swift` | One-file resumable download (`.part` + `Range`, several mirrors), `tar` extraction with path/link checks |
| `src/LocalModelCenter.swift` | State machine: download → verify (SHA-256) → unpack → load check → atomic activate; delete, rollback, import, update check |
| `src/LocalASR.swift` | Recognizer protocol, sherpa-onnx bridge (`#if LOCAL_SHERPA`), recognizer cache with idle unload, local recording session |
| `src/FallbackRecordingSession.swift` | Policy, network state, cloud-then-local session |
| `src/LocalModelsView.swift` | SwiftUI page |
| `src/LocalModelFixtures.swift` | Self-tests (`--selftest-local-model`, `--selftest-local-model-real`) |

## Build

`tools/fetch-sherpa-onnx.sh` downloads the pinned sherpa-onnx static library and C header (both SHA-256 checked) into `third_party/sherpa-onnx` (git-ignored). `build.sh` links it when present (`-D LOCAL_SHERPA`); otherwise the app builds without local inference and the Local page says so. This is the inference library only — no model is fetched.

## On disk

```
~/Library/Application Support/Cadenza/models/
  installed.json                      id → {version, previous, installedAt}
  remote-manifest.json                last verified update list (cache)
  <id>-<version>/                     one directory per version; current + previous are kept
  .downloads/<id>-<version>/          resumable staging (*.part, finished files)
```

Activation moves a fully built `<id>-<version>.tmp` into place and then rewrites `installed.json` atomically, so an interrupted install never changes the current version. A new version first has to load (the `validator`) before it is activated. If a version later fails to load at use time, `LocalTranscriberCache` rolls back to the previous version once.

## Update list (`models-manifest.json`)

See `docs/models-manifest.example.json`. Fields that affect safety are mandatory: `files[].urls` (https only), `sha256`, `size`, `required_files`. Descriptive fields default if missing. `platforms` (optional, e.g. `["macos","windows"]`; empty or missing = every platform) lets one list serve several clients — a client shows only entries that list its own platform, so a future Windows build can reuse the same list, models and sherpa-onnx C API. `min_app_version` hides entries a given app version should not install; `kind` selects the runner (`sensevoice` or `parakeet-tdt`).

1. Host the list and the model files over HTTPS (your own CDN first, upstream second in `urls`).
2. `swift tools/manifest-tool.swift hash <file>` gives the size and SHA-256 for each file.
3. `swift tools/manifest-tool.swift keygen private.key` once; put the printed public key in `LocalModelCatalog.manifestPublicKeys`. From then on lists must carry a valid `models-manifest.json.sig` (`... sign private.key models-manifest.json`). With no key configured, lists are accepted unsigned — set a key before publishing a list for others.
4. Set `LocalModelCatalog.defaultManifestURLs`, or users can paste a URL under Settings → Local → Updates.

Update checking downloads only this small list. A new version appears as an **Update** button; nothing is downloaded until the user taps it.

## Adding a model family

1. Add the family to `LocalModelCatalog.supportedKinds` and to `LocalTranscriberLoader.load`.
2. Implement `LocalTranscriber` (see `SherpaOfflineTranscriber`; sherpa-onnx's C API has configs for transducer/Whisper/Paraformer models).
3. Add entries to the list. Run `--selftest-local-model-real` against the installed model.

## Tests

```bash
"/Applications/随言.app/Contents/MacOS/Cadenza" --selftest-local-model
"/Applications/随言.app/Contents/MacOS/Cadenza" --verify-local-models
# Explicit download acceptance (uses the same production downloader and installer):
"/Applications/随言.app/Contents/MacOS/Cadenza" --verify-local-models --download-models
```
The fixture suite uses a loopback HTTP server with Range and fault injection, generated archives and fake recorders. Acceptance downloads only when explicitly requested, verifies the pinned size and SHA-256, loads both real models, and measures generated speech recognition (WER/CER), quiet generated speech, long paused speech, silence and synthetic noise. A missing model or failed synthesis is a failure, not a passing skip. Acceptance uses no microphone, Keychain credential, cloud audio request, insertion or clipboard. Generated samples are temporary and removed afterward. The English UI model test is a smaller smoke test, not comprehensive microphone acceptance.

## Known limits

- Two model families are runnable: SenseVoice and NeMo Parakeet TDT (transducer). Real-model acceptance must be reported from the latest run; mock tests alone do not prove either family works. Whisper and streaming (online) models need their own runners.
- Manual import is a fallback only (shown after a failed download and on the Developer page). Files must match a list entry by SHA-256.
- Decoding is offline: the live preview re-decodes the last ≤25 s every ~1.5 s; the final text uses VAD-selected speech for short and long recordings, with 200 ms context at the boundaries and inference chunks bounded to 25 s. Silence or unconfirmed speech returns no text. The 15-minute local recording limit automatically ends the recording instead of silently dropping audio.
- A loaded model uses roughly 0.5 GB RAM; it is released after 5 idle minutes.
- Fallback keeps at most 120 s of audio; a longer recording that then fails in the cloud is reported as a cloud failure.

## Recognition and fallback options

- SenseVoice language and ITN (number formatting) use the upstream recognizer options. Parakeet detects its supported languages; these two SenseVoice options do not alter Parakeet.
- VAD threshold and CPU threads are saved with the local settings. Changing recognition options invalidates the cached recognizer. No claim of measured accuracy improvement is made without a before/after corpus measurement.
- Cloud fallback derives languages from the selected provider, not from an unrelated provider's settings. Every required language must be covered; an incompatible explicit fallback is replaced by a compatible installed model, or fallback is unavailable.
- Final-decoding cancellation invalidates delivery. Successful completion releases the in-memory fallback audio; it is never saved as a recording.
- Local word mappings remain post-recognition replacements shared with cloud recognition, not a model hotword API. Protected replacements and URL/code behavior use the existing correction policy.
- Actual microphone quality, far speech, keyboard/fan noise, focus insertion and the full advertised language set need separate acceptance. Synthetic speech error rates are small test-case results, not general model accuracy.

The pipeline gives bounded extra time to local final decoding for long recordings. VAD-confirmed local text is not discarded by the legacy fixed display-level threshold, and an empty local final result never substitutes a stale preview. Both the engine selection and the active model badge use the same primary-model policy.

## Built-in models

| Model | Kind | Languages | Download | Status |
|---|---|---|---|---|
| East Asian languages (SenseVoice) | `sensevoice` | zh, en, ja, ko, yue | about 164 MB | Recommended default, verified on synthesized and speaker-to-microphone speech |
| High-accuracy Chinese (FireRedASR2) | `fire-red-ctc` | zh, en | about 521 MB | Experimental. Installed and run with the real package (`model.int8.onnx`, `tokens.txt`, `silero_vad.onnx` as expected). On the synthesized-speech benchmark its character error rate matches SenseVoice (10.6% vs 10.0%), but it writes no punctuation, keeps spoken numbers as words, and decodes about four times slower. Use "Compare models with my voice" to check it on your own speech |
| European languages (Parakeet TDT v3) | `parakeet-tdt` | 25 European languages | about 488 MB | Experimental |

Automatic selection never depends on install order: among installed models for the language, the recommended one wins.
A model the user picked explicitly ("Use") is always honoured. To compare models on the same sentences, run
`Cadenza --local-accuracy-probe` (developer tool; uses the system voice, so it isolates the model, not the microphone).
