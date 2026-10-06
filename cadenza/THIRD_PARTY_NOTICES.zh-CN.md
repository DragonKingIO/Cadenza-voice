# 第三方说明

当前源码使用 macOS 系统框架及系统 zlib；本地模型权重从不随软件打包；执行过 `tools/fetch-sherpa-onnx.sh` 后，`build.sh` 会静态链接 sherpa-onnx 推理库（见下）。系统框架由 Apple 提供。zlib 的许可证见[官方说明](https://zlib.net/zlib_license.html)。未来分发第三方组件或模型时，必须逐项记录版本、来源、代码与权重许可证。

当前实现了讯飞 IAT、火山语音识别、腾讯实时语音识别、阿里 NLS 和百度短语音识别的协议适配。协议实现不等于真实账号验收，也不赋予重新分发服务商软件或模型的权利。

Apple Speech 使用系统 Speech 框架。

各服务商名称均为其所有者的商标，随言与其无关联，亦未获其背书。品牌材料不使用服务商 Logo。

## 本地推理（可选构建组件）

存在 `third_party/sherpa-onnx` 时，构建会静态链接 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) v1.13.8（Apache-2.0）及其包含的代码：ONNX Runtime 1.28.2（MIT，附其依赖的声明）、kaldi-native-fbank（Apache-2.0）、KISS FFT（BSD-3-Clause）、kaldi-decoder、kaldifst、OpenFst 与 simple-sentencepiece（Apache-2.0）、Eigen（MPL-2.0）、nlohmann/json（MIT）以及 hclust-cpp/fastcluster（BSD-2-Clause）。确切版本、来源和完整许可文本见 [licenses/](licenses/README.md)，每次构建都会把这个文件夹连同本文件复制进应用（`Contents/Resources/Licenses`）。这份清单已对照链接库里的符号核对过。

## 下载的模型（不随软件打包）

模型由用户在软件内下载，不属于本仓库或应用包。每个模型保留自己的许可证，随下载包一起提供，可在 设置 → 语音识别 → 本地 → 许可协议 中打开。内置清单目前提供 sherpa-onnx 转换的 SenseVoice Small（int8，2024-07-17）和 Silero VAD；再分发这些模型或基于它们做产品前，请先阅读包内的许可文件。远端更新清单里的模型由发布该清单的人负责。

## 截图工具栏图标

39 个工具栏与浮层图标（`resources/shot-*.svg`）为本项目原创绘制，适用本项目许可证；并非复制或描摹其他应用或图标库的图标。
