# 公开语音测试集

帮我们衡量和修复随言的识别准确率：在浏览器里照着脚本念几句话，同意的话把录音发给我们。

英文版：[README.md](README.md)。

- 录音器（网站 PR 部署后可用）：https://dragonkingio.github.io/cadenza-site/record/
- 脚本：[script.md](script.md)（机器可读版 [script.json](script.json)），共 90 句普通话，分短句、中句、长句、中英夹杂、语气词与疑问、数字和日期六类。
- 同意书：[CONSENT.zh-CN.md](CONSENT.zh-CN.md)

## 怎么参与

1. 打开录音器，阅读同意书，选择授权 A（公开，CC0）或 B（仅用于评测），并填写元信息。
2. 用平常说话的语气逐句朗读。每句都可以重录、回放或跳过。电平条会提示声音太小或爆音。
3. 全部录完后下载 zip 文件。页面不会上传任何东西。
4. 按录音器最后一页的说明，把 zip 文件发给我们。

## 收集什么、不收集什么

收集：WAV 录音（16 kHz、单声道）、参考文字、随机参与编号、口音或地区、麦克风类型，以及选填的性别和年龄段。不收集：姓名、账号、位置，也不读取你设备上的任何东西。

数据只用于衡量和修复识别准确率，不用于训练模型。选 A 的录音会按 CC0 发布在需要申请才能下载的数据集里；选 B 的录音保持私有，并在你要求时删除。

## 本文件夹内容

| 文件 | 用途 |
| --- | --- |
| `script.md`、`script.json` | 朗读脚本，唯一来源 |
| `CONSENT.md`、`CONSENT.zh-CN.md` | 同意书，带版本号 |
| `DATASET_CARD.md` | Hugging Face 数据集说明草稿 |
| `HF_SETUP.md` | 维护者创建数据集和处理投稿的步骤 |
| `DISCUSSION_POST.md`、`DISCUSSION_POST.zh-CN.md` | GitHub Discussions 征集帖草稿（尚未发布） |

音频绝不进入本仓库。
