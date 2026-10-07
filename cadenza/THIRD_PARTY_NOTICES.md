# Third-party notices

The current source imports macOS system frameworks and zlib. Local-model weights are never bundled. When `tools/fetch-sherpa-onnx.sh` has been run, `build.sh` statically links the sherpa-onnx inference library (see below). macOS frameworks are supplied by Apple. zlib is supplied by the system; see its [license](https://zlib.net/zlib_license.html). Future bundled dependencies and model weights must have their versions, source URLs, and code/weight licenses documented before distribution.

## Speech services

The source includes protocol adapters for iFLYTEK IAT, Volcengine speech recognition, Tencent Cloud real-time speech recognition, Alibaba Cloud NLS, and Baidu short speech recognition. Implemented adapters do not establish live-account acceptance or rights to redistribute any provider's software or models.

Apple Speech uses the system Speech framework.

Provider names are trademarks of their respective owners. Cadenza is not affiliated with or endorsed by them. No provider logos are used in the branding material.

## Local inference (optional build component)

Builds made with `third_party/sherpa-onnx` statically link [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) v1.13.8 (Apache-2.0) and the code it contains: ONNX Runtime 1.28.2 (MIT, with the notices of its own dependencies), kaldi-native-fbank (Apache-2.0), KISS FFT (BSD-3-Clause), kaldi-decoder, kaldifst, OpenFst and simple-sentencepiece (Apache-2.0), Eigen (MPL-2.0), nlohmann/json (MIT) and hclust-cpp/fastcluster (BSD-2-Clause). The exact versions, sources and full license texts are in [licenses/](licenses/README.md), and every build copies that folder into the app (`Contents/Resources/Licenses`) together with this file. The list was checked against the symbols in the linked libraries.

## Downloaded models (not bundled)

Models are downloaded by the user inside the app and are not part of this repository or the app bundle. Each model keeps its own license, which is included in the downloaded package and can be opened from Settings → Speech → Local → License. The built-in list currently offers sherpa-onnx's conversion of SenseVoice Small (int8, 2024-07-17) and the Silero VAD model; read the license files shipped inside those packages before redistributing the models or building a product on them. Models listed in a remote update list are the responsibility of whoever publishes that list.

## On-device text recognition models (not bundled)

Like the speech models, the PP-OCR text recognition models are downloaded by the user inside the app and are not part of this repository or the app bundle. They are made by the [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) project and its converters; each package keeps its own license, which you should read before redistributing a model or building a product on it. The headers `tools/fetch-sherpa-onnx.sh` fetches for onnxruntime (MIT) are interface declarations used to call the library that is already linked; they are downloaded, SHA-256 checked, and not committed.

## Screenshot toolbar icons

The 39 toolbar and overlay icons (`resources/shot-*.svg`) were drawn for this project and are covered by the project license. They are not copied from or traced over any other application's icons or from any icon library.
