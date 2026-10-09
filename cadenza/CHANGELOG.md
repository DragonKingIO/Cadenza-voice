# Changelog

What changed in each version, for people who use Cadenza. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).
Each release is also published, with its package and checksum, on
[GitHub Releases](https://github.com/DragonKingIO/Cadenza-voice/releases).

## [Unreleased]

### Compatibility
- CI now runs the package on Apple silicon with macOS 14, 15 and 26 and on Intel with macOS 15 and 26, so the claims about Intel and older systems are checked on real systems at every change. That run found that Vision's QR code detector finds nothing on macOS 14 in that environment; QR codes now fall back to Core Image's detector when Vision finds none.

### Fixed
- **A Keychain prompt that showed a code like "ui.5b50196b3cb3" instead of a name.** Saved speech-service credentials carried the raw text key as their name, so macOS asked to open "ui.5b50196b3cb3". Such names are now recognized as old and rewritten to the app's name at launch (the name only; secrets and permissions are untouched), and new items always get a readable name. After you press Always Allow once for an item, macOS stops asking for it.
- Self-test suites other than `--selftest` read the person's real settings and Keychain, so a developer's own AI polish setting could make a test wait on a system prompt nobody sees. Every `--selftest*` run now uses a scratch config and an in-memory Keychain.
- **Dictated text "kept for you" instead of typed into the text field, after reinstalling or running tests.** macOS keeps one permission record per app identifier, tied to the code signature that was granted. Any other copy with the same identifier but a different signature (a test build, a release candidate) that only asked "am I allowed?" made macOS distrust the record, and the installed app silently lost its Accessibility grant while still believing it had it. Now every permission question goes through one place, and self-tests, previews, benchmarks and resource checks never ask the system. The app also notices a grant that no longer answers, and says so ("Accessibility permission is off … grant the permission again") instead of a generic failure. A source check (`tools/check-tcc-calls.sh`, run by the build and by CI) fails if code asks for a permission directly. If the app already lost the grant, turn Accessibility off and on again for it once in System Settings → Privacy & Security, then restart it.

### Added
- **AssemblyAI and ElevenLabs Scribe speech recognition.** AssemblyAI's short-clip service (one call, up to two minutes, a limited set of languages; the language must be named, English is assumed otherwise) and ElevenLabs Scribe (language detected unless named, up to five minutes, sound descriptions such as laughter are not added). Both take your vocabulary as key terms. Their key checks send no audio (AssemblyAI lists transcripts, ElevenLabs lists models). Not tested against the real services (no accounts here): the request shapes follow the vendors' documentation, with scripted answers for a wrong key, a limit and a message that echoes the key. AssemblyAI's documentation names two addresses for the short-clip call; the one from its API reference is used.
- **Google Cloud Speech-to-Text and Microsoft Azure Speech.** Two more international services. Both take the language you name (one per recording, up to a minute); Google also takes your vocabulary as phrases to favour and a model choice, Azure takes the region of your Speech resource or the address of the resource and no list of terms. A Google API key is the same one text recognition uses, so it is entered once. The key checks send no audio: Google is asked an empty question that only a valid key answers with "invalid argument", Azure is asked for a token. Not tested against the real services (no accounts here): the request shapes follow the vendors' documentation and are tested with scripted answers, including a wrong key, a project without the API turned on, a limit and nothing recognized. Azure keeps words as spoken (no masking of profanity).
- **Any OpenAI-compatible speech-to-text service.** "Other OpenAI-compatible service" takes an address, a model and a key, so Together AI, Mistral (Voxtral), SiliconFlow, a Whisper server on this Mac or anything else that copies the OpenAI transcription API works without waiting for a release. Together, Mistral and SiliconFlow are offered as presets (address and model as their documentation gives them). The same rules as for AI services apply to the address: https, or http for this Mac only, no credentials or query in it; the key goes only to that address, and the permission sheet names the address. Tested end to end over the real network stack against a local server that parses the upload independently (model, language, the term list and a valid WAV arrived as sent); not tested against the cloud services themselves.
- **OpenAI and Groq speech recognition.** Two international services for people who already have an account there: OpenAI speech to text (`gpt-4o-mini-transcribe`, `gpt-4o-transcribe`, `whisper-1`) and Groq's Whisper models. The recording is sent once when you release the key (up to five minutes), the language is detected or chosen, your vocabulary goes along as a short list of terms to favour, and a rejected key, a missing model, a limit or a dead network each say so in words. The key check uses the service's model list and sends no audio. Only after you allow the service to receive recordings. Not tested against the real services (no keys here): the request shape, the answers and the failures are tested with scripted replies.
- **One account, entered once.** Speech recognition and text recognition from the same company sign in with the same secret, so a Tencent Cloud or Baidu key saved for one is now used by the other, in both directions, with no second registration and no second copy in the Keychain. The settings sheet says when a key is in use from the other feature, and a key typed in either place replaces it for that feature only. Tencent needs only the account ID in addition for speech recognition. Baidu keys belong to an application in the console, so text recognition must also be switched on for that application; the service's message says so when it is not.
- **A measurement of translating with a model on this Mac, and stricter checks on the answer.** `Cadenza --bench-translate` runs twelve dictated sentences through any chat service and counts what the app would use and what it would refuse. It found answers the old check let through: a Japanese answer with English and Chinese words left in it, and an English answer with a Chinese word left in the middle. Both are now refused (the dictation is inserted untranslated, with the reason), and the translation prompt now states that 万 is ten thousand. Results for Qwen2.5 3B and 7B, and what they get wrong, are in [LOCAL-MODELS.md](docs/LOCAL-MODELS.md).
- **Soft speech and noisy rooms.** Local models now read recordings after a gentle high-pass and, when a steady room noise sits close to the speech level, a noise reduction step (`SpeechEnhancer`); clean recordings are left alone. Measured with `Cadenza --bench-quiet` on synthetic speech: with the speech at −50 dBFS under a fan's rumble the character error rate fell from 100% to about 33% (SenseVoice) and 36% (FireRed ASR2); at −50 under white noise at −45 from 100% to 11% and 16%; at −58 under white noise at −55 from 100% to 6% and 11%; quiet rooms and normal speech did not change (2–3%). When the noise is as loud as the speech or louder, nothing helps. Cloud services and Apple's recognizer no longer lose a whisper: a recording is judged "speech or only the room" against its own quiet part instead of against a fixed level (the audio they receive is unchanged). The tables, the method and the limits (dBFS is not dB SPL; synthetic noise, not real microphones) are in [LOCAL-MODELS.md](docs/LOCAL-MODELS.md).
- **My AI models.** Add any number of AI services (a name, an address, a model, a key and its own permission to receive text) under Settings → Voice input → "My AI models", and pick one for AI polish and one for voice translation, so translation can use a different model than polish, a stronger or a local one, or a model added only for it. The single service of earlier versions is carried over as the first model, with its key, so nothing has to be set up again. Deleting a model deletes its key; each model has its own key.
- **Voice translation.** Choose a language in Settings → Voice input ("Translate dictation into", 37 languages or any language you type) or in the menu bar ("Translate into", with the common ones), and what you say is recognized, translated, and the translation is inserted. It uses the AI service you set up for AI polish (any of the listed services, including Ollama and LM Studio on this Mac), so any language the model knows works, and no new key is needed. The answer is checked before use: it must be in the chosen language's script, keep every number and any glossary term, and not be a refusal; on any failure, the spoken text is inserted and the result line says why. Only text is sent, and the same permission, Keychain and "Only on this Mac" rules apply as for AI polish. Engines to come: Apple's translation and the cloud translation services of Tencent, Volcengine, Baidu and Aliyun.
- `Cadenza --bench-fillers` measures whether the installed local models already leave out hesitation sounds and stutters (they do not: SenseVoice, FireRed ASR2 and Parakeet all keep most of them), so the tidy step has work to do for each; see [LOCAL-MODELS.md](docs/LOCAL-MODELS.md). Each dictation also logs what the tidy step did as counts only (`polish engine=… hesitations=… repeats=… changed=…`, never the text), so the need for it can be read off real use for Apple's recognizer and the cloud services.
- Tidy the text: a 嗯 written between two words with no mark around it ("方案的话嗯成本") now goes too, and three repeats in a row in English ("I I I think") collapse to one. A 嗯 that is a whole answer, and 嗯哼, stay.
- **The vocabulary now reaches the cloud recognizers that accept hot words**: Tencent (word|weight, your own terms heavier), Volcengine (up to 50) and Deepgram (key terms, English and multilingual only, up to 100), added to whatever you typed in the provider's own hot-word field and kept within each provider's own rules; if the result would be refused, the recording uses your options as they were. Only the service you already allowed to receive recordings gets them, and "Also give the terms to cloud recognition services" in Settings → Vocabulary switches it off. Other engines have no hot-word field here: the correction after recognition covers them.
- **Vocabulary** (Settings → Vocabulary). Fixes names and jargon that speech recognition gets wrong, for every engine, after recognition and on this Mac: your own terms (with the spellings recognizers actually write for them), plus shared packs shipped with the app and open to contributions on GitHub (`cadenza/vocab`). Three kinds of fix, all exact: an alias you listed (吉特哈勃 → GitHub), an English term written apart or in the wrong case (git hub, github → GitHub; node js → Node.js), and a Chinese term written with characters that sound the same (糖尿饼 → 糖尿病). A plain English word such as React or Swift is never re-cased from a shared pack, and links, addresses and `code` are left alone. Packs: developer, AI and machine learning, cloud and DevOps, Apple platforms (on by default), medicine (Chinese) and business (off by default). Import a JSON pack, a JSON list or plain lines, and export your terms as a pack file to share. When AI polish is on, the terms found in the text are given to the model as a glossary.
- **AI polish** (Settings → Voice input, off by default). After recognition, a language model removes fillers, fixes punctuation and obvious recognition mistakes. One chat-completions interface covers DeepSeek, Qwen, Zhipu, Kimi, SiliconFlow, OpenAI and any compatible address, including Ollama and LM Studio on this Mac (no key, no upload). Two styles: keep your wording, or written style. Only text is sent, never audio; a service that is not on this Mac needs its own permission, an API key in the Keychain, and an `https://` address, and "Only on this Mac" blocks it. The answer is checked before use: if numbers change, it is translated or refused, it is much longer, or it does not keep your words in order, the text is inserted without polishing, and so it is on any error or time-out. A Test button tries your settings. Checked against a real local model (qwen2.5 on Ollama) through the app's own client; small models (about 1B–3B) sometimes rewrite, so prefer 7B or larger, or a cloud model.
- **Tidy the text** (Settings → Voice input). Recognized text can be cleaned before it is inserted: hesitation sounds (呃, 嗯, um, uh), stuttered repeats ("我我我想", "I I think"), stray spaces and doubled marks. *Standard* is on by default; *Thorough* also drops spoken fillers that only fill a pause ("那个，", "然后，", "you know,"); *Off* inserts exactly what the recognizer wrote. Long text can optionally be split into paragraphs (off by default, because a line break typed into a chat box can send the message). It is a fixed set of rules on this Mac, with no model and no network. Words that belong to a sentence are kept: 额度, 呃逆, "err on the side", a 嗯 that is a whole answer, links, e-mail addresses and `code`.

### Changed
- "Compare models with my voice" now compares every way of recognizing that is actually set up: downloaded local models, cloud services with saved credentials and upload consent, and the Mac's built-in recognition when it runs on the device. Nothing that is not downloaded or not configured is listed. Each way has a tick box, cloud services are marked "Uploads recording" with a notice naming where the recordings go, and a service that fails (no network, rejected credentials) shows why instead of a score. The recordings still exist only in memory. When the app is locked to local recognition no cloud service is offered.
- Speech settings: "Recognition settings" is no longer a separate tab. Its options (language, number formatting, voice-detection sensitivity, CPU use, update source and import) now sit under the model list on the Local models page.

### Speech recognition
- The model list now says how fast each local model is, how much memory it needs and whether its text comes with punctuation, from measurements on one Mac (a footnote says so). Speech models show how long 10 seconds of speech takes; text recognition models show the time for one line.
- Two more on-device speech models, both experimental: **Paraformer** (Chinese with English words, int8, about 244 MB, the fastest, writes no punctuation) and **Qwen3-ASR 0.6B** (multilingual, int8, about 879 MB, writes punctuation). On the same 105 synthesized clips Qwen3-ASR made 0.8% character errors against 2.0–2.2% for SenseVoice and 1.8% for Paraformer, and was the only one to read Chinese with English words correctly; it is also the slowest. SenseVoice stays the recommended default. `--bench-model=<kind>:<folder>` compares models that are not installed.

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
