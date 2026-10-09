# Privacy

Cadenza's current, source-reviewed behavior as of 2026-10-03. It is not a claim of completed network or provider acceptance. [简体中文](PRIVACY.zh-CN.md)

## Our promise

- **We collect nothing.** Cadenza has no server, no account, no analytics, no crash reporting, no advertising and no tracking. The project's maintainers receive no data from your use. A review of the application source found no such code.
- **Your voice goes only where you send it.** Audio is captured only after you start a recording. Local recognition, and Apple Speech when it runs on the device, keep audio on this Mac. A cloud engine sends audio to the provider you selected, and only after you gave that provider upload consent. Local recognition never uploads audio on its own, even when it fails.
- **Nothing is kept.** The app does not save recordings. Recognized text lives in memory until you clear it or replace it with the next result.
- **Your keys stay yours.** Provider credentials are stored in the macOS Keychain, never in the settings file, and you can delete them in Settings → Privacy.
- **You can see and erase local data.** Settings → Privacy shows what is stored on this Mac and lets you clear the recent result, switch the diagnostic log off or clear it, and delete saved credentials.

macOS, Apple, and the speech providers you choose have their own behavior and retention policies. This notice does not cover them.

## What can leave this Mac

| Action | What is sent | To whom |
|---|---|---|
| Recording with a cloud engine | Audio of that recording; authentication requests | The provider you chose, after you consented to it |
| Recording with Apple Speech | On-device if supported; otherwise only if you enabled Apple cloud fallback | Apple |
| Recording with the Local engine | Nothing | Nobody |
| Downloading a local model (you press Download) | Your IP address and the file requested; no audio, no settings | The model host named in the model list (by default the upstream project's GitHub release page) |
| Checking for model updates | A request for a small list file, only if an update source is configured and the option is on. None is configured in this version | The update source |
| Checking for app updates (when you press Check in About, or weekly if you answered yes in the setup wizard or ticked the box in About; off by default) | A request for the project's latest release information. The host can see your IP address and that the request came from this app; nothing else is sent. Nothing is installed for you. When a newer version exists, the app remembers its version number, its release page address and the first lines of its release notes in its own settings, and shows a notice in the menu bar menu and on the About page until you update or skip that version. "Never go online" turns checks off | The project's release page (GitHub) |
| Testing provider credentials (you press Test) | A short silent test request | The provider |
| Local developer API (off by default) | Nothing leaves the Mac: it listens on 127.0.0.1 only. A program or device bridge on this Mac can submit audio; it is handled like a recording (a local model keeps it on the Mac, a cloud engine uploads it to that provider after your consent) | Programs on this Mac holding your owner token or a device token you created |

Cloud providers integrated in this version: iFlytek, Volcengine, Tencent Cloud, Alibaba Cloud, Baidu, Deepgram, OpenAI and Groq. OpenAI and Groq receive the whole recording once you release the key, together with the terms you gave for hot words (as a short list), and nothing else; the key stays in the Keychain. Their names are trademarks of their owners; Cadenza is not affiliated with or endorsed by them.

## Capture and destinations

Audio capture begins after a user starts a recording by shortcut, in-app button, or menu, subject to permissions. Tap recording continues until ended; capture is not limited to the time a shortcut is physically held.

Apple Speech explicitly requires on-device recognition when the selected recognizer reports support. If that support is unavailable, recording is refused unless Apple cloud fallback is enabled. With fallback enabled, Apple may process the audio remotely.

Cloud providers require per-provider upload consent in the production voice pipeline. The selected provider receives the recording and returns text; authentication requests may also be made. Source-level consent checks are present, but no packet capture was performed for this documentation update.

Turning consent off in the provider settings and saving it blocks future sessions. Settings cannot currently be saved during an active recording. If you cancel a recording after streaming has started, audio already sent to the provider cannot be recalled. Providers that accept a single upload at the end receive nothing when you cancel.

The hybrid buffer gate is connected in source behind a disabled-by-default development switch; it has not been enabled in the installed app. Before the standalone-modifier decision point, a chord or extremely short tap discards the local buffer without establishing a provider connection. After the decision point, streaming providers may already have received audio; whole-recording providers receive audio only at a valid end. Consent is checked again before constructing the service. Local test transports count requests/messages without using real credentials or network audio. This is not a live packet-capture result.

## AI polish (optional)

Off by default. When you turn it on and choose a service, the **recognized text** (never the audio) is sent to that service's address after recognition, to remove fillers and fix punctuation. Nothing else is sent: no audio, no settings, no earlier text. A service on this Mac (Ollama, LM Studio, any `localhost` address) does not send the text anywhere else. For a service that is not on this Mac you must also switch on "Allow sending the recognized text to this service"; plain `http://` is refused for such addresses, the API key is stored in the macOS Keychain (never in the settings file), and turning on "Only on this Mac" blocks the service. If the service fails, is slow, or its answer does not look like your text, the text is inserted without polishing. The log records only the service name, the number of characters and the time taken, never the text or the key.

## Voice translation (optional)

Off by default. When you choose a language to translate into (Settings → Voice input, or the menu bar), what you say is recognized as usual and the **recognized text** (never the audio) is sent to the model you chose for translation under "My AI models" (it can be a different one than AI polish uses), which returns the translation; the translation is inserted. The rules are the same as for AI polish, and are kept per model: a service that is not on this Mac needs your permission, an API key in the Keychain and an `https://` address, "Only on this Mac" blocks it, and if the service fails or its answer does not look like a translation (wrong language, numbers or names changed, a refusal) the text is inserted untranslated. The log records the service, character counts and time, never the text.

## Vocabulary

Your own terms are stored in `vocabulary.json` in the app's data folder on this Mac; the shared packs are files inside the app. Correcting terms runs on this Mac and sends nothing. If you use a cloud recognition service that accepts hot words (Tencent, Volcengine, Deepgram for English, and OpenAI and Groq as a short list), your terms and the terms of the packs you switched on are sent to that service before the recording, as hot words, together with your recording and only to the service you already allowed to receive it; the switch "Also give the terms to cloud recognition services" in Settings → Vocabulary turns this off, and then your own terms stay on this Mac. Only when AI polish is on, the terms that appear in the dictated text (and your own terms) are included in the request to the service you chose, as a glossary, together with the text. Import and export read and write only the file you choose.

## Text tidying

The "Tidy the text" setting (Settings → Voice input) removes hesitation sounds and stuttered repeats from recognized text, and can split long text into paragraphs. It is a fixed set of rules that runs on this Mac: no model, no network, nothing is sent or stored.

## Local storage

- Settings: `config.json` in the app's data folder (Settings → Privacy → Open data folder), including provider options and consent flags. A few preferences (app language, recording indicator style, whether the diagnostic log is on, which version of this notice and the terms you accepted) are kept in the app's macOS preferences. The Local developer API, if you turn it on, keeps its port and access token in `local-api.json` and `local-api-token` in that same folder (readable only by your account).
- Provider credentials: macOS Keychain, using the existing compatibility service identifier. They are not stored in the settings JSON by the production credential writer.
- Recognition results: retained in application memory until cleared or replaced. Copying a result places it on the system clipboard, where other software may access it.
- Audio: the current native and cloud recorder code uses memory buffers; no production audio-file writer was found. Cloud buffers are cleared on abort, completion, or failure. This is source evidence, not an OS memory, swap, or external-provider retention guarantee.
- Logs: local `log.txt` in the same support directory (capped at about 512 KB; the oldest lines are dropped; you can turn file logging off or clear it in Settings → Privacy), plus standard error and an in-memory diagnostic buffer. Logs include timestamps, engine/session state, errors, input-source identifiers, target-process diagnostics, and text lengths. Current production paths do not intentionally log raw recordings, transcripts, or credentials. Old files and manually collected diagnostic artifacts were not exhaustively audited.

No analytics, third-party crash-reporting, or telemetry implementation was found in the reviewed application source. macOS and speech providers have their own behavior and retention policies; this statement does not cover them.

## Your controls

Provider settings expose upload consent. Apple cloud fallback is separate. The Privacy page can clear the recent recognition result, switch the diagnostic log off or clear it, delete the saved provider credentials from the Keychain, and open the local-data directory. To remove everything else, quit the app and delete its data folder (Settings → Privacy → Open data folder takes you there).

Cloud recognition needs your provider account and credentials. Review that provider's own terms before enabling it. Do not share recordings, transcripts, credentials, or unredacted diagnostic logs in bug reports.

## Local models

The Local engine recognizes speech on this Mac with models you download in Settings → Speech → Local. Audio is not uploaded for local recognition.

- **Downloads.** Models are not bundled. A download contacts the model host named in the model list (the built-in list points to the upstream project's GitHub release page), which can see your IP address and the file requested; no audio or settings are sent. Files are verified by SHA-256 before use. Packages are unpacked with the system `tar` after checking for absolute paths, `..` and links.
- **Update check.** If enabled (default, and only when at least one model is installed and an update source is configured), the app downloads a small list file at launch and compares versions. It never downloads a model by itself. You can turn this off in Settings.
- **Fallback.** When enabled, the cloud engine's audio is also kept in memory (up to 120 seconds) so a failed cloud request can be recognized by a local model without you repeating it. That buffer is discarded when the session ends and is never written to disk. When the network is unavailable the app can skip the cloud engine and use the local model directly.
- **Comparing with your voice.** "Compare models with my voice" records a few sentences into memory only (never to disk) and clears them when you close the window. The recordings are recognized on this Mac by the models and the built-in recognizer you tick. They are sent to a cloud service only if that service has your saved credentials, you gave it upload consent, and it is still ticked in the comparison list, which marks it "Uploads recording". When the app is locked to local recognition, no cloud service is offered.
- **Storage.** Models and a small record of installed versions are stored in the `models` folder inside the app's data folder. Deleting a model in Settings removes its files. A loaded model occupies roughly 0.5 GB of memory and is released after a few idle minutes.
- Model licenses are set by their authors; see the license file inside each installed model (Settings → Local → License).

## Screenshots and text recognition

- **Permission.** Capturing needs macOS Screen Recording permission. Without it nothing is captured.
- **What is captured.** When you start a capture (menu, Settings button, or a shortcut you set — none is set by default; the menu also offers full-screen, delayed and repeat-last-area capture), the app takes one picture of each screen and keeps it in memory only while you select and annotate. Cancelling or finishing discards it. Nothing is captured in the background.
- **Where the result goes.** Only when you click: Copy puts the image on the clipboard, Save writes a PNG where you choose, Pin shows it in a floating window. The app never writes a screenshot to the clipboard or disk on its own. Two actions copy text on request: pressing **C** over the magnifier copies the colour under the pointer, and the optional *Screenshot and copy text* shortcut copies recognized text after you select an area.
- **Marks stay local.** Annotations, mosaic and blur are applied on this Mac; nothing is sent anywhere to draw them.
- **Codes.** QR and bar codes in the selected area are detected on this Mac (Apple Vision). A code is only opened in your browser when you click Open.
- **Text recognition — on this Mac (default).** Apple Vision runs on this Mac; the selected area is not uploaded.
- **Text recognition — on-device models (optional).** In Settings → Text Recognition you can download a PP-OCR model set and use it instead of Apple Vision. It runs on this Mac and the picture is not uploaded. The download works like the speech models above: it contacts the model host named in the model list, which sees your IP address and the files requested, files are checked by SHA-256 before use, and nothing but the model files is fetched. Deleting the model in Settings removes its files; if it is deleted or cannot run, Apple Vision reads the text instead.
- **Text recognition — online services (optional).** In Settings → Text Recognition you can choose Baidu AI Cloud OCR, Tencent Cloud OCR or Google Cloud Vision. They are off until you enter your own keys **and** switch on *Allow uploading the screenshot area to this service* for that provider; removing the keys switches the permission off again.
  - **What is sent.** Only the selected area, re-encoded as a JPEG (long side at most 4096 px for Baidu and Google, 6000 px for Tencent; reduced further if the file is too large), together with your credentials in the request the provider requires. Nothing else from the screen is sent, and no audio.
  - **Where.** `aip.baidubce.com` (Baidu), `ocr.tencentcloudapi.com` (Tencent), `vision.googleapis.com` (Google). Those providers see the image, your IP address and your account, and handle them under their own terms and retention; the app cannot recall an image once sent. Check each provider's policy before use.
  - **Keys.** Stored in the macOS Keychain under `ocr.<provider>.<field>`, never in the settings file, logs or this repository, and never shown again after saving. *Test connection* sends one small built-in test image only when you click it.
  - **Fallback.** If the online service fails, there is no network, or you have not allowed upload, the app recognizes on this Mac instead (when *Fall back to this Mac* is on) and tells you why. With fallback off it reports the error and sends nothing else.
- The recognized text is shown in the screenshot view and in a window; it is copied only when you press Copy Text (or use the direct-copy shortcut).
