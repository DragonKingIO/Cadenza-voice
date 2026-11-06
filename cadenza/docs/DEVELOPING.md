# Developing Cadenza

Everything lives in `cadenza/`. The app is plain Swift (Swift 5 language mode, SwiftUI plus AppKit) compiled with `swiftc`;
there is no Xcode project. Local speech models run through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx).

## Requirements

- macOS 14 or later (Apple silicon or Intel), with the Xcode Command Line Tools (`xcode-select --install`). The build produces one binary for both chips (`CADENZA_ARCHS=arm64 ./cadenza/build.sh --stage-only` builds only the chip you are on, faster).
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
"$T"/*.app/Contents/MacOS/Cadenza --selftest
```

### Run a staged build next to the installed app

A staged build and the installed app use the same data folder, `~/Library/Application Support/Cadenza`. To run a staged
build while the installed app runs, give the staged build its own folder with `--data-dir`. Also start it with
`--inspect-page=N`: this mode opens page `N` of the settings window, never asks macOS for permissions and keeps
credentials in memory (see [Test](#test)).

```sh
"$T"/*.app/Contents/MacOS/Cadenza --data-dir="$HOME/Library/Application Support/Cadenza-dev" --inspect-page=1
```

- `--data-dir=<path>` moves the files of this process into `<path>`: the settings (`config.json`), the models, the logs
  and the other data files. A new folder has no models, so download them again in that copy.
- The path must be absolute. Write `$HOME` instead of `~`: the app refuses a relative path and a path that starts with
  `~`.
- When the folder does not exist, the app creates it with mode 0700. When the app refuses the path, it writes the reason
  to stderr and stops with exit code 64. When it cannot create the folder or write to it, it does the same with exit
  code 73. It never uses the standard folder instead.
- The settings window shows the last part of the path under the page title, for example `Cadenza-dev`, so that you can
  tell the two copies apart. Without `--data-dir`, nothing shows there. The window does not show the full path, so that
  a screenshot does not show your user name.
- The app does not move the data of the old product name (`Yansui`) into this folder. Only the standard folder gets it
  (see `LegacyMigration.swift`).
- To start again with an empty folder, quit that copy and delete the folder.
- `--data-dir` does not keep the permissions apart. macOS keeps one permission record for each Bundle ID. When a copy
  with another signature, such as a staged build, asks for a permission, the installed app can lose its grants. Thus
  always start a staged build with `--inspect-page=N`.

### Names you will see in the code

The product is **Cadenza** (English) and **随言** (Simplified Chinese); user-visible names always come from `Brand.name`.
The executable, Bundle ID (`local.cadenza.app`), Keychain service and support folder (`~/Library/Application Support/Cadenza`)
all use the current name. Installs from before the rename keep working: `LegacyMigration.swift` moves the old folder,
preferences and saved credentials once (macOS may ask once to allow access to the old Keychain items; choose Always Allow).
The permissions the app needs (microphone, accessibility, input monitoring, screen recording) are granted again once, because
macOS ties them to the Bundle ID. The code that recognises Keychain labels written under retired product names (`Capsule.swift`)
also stays.

## Test

Run every suite before a pull request. Each prints `failures=0` when it passes:

```sh
BIN="$T"/*.app/Contents/MacOS/Cadenza
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

- Self-tests, previews, benchmarks and `--check-*` runs never ask macOS about permissions (`src/TCC.swift`): a build signed differently from the installed app (ad hoc) that does so makes macOS reset the installed app's Accessibility, Input Monitoring and Screen Recording grants. Ask for permissions only through `TCC`; `tools/check-tcc-calls.sh` enforces it. Do not launch a staged build without one of those flags.
- `--selftest-models-ui` opens the real settings window on a scratch configuration and an in-memory Keychain, and drives the "My AI models" controls (add, type a name, switch consent, save and delete a key, delete with confirmation) through the accessibility tree, as VoiceOver would. It needs a logged-in graphical session, so it is not in CI; run it by hand after changing that page. `--selftest-sidebar-click` does the same for the sidebar.
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
