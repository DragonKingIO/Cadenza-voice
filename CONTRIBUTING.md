# Contributing to Cadenza · 随言

Thank you for helping. Cadenza is a local-first voice input app for macOS, and it is built in the open so that anyone can
improve it. You do not need to be a Swift developer: documentation, model evaluations on your own voice, and bug reports are all
real contributions. 中文说明见本文末尾。

## Ways to help

| You want to… | Start here |
|---|---|
| Report a bug | Open an issue with the **Bug report** form. Do not attach recordings, transcripts or unredacted logs. |
| Suggest a feature | **Feature request** form; for large changes please discuss before writing code. |
| Translate the app into your language | **Add a language** form first: adding a third language still needs some code work, see [Adding a language](cadenza/docs/DEVELOPING.md#adding-a-language). |
| Propose a speech model | **Model request** form. We need the license, size, checksum and benchmark numbers. |
| Add a cloud speech service | **Cloud provider** form, then [Adding a cloud provider](cadenza/docs/DEVELOPING.md#adding-a-cloud-provider). |
| Improve the docs | Edit any `.md` file and open a pull request. Small fixes need no issue. |
| Fix a bug or build a feature | [Developing Cadenza](cadenza/docs/DEVELOPING.md), then follow the pull request steps below. |
| Report a security problem | **Do not open a public issue.** See [SECURITY.md](SECURITY.md). |

Issues labelled `good first issue` are chosen to be approachable.

## The privacy contract

Cadenza's promise is that nothing leaves the Mac unless the user turns it on. Every change is reviewed against it:

- No telemetry, analytics, crash reporting, update pings or any other network request that the user did not ask for.
- Cloud upload only after the user's explicit, per-provider consent, and the privacy text must describe the real boundary
  (audio already streamed cannot be recalled by cancelling).
- Recordings and transcripts are never written to disk or to logs. Logs may contain state, errors and text *lengths*.
- Credentials live in the macOS Keychain, never in files, logs, URLs or test fixtures.
- Never commit API keys, credentials, recordings, private transcripts, screenshots of private content or absolute paths
  from your own machine. Run `cadenza/tools/check-no-secrets.sh --staged` before every commit.

## Pull requests

1. **Fork and branch** from `main`. Keep one topic per pull request.
2. **Build and test** locally (see [Developing Cadenza](cadenza/docs/DEVELOPING.md)). A pull request that changes behavior
   needs a test that fails without the change.
3. **Describe it honestly**: what changed, how you tested it, and what you could *not* test (a real microphone, a real
   provider account, a real third-party app). Do not describe a fake transport or mock recorder as a verified service.
4. **Sign off** every commit (`git commit -s`). This adds `Signed-off-by:` and states you may submit the work under the
   project license ([Developer Certificate of Origin](https://developercertificate.org/)). There is no CLA.
5. **Be patient and kind.** Reviews are done by volunteers. See the [Code of Conduct](CODE_OF_CONDUCT.md).

## Project rules

- Discuss large changes in an issue before implementation.
- User-facing text belongs in `Localizable.strings` for English and Simplified Chinese. Product names come from
  `Brand.name`. Follow [BRAND.md](BRAND.md). Never show both product names in one UI.
- Trigger behavior has one state owner, `TriggerStateMachine`, and deterministic tests using an injected monotonic clock.
  Run `./cadenza/trigger-state-machine/run-tests.sh`.
- Do not change the Bundle ID, signing identity, Keychain identifiers or compatibility storage paths during a branding change.
- Separate implementation, unit tests, integration tests, and real microphone or provider acceptance. Report which of
  these were done.
- Keep `triggerCoordinatorEnabled=false` unless a maintainer has accepted the real-device acceptance for that stage.
- Preserve the existing license and copyright notice unless the rights holder explicitly authorizes a correction.
- Third-party code, models and artwork need a compatible license and an entry in `THIRD_PARTY_NOTICES.md`.

## Releases

Maintainers cut releases. Builds you make yourself are signed ad hoc and macOS will ask you to approve them. They are for
development, not for distribution.

---

## 中文说明

欢迎一起完善随言。你不一定会写 Swift：翻译、文档、模型评测和 Bug 反馈都算真正的贡献。

- **隐私约定**：除非用户主动开启，任何数据都不能离开这台 Mac。不允许加入统计、崩溃上报等未经用户同意的网络请求；云端上传必须有按服务商的明确同意；录音和识别文字不写入磁盘和日志；凭据只放钥匙串。
- **提交前**运行 `cadenza/tools/check-no-secrets.sh --staged`，不要提交密钥、录音、含个人信息的截图或你本机的绝对路径。
- **提交 Pull Request**：从 `main` 派生分支，一个主题一个 PR；改行为必须带测试；如实说明哪些没法测试（真实麦克风、真实服务商账号等）；每个提交用 `git commit -s` 签署（DCO，无需签 CLA）。
- **构建**：没有维护者的签名证书也可以，用 `./cadenza/build.sh --stage-only`，详见 [cadenza/docs/DEVELOPING.md](cadenza/docs/DEVELOPING.md)。
- 发现安全问题请**不要**公开提 Issue，见 [SECURITY.md](SECURITY.md)。
