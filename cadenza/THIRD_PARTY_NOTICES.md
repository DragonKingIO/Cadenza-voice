# Third-party notices

The current source imports macOS system frameworks and zlib. Local-model weights are never bundled. When `tools/fetch-sherpa-onnx.sh` has been run, `build.sh` statically links the sherpa-onnx inference library (see below). macOS frameworks are supplied by Apple. zlib is supplied by the system; see its [license](https://zlib.net/zlib_license.html). Future bundled dependencies and model weights must have their versions, source URLs, and code/weight licenses documented before distribution.

## Speech services

The source includes protocol adapters for iFLYTEK IAT, Volcengine speech recognition, Tencent Cloud real-time speech recognition, Alibaba Cloud NLS, and Baidu short speech recognition. Implemented adapters do not establish live-account acceptance or rights to redistribute any provider's software or models.

Apple Speech uses the system Speech framework.

Provider names are trademarks of their respective owners. Cadenza is not affiliated with or endorsed by them. No provider logos are used in the branding material.

## Local inference (optional build component)

Builds made with `third_party/sherpa-onnx` statically link [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) v1.13.8 (Apache-2.0) and the libraries packaged with its release: ONNX Runtime (MIT), kaldi-native-fbank (Apache-2.0), kaldi-decoder (Apache-2.0), KissFFT (BSD-3-Clause), OpenFst/kaldifst and sentencepiece (Apache-2.0). Their full license texts ship with the upstream release archive named in `tools/fetch-sherpa-onnx.sh`; include them when distributing a binary. Verify these license names against the upstream archive before a public release.

## Downloaded models (not bundled)

Models are downloaded by the user inside the app and are not part of this repository or the app bundle. Each model keeps its own license, which is included in the downloaded package and can be opened from Settings → Speech → Local → License. The built-in list currently offers sherpa-onnx's conversion of SenseVoice Small (int8, 2024-07-17) and the Silero VAD model; read the license files shipped inside those packages before redistributing the models or building a product on them. Models listed in a remote update list are the responsibility of whoever publishes that list.

## Screenshot toolbar icons

The 39 toolbar and overlay icons (`resources/shot-*.svg`) were drawn for this project and are covered by the project license. They are not copied from or traced over any other application's icons or from any icon library.
