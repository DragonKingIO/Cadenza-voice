# 随言 · Cadenza

**随口说，随处写。** 在你自己的 Mac 上运行的 macOS 开源语音输入工具。

[English](README.md)

按住快捷键说话，松开，识别出的文字会写到光标所在的位置。默认用**本地模型在这台 Mac 上识别**；除非你主动选择云端服务并同意，否则不会上传任何东西。文字没法写入时，软件会保留下来，方便你复制。

> **状态：早期开发。** 维护者日常使用没有问题，但还没在很多环境里测试过，也没有验证所有应用的兼容性。非常欢迎反馈问题。

## 为什么用随言

- **隐私是设计前提。** 没有账号、没有服务器、没有统计、没有崩溃上报。本地识别时音频不离开这台 Mac；云端服务只有在你对该服务商明确同意后才会收到音频；服务密钥存放在 macOS 钥匙串；还有“永不联网”开关，隐藏一切可能联网的选项。
- **可以对比的本地模型。** SenseVoice（推荐）、FireRedASR2、Parakeet，通过 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 运行，在应用内下载并校验。“用我的声音比较模型”可以按你的声音挑最合适的，录音只保存在内存里。
- **云端服务自带账号，可选。** 讯飞、火山引擎、腾讯云、阿里云、百度、Deepgram，使用你自己的凭据；网络出问题时可以用本地模型继续识别。
- **能接硬件。** 默认关闭、只监听 `127.0.0.1` 的接口，让你自己的挂件、眼镜或按钮发送音频、取回文字。见 [本地接口](cadenza/docs/LOCAL-API.md) 和 [硬件接入](cadenza/docs/HARDWARE-INTEGRATION.md)。
- **公开、可度量。** 识别效果的改动都用可重复的基准来证明（[ACCURACY.md](cadenza/docs/ACCURACY.md)）。
- 界面支持简体中文和英文。

## 安装

目前还没有发布版本，需要自己构建，几分钟即可。要求 Apple 芯片、macOS 26，并安装 Xcode 命令行工具：

```sh
git clone https://github.com/DragonKingIO/Cadenza-voice.git && cd Cadenza-voice
./cadenza/tools/fetch-sherpa-onnx.sh     # 可选：本地模型需要的推理库
./cadenza/build.sh --stage-only          # 生成 cadenza/build/stage.noindex/Cadenza.app.zip
```

解压后打开应用。自己构建的副本可以直接打开；下载的发布版是临时签名、没有公证，macOS 第一次会拦截：到 系统设置 → 隐私与安全性，下拉找到关于这个应用的提示，点“仍要打开”（macOS 15 起，右键“打开”已不能绕过）。因为每次临时签名的构建都是新的身份，重新构建或更新后 macOS 会再次询问下面的权限。完整说明见 [开发指南](cadenza/docs/DEVELOPING.md)（英文）。

**平台：** 目前只支持 macOS 26 及以上、Apple 芯片。原因，以及哪些部分可以复用于移植，见 [平台说明](cadenza/docs/PLATFORMS.md)（英文）。

| 权限 | 用途 |
|---|---|
| 麦克风 | 录音时采集你的声音 |
| 辅助功能 | 找到输入框并写入识别结果 |
| 输入监控 | 检测全局快捷键 |
| 语音识别 | 仅在使用 Apple 自带识别时需要 |

## 哪些已验证，哪些没有

SenseVoice 本地识别有基准测试，也在日常使用。除讯飞和 Deepgram 外，其他云端服务只用假的网络层测试过；讯飞和 Deepgram 也只用合成语音联网测试过。接口实现不代表你的账号、地区或套餐一定可用。服务商名称只是描述，不代表背书，随言与它们没有关联。

## 隐私

请阅读[隐私说明](cadenza/PRIVACY.zh-CN.md)和[使用条款](cadenza/TERMS.zh-CN.md)。日志只记录状态、错误和文字长度，代码不会把音频和识别内容写进去，也可以关闭日志。

## 参与贡献

欢迎所有人：代码、文档、用自己声音做的模型评测、问题反馈。从 [CONTRIBUTING.md](CONTRIBUTING.md) 和[开发指南](cadenza/docs/DEVELOPING.md)开始；请遵守[行为准则](CODE_OF_CONDUCT.md)，安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。命名规则见 [BRAND.md](BRAND.md)。

## 许可证

[MIT](cadenza/LICENSE)。第三方组件和模型见[第三方声明](cadenza/THIRD_PARTY_NOTICES.zh-CN.md)。
