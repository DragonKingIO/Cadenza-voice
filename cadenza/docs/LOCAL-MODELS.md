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

`tools/fetch-sherpa-onnx.sh` downloads the pinned sherpa-onnx static library and C header (both SHA-256 checked) into `third_party/sherpa-onnx` (git-ignored). `build.sh` links it when present (`-D LOCAL_SHERPA`); otherwise the app builds without local inference and the Local page says so. This is the inference library only — no model is fetched. The same script also fetches the pinned onnxruntime C API headers (SHA-256 checked, git-ignored); with them `build.sh` adds `-D LOCAL_ORT`, which the on-device text recognition models need (see `docs/SCREENSHOT.md`).

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
| Chinese with English words, fastest (Paraformer) | `paraformer` | zh, en | about 244 MB | Experimental. DAMO's Paraformer-large int8 from Hugging Face (file checksums published by the host). Fastest of the Chinese models, no punctuation. Installed and read with the real files. |
| Most accurate in our tests, multilingual (Qwen3-ASR) | `qwen3-asr` | zh, en, yue, ja, ko and more | about 879 MB | Experimental. Qwen3-ASR 0.6B int8 (ONNX export by Wasser1462, sherpa-onnx release). Writes punctuation, about a second for a short sentence, the first install takes a minute or two. Installed and read with the real files. |

The benchmark below was run with `--accuracy-benchmark --bench-quick` on the same 105 synthesized clips per model (several system voices, seven conditions; Chinese sentences, a few with English words), character error rate, lower is better. Synthesized speech is cleaner than a person, the mixed-language group is only a few sentences, and the numbers say nothing about other languages, so treat it as a comparison on identical audio, not a ranking for every voice:

| Model | Overall | Chinese with English words | Time for the 105 clips (4 at a time) |
|---|---|---|---|
| Qwen3-ASR 0.6B int8 | 0.8% | 0.0% | 81 s |
| Paraformer-large int8 | 1.8% | 20.0% | 9 s |
| SenseVoice (recommended default) | 2.0–2.2% | 24.8% | fast |
| FireRedASR2 CTC | 2.5% | 33.3% | 52 s |

### Speed and memory (shown in the model list)

Every built-in model carries a `profile` in the model list (`LocalModelProfile`), and the Settings page prints it under the model as one line, for example "Speed: fast · 10 s of speech takes about 0.6 s · about 594 MB of memory · with punctuation". The numbers come from `Cadenza --bench-speed --bench-model=<kind>:<folder>`, run once per model in its own process (memory that was used does not shrink): load time, then three timed runs of each of five synthesized sentences of 4.6–7.2 s after one warm-up, 2 threads, on one Apple silicon Mac. The speed word follows the real-time factor: under 0.10 fast, under 0.20 medium, otherwise slow. Memory is the whole app's resident size after loading and using the model, so it includes about 26 MB for the app itself.

| Model | Load | Memory | 10 s of speech takes | Punctuation |
|---|---|---|---|---|
| Paraformer-large int8 | 0.5 s | 557 MB | 0.5 s | no |
| SenseVoice int8 | 0.4 s | 594 MB | 0.6 s | yes |
| Parakeet TDT v3 int8 (English clips) | 0.8 s | 1.2 GB | 1.2 s | yes |
| Qwen3-ASR 0.6B int8 | 1.4 s | 1.8 GB | 2.4–2.8 s | yes |
| FireRedASR2 CTC int8 | 0.7 s | 1.3 GB | 3.1 s | no (English comes out in capitals) |

For the text recognition sets, one line of text takes about 30 ms (17–36 ms for the three test pictures) and the app holds about 142 MB with PP-OCRv5 and 113 MB with PP-OCRv4. Re-measure and update the `profile` when a model or the recognizer changes; the values are data, not behaviour, so they never affect how a model runs.

Models that are not installed can be compared with `--bench-model=<kind>:<folder>` (repeatable), e.g. `--bench-model=paraformer:/path/to/folder`.
`Cadenza --selftest-local-model-download=<id>` downloads one built-in speech model with the app's own downloader into a temporary folder,
loads it, reads two synthesized sentences and deletes it again; with `CADENZA_MODEL_IMPORT=<file>,<file>` it installs files you already have.

Automatic selection never depends on install order: among installed models for the language, the recommended one wins.
A model the user picked explicitly ("Use") is always honoured. To compare models on the same sentences, run
`Cadenza --local-accuracy-probe` (developer tool; uses the system voice, so it isolates the model, not the microphone).

## Compare with your own voice

Settings → Speech → Local models → "Compare models with my voice" records a few sentences in memory and runs them through
every way of recognizing that is set up: installed local models that cover the app's language, cloud services that have saved
credentials **and** upload consent (`CompareCandidates.cloudReady`), and the Mac's built-in recognizer when it can run on the
device. Anything not downloaded or not configured is not listed. Cloud services receive the recordings only while ticked and
are marked "Uploads recording"; the app locked to local recognition lists none. A cloud service runs through the same
recorder as a real dictation (`CloudClipTranscriber`), so a failure (no network, rejected credentials, no answer in 30 s) is
shown as a failure, never as a 100% error rate. For cloud services the time column is the wait after the audio ends, not
decoding time.

## Do the models already leave out hesitation sounds?

