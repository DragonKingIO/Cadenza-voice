# Developing Cadenza

Everything lives in `cadenza/`. The app is plain Swift (Swift 5 language mode, SwiftUI plus AppKit) compiled with `swiftc`;
there is no Xcode project. Local speech models run through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx).

## Requirements

- macOS 26 or later on Apple silicon, with the Xcode Command Line Tools (`xcode-select --install`).
- Optional: the sherpa-onnx static library for local models. Without it the app still builds, without local recognition.

## Build

```sh
./cadenza/tools/fetch-sherpa-onnx.sh        # optional, once: downloads the inference library into cadenza/third_party
./cadenza/build.sh --stage-only             # builds cadenza/build/stage.noindex/Cadenza.app.zip
```

`--stage-only` does not install anything and works without the maintainer's signing certificate: the package is signed ad
hoc. Plain `./cadenza/build.sh` installs over `/Applications/随言.app` and is for maintainers; it refuses to run without the
real signing identity so that a stray build can never replace the signature the installed app's privacy permissions are
tied to. `CADENZA_SIGN_IDENTITY=<id>` selects another certificate; `-` means ad hoc.

The staged app is a zip on purpose, so that no launchable copy sits in your checkout. To run it, unzip into a temporary
directory, use it, then delete it:

```sh
T=$(mktemp -d) && unzip -q cadenza/build/stage.noindex/Cadenza.app.zip -d "$T"
"$T"/*.app/Contents/MacOS/Yansui --selftest
```

(`Yansui` is the executable's compatibility name and stays as it is.)

### Names you will see in the code

The product is **Cadenza** (English) and **随言** (Simplified Chinese); user-visible names always come from `Brand.name`.
A few identifiers from before the rename remain on purpose, because changing them would make existing installs lose their
permissions, saved credentials and settings. Please do not rename them in a "cleanup" pull request:

- the Bundle ID `local.yansui.app` and the executable name `Yansui`;
- the Keychain service name `Yansui` and the support folder `~/Library/Application Support/Yansui`;
- the code that recognises Keychain labels written under retired product names (`Capsule.swift`).

## Test

Run every suite before a pull request. Each prints `failures=0` when it passes:

```sh
BIN="$T"/*.app/Contents/MacOS/Yansui
"$BIN" --selftest                      # main suite
"$BIN" --selftest-settings-ui
"$BIN" --selftest-settings-polish
"$BIN" --selftest-status-menu
"$BIN" --selftest-asr-settings
"$BIN" --selftest-asr-entry
"$BIN" --selftest-local-model
"$BIN" --selftest-trigger-stage2
"$BIN" --check-brand-resources         # both languages have the same keys
./cadenza/trigger-state-machine/run-tests.sh
```

- Self-tests never open windows and use isolated configuration. They do write lines into the local log file.
- `--selftest-local-model-real` runs a real installed model on speech synthesized by macOS `say`. It skips itself when no
  model is installed. Download models inside the app (Settings → Speech → Local models).
- Tests with a fake recorder or fake socket prove the protocol, not a real microphone or provider. Say which you ran.

## Measure accuracy

`--accuracy-benchmark` speaks a fixed Mandarin corpus with several system voices under several conditions and scores each
installed model (and, if you name them, cloud providers) with the character error rate. See
[ACCURACY.md](ACCURACY.md) for options and the current results. Use it to justify any change to recognition settings or any
new model: keep a change only if it measurably helps.

## Preview the interface

```sh
"$BIN" --preview-brand-page=engines --preview-engine-tab=tuning \
       --preview-brand-output=/tmp/engines.png --preview-brand-height=1100 --ui-language=zh-Hans
```

Pages: `onboarding-1…`, `engines`, `engines-local`, `general`, `developer`, `capsule-record`, `capsule-error` and more
(`BrandPreview.swift`). Previews render off-screen with temporary configuration: no shortcut listeners, no recording, no
network.

## Layout

| Path | Contents |
|---|---|
| `src/` | All app source, plus `*Fixtures.swift` self-test suites |
| `src/ASRCore.swift`, `ASRWire.swift`, `CloudASRRecorder.swift`, `*Provider.swift` | Cloud providers and their wire formats |
| `src/LocalASR.swift`, `LocalModelCatalog.swift`, `LocalModelCenter.swift` | Local models: loading, catalog, download |
| `src/VoicePipeline*.swift`, `HotkeyCenter.swift`, `Shortcut.swift` | Hold-to-talk pipeline and shortcut handling |
| `src/MainSettingsView.swift`, `*View.swift` | SwiftUI settings and onboarding |
| `src/LocalAPI*.swift` | Loopback developer API ([LOCAL-API.md](LOCAL-API.md)) |
| `resources/` | Localized strings, brand assets (`resources/brand`), illustrations |
| `trigger-state-machine/` | The trigger state machine, a separate Swift package with its own tests |
| `docs/` | Technical documentation |
| `tools/` | Helper scripts, including `check-no-secrets.sh` |

## Adding a language

The app currently ships English and Simplified Chinese, and the language list is **not yet data-driven**. A translation is
more than a strings file: the list of languages is written out in code in several places. Today a third language needs:

1. `resources/<code>.lproj/Localizable.strings` and `InfoPlist.strings`, translated from `resources/en.lproj`. Keep every key,
   keep `%@`/`%d`/`%.1f` placeholders in the same order, and keep product names out of the strings (they come from
   `Brand.name`).
2. A new case in `AppLanguage` and its title key (`src/Brand.swift`), the language list inside `L10n.verifyResources` (it
   currently compares English with Simplified Chinese only), the bundled copies in `build.sh`, the localized privacy and terms
   documents (`PRIVACY.<code>.md`, `TERMS.<code>.md`, see `PrivacySupport.swift`), and the per-language names in
   `LocalModelCatalog.swift`.
3. `--check-brand-resources` must pass, and the busiest pages should be previewed with `--ui-language=<code>`.

Making the language list data-driven, so that a translation is only a strings file plus one table entry, is on the roadmap
and would be a very welcome contribution. If you want to translate, open an **Add a language** issue first so that we can
coordinate this work.

## Adding a local model

Edit `LocalModelCatalog.builtin` and keep `docs/models-manifest.example.json` identical (a test compares them). A model
needs a compatible license, download size, SHA-256 of every file, the files the loader requires and the languages it
covers. Run `--accuracy-benchmark` against the recommended model and put the numbers in your pull request; also report
speed, memory and whether it writes punctuation. The app never downloads a model without the user's action.

## Adding a cloud provider

A provider needs: a wire implementation in `ASRWire.swift` or its own file, option validation in `ASRSettings.swift`,
credential fields in `ASRCore.swift` (stored in the Keychain), the configuration sheet, an upload-consent check, and
wire-level tests with a fake socket covering consent, request construction, partial/final handling, cancellation and errors.
Check the official documentation for every parameter you send. Mark in the pull request that the provider was tested with
a fake transport unless you also ran it against a real account.

## Code style

Match the surrounding code: naming, comment density and idioms. User-facing strings go through `L10n.tr`. Do not add
dependencies without discussing them first; third-party code needs a license entry.
