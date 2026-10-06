# Recognition accuracy: how it is measured and what was changed

`--accuracy-benchmark` (developer tool, no window) speaks 30 Mandarin sentences with several system voices under
several conditions and scores every engine with the character error rate (CER). Punctuation and spaces are ignored,
Arabic numerals equal Chinese numerals ("3点" = "三点"), and English is case-insensitive.

```
Yansui --accuracy-benchmark [--bench-quick] [--bench-voices=Tingting,...] [--bench-conditions=clean,quiet,...]
       [--bench-engines=<substring>] [--bench-workers=N] [--bench-cache=<dir>] [--bench-out=<json>]
       [--bench-cloud-only] --bench-cloud=iflytek,deepgram [--bench-cloud-clips=24]
       [--bench-pad=0.8] [--bench-min-speech=0.25] [--bench-min-silence=0.5] [--bench-vad=0.5] [--bench-threads=2]
```

Conditions: `clean`, `quiet` (volume ×0.05), `quietnoise` (15 dB noise at low volume), `noise10` (10 dB noise),
`tail` (a second of room noise after the speech), `fast` (260 words per minute). Local runs use every installed model
and several recognizer instances in parallel. Cloud engines are only run when named, because they upload the
synthesized audio with the user's credentials and consent.

## What the numbers mean

Synthesized speech is cleaner and more regular than a person, and system voices pronounce English words badly, so the
absolute values are optimistic and the "mixed" sentence type is not representative. The benchmark is for comparing
settings on identical audio and for catching regressions. It cannot measure a particular person's voice, accent or
microphone.

## Local model (SenseVoice small, int8), 3 voices × 30 sentences × 6 conditions

| Setting | clean | quiet | quiet+noise | noise 10 dB | tail noise | fast | overall |
|---|---|---|---|---|---|---|---|
| Before (language auto, 0.2 s VAD margin, no level) | 9.1% | 44.9% | 22.6% | 18.0% | 10.6% | 13.1% | 19.7% |
| + loudness levelling | 9.4% | 9.7% | 16.0% | 18.3% | 10.3% | 13.8% | 12.9% |
| + Mandarin set explicitly | 9.2% | 9.3% | 13.1% | 15.6% | 8.9% | 13.1% | 11.5% |
| + 0.8 s margin around speech (shipped) | 6.8% | 7.0% | 13.1% | 15.5% | 7.5% | 9.8% | **10.0%** |

Short sentences: 21.2% → 1.0%. Sentences with numbers: 12% → 1.8%.

Changes kept because they measurably helped:

1. **Loudness levelling** (`LocalDecoder.levelled`): quiet recordings are raised to a normal level before recognition
   (boost only, at most ×30, based on the 99.5th percentile so one click does not block it). Quiet speech went from
   44.9% to 9.7%.
2. **Mandarin when the app is set to Chinese** (`LocalRecognitionOptions.resolved`): "automatic" sometimes heard short
   Mandarin as Japanese or Korean. An explicit choice by the user is never overridden; Cantonese regions stay automatic.
3. **0.8 s margin around detected speech**: the old 0.2 s cut off soft first syllables ("好的，我马上处理" became "我马上处理").
   Gains level off at 0.8 s; a longer margin did not help and a margin did not add noise hallucinations.

Tried and rejected: higher VAD threshold (0.65 was worse, 0.35 equal), shorter minimum speech, longer minimum silence,
4 threads (identical text, only speed differs).

Still weak (model limits, not settings): 10 dB noise (15%), English words inside Chinese sentences, rare words.
Parakeet TDT v3 has no Mandarin; it is only chosen for European languages. FireRedASR2 needs to be downloaded in the app
before it can be compared; run the benchmark afterwards.

## Cloud services

| Service | What was checked |
|---|---|
| iFlytek | Live, synthesized speech, 22 of 24 clips scored: 2.7% CER (clean 3.7%, quiet 3.0%, fast 0%). The other 2 clips failed with "send buffer full" because the test pushed a long clip faster than real time; the benchmark now paces it. Parameters `dwa=wpgs`, `ptt`, `nunum`, `vad_eos` are sent for Mandarin only. |
| Deepgram | Live test showed garbage for Chinese with the saved language `multi`: **multilingual mode does not include Chinese** (Nova-3 supports `zh-CN`, `zh-TW`, `zh-HK` separately). Fixed: a recording that asks for `multi` while the app is set to Chinese now uses the matching Chinese language; the saved setting is not rewritten; other languages are untouched. |
| Tencent | Official parameter table: the Chinese-English large model `16k_zh_en` accepts punctuation, number conversion and filler filtering, but the app disabled them. Now enabled for `16k_zh` and `16k_zh_en`; the English-only model still sends none. |
| Volcengine, Aliyun, Baidu | Parameters reviewed against the code and wire tests; not live tested because no account is configured. |

## Checks

`--selftest` covers the scoring (normalization, edit distance, noise), levelling (boost, no change when loud, silence,
cap, clicks), language resolution, the VAD margin, Tencent and Deepgram wire parameters. The real-model checks run when a
model is installed.
