# Public voice test set

Help us measure and fix Cadenza's recognition accuracy. Read a short script aloud in your browser, and send us the recordings if you agree.

Chinese version: [README.zh-CN.md](README.zh-CN.md).

- Recorder (after the website PR is deployed): https://dragonkingio.github.io/cadenza-site/record/
- Script: [script.md](script.md) (machine-readable: [script.json](script.json)), 90 Mandarin sentences in six groups: short, medium, long, mixed Chinese and English, particles and questions, numbers and dates.
- Consent form: [CONSENT.md](CONSENT.md)

## How it works

1. Open the recorder, read the consent form, choose license A (public, CC0) or B (evaluation only), and fill in the metadata.
2. Read each sentence at a normal pace. You can re-record, play back, or skip any sentence. A level bar warns you if the sound is too quiet or clipped.
3. Download the zip file. Nothing is uploaded by the page.
4. Send the zip file as described on the last page of the recorder.

## What is and is not collected

Collected: WAV recordings (16 kHz, mono), the reference text, a random participant ID, accent or region, microphone type, and optionally gender and age range. Not collected: name, account, location, or anything from your device.

The data is used to measure and fix recognition accuracy. It is not used to train models. Recordings under license A are published as CC0 in a gated dataset; recordings under license B stay private and are deleted on request.

## What is in this folder

| File | Purpose |
| --- | --- |
| `script.md`, `script.json` | The reading script, single source of truth |
| `CONSENT.md`, `CONSENT.zh-CN.md` | Consent form, versioned |
| `DATASET_CARD.md` | Draft dataset card for the Hugging Face dataset |
| `HF_SETUP.md` | Maintainer steps to create the datasets and handle submissions |
| `DISCUSSION_POST.md`, `DISCUSSION_POST.zh-CN.md` | Draft announcement for GitHub Discussions (not published) |

Audio never goes into this repository.
