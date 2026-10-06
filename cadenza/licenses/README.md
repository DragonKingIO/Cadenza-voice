# Licenses of code built into the app

When `tools/fetch-sherpa-onnx.sh` has been run, `build.sh` statically links the sherpa-onnx inference library and the code it
contains. Their license texts are kept here, unmodified, as published upstream at the versions below, and `build.sh` copies this
folder into the app bundle (`Contents/Resources/Licenses`). Update this folder whenever the sherpa-onnx version changes:
the versions come from sherpa-onnx's `cmake/*.cmake` files and those of its dependencies.

| Component | Version | Source | License | Files |
|---|---|---|---|---|
| sherpa-onnx | 1.13.8 | https://github.com/k2-fsa/sherpa-onnx | Apache-2.0 | `sherpa-onnx-1.13.8/LICENSE` (full Apache-2.0 text) |
| ONNX Runtime (static library built by csukuangfj/onnxruntime-libs) | 1.28.2 | https://github.com/microsoft/onnxruntime | MIT, plus the notices of its own dependencies | `onnxruntime-1.28.2/LICENSE`, `onnxruntime-1.28.2/ThirdPartyNotices.txt` |
| kaldi-native-fbank | 1.22.3 | https://github.com/csukuangfj/kaldi-native-fbank | Apache-2.0 | `kaldi-native-fbank-1.22.3/LICENSE` |
| KISS FFT (used by kaldi-native-fbank) | febd4ca | https://github.com/mborgerding/kissfft | BSD-3-Clause | `kissfft/COPYING`, `kissfft/BSD-3-Clause` |
| kaldi-decoder | 0.3.0 | https://github.com/k2-fsa/kaldi-decoder | Apache-2.0 | `kaldi-decoder-0.3.0/LICENSE` |
| kaldifst (used by kaldi-decoder) | 1.8.0 | https://github.com/k2-fsa/kaldifst | Apache-2.0 | `kaldifst-1.8.0/LICENSE` |
| OpenFst (csukuangfj fork) | 1.8.5 (2026-07-09) | https://github.com/csukuangfj/openfst | Apache-2.0 | `openfst-1.8.5/COPYING` |
| Eigen (header-only, used by kaldi-decoder) | 3.4.0 | https://gitlab.com/libeigen/eigen | MPL-2.0 | `eigen-3.4.0/COPYING.MPL2`, `eigen-3.4.0/COPYING.README` |
| simple-sentencepiece | 0.7 | https://github.com/pkufool/simple-sentencepiece | Apache-2.0 | `simple-sentencepiece-0.7/LICENSE` |
| nlohmann/json (header-only) | 3.12.0 | https://github.com/nlohmann/json | MIT | `nlohmann-json-3.12.0/LICENSE.MIT` |
| hclust-cpp / fastcluster (header-only) | 2026-02-25 | https://github.com/csukuangfj/hclust-cpp | BSD-2-Clause | `hclust-cpp-2026-02-25/LICENSE` |

The list was checked against the symbols in the linked static libraries; the text-to-speech parts of sherpa-onnx (espeak-ng,
piper) are not in the "no-tts" build that is linked. Eigen's source is available at the URL above, as MPL-2.0 requires.
