---
# Draft dataset card. Copy the body into README.md of the Hugging Face dataset repository.
license: cc0-1.0
language:
  - zh
  - en
pretty_name: Cadenza Mandarin voice test set
size_categories:
  - n<1K
task_categories:
  - automatic-speech-recognition
extra_gated_prompt: >-
  This dataset is for measuring speech recognition accuracy. Please confirm
  you have read the dataset card and will not try to identify the speakers.
extra_gated_fields:
  Name or organization: text
  I will use this data to evaluate speech recognition: checkbox
  I will not try to identify or contact the speakers: checkbox
---

# Cadenza Mandarin voice test set

Recordings of volunteers reading a fixed 90-sentence Mandarin script (with some English words), collected to **measure and fix the recognition accuracy** of [Cadenza](https://github.com/DragonKingIO/Cadenza-voice), an open-source voice typing app for macOS.

## Contents

- `cc0/<participant_id>/` : one folder per participant who chose license A (public, CC0).
  - `wav/<sentence_id>.wav`: 16 kHz, mono, 16-bit PCM.
  - `manifest.json`: sentence IDs, reference text, durations, consent option, metadata, recorder version.
  - `consent.json`: the consent text version and the choice the participant made.
- `script.json`: the reference script (same as `docs/testset/script.json` in the Cadenza repository).

Recordings from participants who chose license B (evaluation only) are **not** in this dataset. They are kept in a private repository and are never redistributed.

## Metadata

Accent or region and microphone type are always present (may be "prefer not to say"). Gender and age range are optional and may be empty.

## Intended use

Evaluating and comparing speech recognition systems on everyday Mandarin and mixed Chinese-English dictation. The maintainers do not use it to train models. CC0 does not restrict others, but we ask you not to use it to identify speakers and, where you can, to keep it for evaluation.

## Limitations

A small sample of volunteers, read speech rather than spontaneous speech, recorded on whatever microphone each person had. Do not draw conclusions about accents or groups not well represented.

## Removal

Participants can ask for their files to be removed at any time: email evendstate@gmail.com with the participant ID. Copies already downloaded cannot be recalled.

## License

CC0 1.0 Universal for the recordings, reference text and metadata in this dataset.