`Cadenza --bench-fillers` speaks nine sentences that contain "呃", "嗯", "那个", stutters and English "um", "uh", "like" with the
system voices, has each installed local model write them, and shows what the "Tidy the text" step (Standard and Thorough) changes.
Synthetic voices say fillers more cleanly than people do, so the figures are a lower bound. Measured on one Mac:

| Model | Hesitation sounds the model wrote (of 9) | Changed by Standard | What the model does by itself |
|---|---|---|---|
| SenseVoice | 3 | 4 | Drops English "Um," but writes "uh" as "a" and 呃 as 饿 (a real word, so nothing can remove it); keeps 呃, 嗯 and every stutter ("我我我想", "这个这个") |
| FireRed ASR2 | 4 | 5 | Keeps all of them; writes no punctuation |
| Parakeet TDT v3 | 4 | 4 | English only; keeps "uh" and "I I I" |

So none of the installed models filters these by itself, and the tidy step has real work to do for each. Skipping it per engine
would not help; the step only fires where the text has something to fix. For Apple's recognizer and the cloud services the
app cannot measure this itself, so each dictation writes one log line with counts only (`polish engine=… hesitations=… repeats=…
connectors=… changed=… chars=a->b`, never the text); read your own log to see which engine needs it. Cloud services have their own
filters too (Settings → Speech → Cloud → "Filter filler words": Tencent `filter_modal`, Aliyun `disfluency`, Volcengine `enable_ddc`).
The measurement found two gaps, now closed: a 嗯 between two words with no mark around it ("方案的话嗯成本"), and three repeats in
a row in English ("I I I think").

## Soft speech and noisy rooms

`Cadenza --bench-quiet` (add `--bench-quiet-enhance=off` for the "before" figures) speaks 12 sentences with the system voice,
scales the speech to a chosen level, adds steady room noise of a chosen level, rounds the result to 16 bits like a microphone's
converter, and has each installed Chinese-capable local model read it. A value of 100 means the model wrote nothing usable.
Levels are the digital level of the signal (dBFS, RMS of the louder frames): normal speech at arm's length is about −28, a
whisper about −45 to −55. They are **not** sound pressure in dB SPL, which depends on the microphone and its gain, so no claim
about decibels in the room can be made from this table.

What changed (all on this Mac, on the audio already in memory):

- A gentle 80 Hz high-pass and, when the recording has a steady room noise close to the speech level, spectral subtraction
  (`SpeechEnhancer`: the noise spectrum is learned from the quietest 20% of frames; strength 2.5, floor 0.05, picked by
  measurement). A recording that is already clean (24 dB or more between its loud and quiet frames) is only high-passed.
- The existing levelling step (up to ×30) now runs on the cleaned audio, so a hum no longer sets its gain.
- Cloud services and Apple's recognizer: recordings whose loudest moment was under a fixed level were dropped as "silence", which
  also dropped every whisper. `SpeechPresence` now compares the recording with its own room: a stretch that stands 2.5 times above
  the quiet part for about a tenth of the recording is speech however soft; a room alone, a cough or digital silence is still
  dropped. The audio sent to those services is not changed (no keys here to measure it).

**SenseVoice** — character error rate, %, before → after:

| Speech level (dBFS RMS) | silent room | fan, −45 dBFS | white noise −65 | white noise −55 | white noise −45 |
|---|---|---|---|---|---|
| −28 (normal) | 2.3 | 2.2 | 3.4 → **2.8** | 2.2 | 2.8 → **2.2** |
| −40 | 2.2 | 11.3 → **3.7** | 2.2 | 2.8 → **2.2** | 4.6 → **4** |
| −50 (whisper) | 2.2 | 100 → **32.5** | 2.8 | 4.6 → **4** | 100 → **11.4** |
| −58 (soft whisper) | 2.2 | 100 | 4.1 → **3.4** | 100 → **5.7** | 100 |
| −66 | 2.2 | 100 | 100 → **5.7** | 100 | 100 |

**FireRed ASR2** — character error rate, %, before → after:

| Speech level (dBFS RMS) | silent room | fan, −45 dBFS | white noise −65 | white noise −55 | white noise −45 |
|---|---|---|---|---|---|
| −28 (normal) | 2.8 | 2.8 → **3.3** | 2.8 | 3.3 → **2.8** | 3.3 → **2.8** |
| −40 | 2.8 | 12.6 → **3** | 2.8 | 3.3 → **2.8** | 5.5 |
| −50 (whisper) | 4 → **3.4** | 100 → **35.5** | 3.4 → **2.8** | 3.5 → **4.7** | 100 → **16.3** |
| −58 (soft whisper) | 3.4 | 100 | 4.7 | 100 → **11.1** | 100 |
| −66 | 3.4 | 100 | 100 → **11.4** | 100 | 100 |

Reading the table: soft speech in a quiet room was already fine (levelling does that); the gains are where a steady noise sits
close to or above the speech. White noise is the harshest case (it covers every frequency); a fan's low rumble is closer to a
real room. Differences of about one point (for example 2.8 and 3.3) are within the variation of 12 sentences. When the noise is
more than about 10 dB louder than the speech (a whisper at −58 under white noise at −45, or speech at −66 under noise at −55)
nothing recovers the words, and the tool does not pretend otherwise. Synthetic speech and noise are cleaner than a real
microphone in a real room; this has not been measured on real recordings.
