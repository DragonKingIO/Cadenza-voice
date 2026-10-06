> This is the original stage 1 description of the trigger state machine; the later stages build on it.

# 混合触发模式：阶段 1（2026-10-02）

阶段 1 已完成；没有接入应用。停止在本阶段，等待审查。

## 范围与复现

新增独立 Swift Package：`Sources/TriggerCore/TriggerStateMachine.swift`、`Tests/TriggerCoreTests/TriggerStateMachineTests.swift`、`Package.swift`、`run-tests.sh`、`.gitignore`，以及本报告与 evidence 文件。

状态机没有 import，没有 UI、系统事件、音频、网络或定时器副作用。时钟通过 `TriggerClock` 注入；事件返回状态和有序动作。它位于现有 `src/` 之外，`build.sh` 的 `src/*.swift` 不会包含它。

```sh
./cadenza/trigger-state-machine/run-tests.sh
```

使用 Apple Swift Testing。当前仅安装 Command Line Tools，没有可导入的 XCTest；脚本为 CLT 的 Testing.framework 和 lib_TestingInterop.dylib 设置搜索路径，不安装依赖、不修改现有脚本。

- 37 个测试，0 失败：`evidence/unit-tests.log`。
- 现有应用以 arm64、macOS 26 deployment target、Swift 5 模式编译成功，12 条既有警告：`evidence/existing-app-compile.log`。只输出临时可执行文件，未启动、未签名、未安装。
- 39 个原有源码、构建脚本及资源文件的前后 SHA-256 全部一致：`evidence/existing-file-hashes.json`。
- 没有修改 Bundle ID、签名、钥匙串、用户配置或已安装的应用。
- Git 原仓库无提交。因此先将上述现有文件建立原样基线提交 `5b66b10`，再对阶段 1 新文件做独立提交；分支 `codex/mixed-trigger-stage1`。没有提交其他历史文档、构建产物或用户数据，没有推送。

## 已实现的纯逻辑契约

- 状态 idle / armed / holding / locked / recognizing / inserting / cancelled / error。
- 按下立即输出 startCapture；armed 期间不输出上传动作。
- 默认 T=300ms，可配置 200–600ms。达到 T 转 holding 并仅输出一次缓存放行；干净短按转 locked 并放行。
- 仅按住仍按下开始、松开结束；仅点按及可选独立点按键用再次按下结束。
- 有效 PCM 样本时长不足 0.5s，在结束时丢弃。极短按压小于 60ms 直接丢弃，输出 tooShort 原因，由后续界面本地化。
- 缓存上限通过 startCapture 动作传给执行层；默认 64,000 bytes，阶段 2 按归一化 PCM16/16kHz/mono 执行实际上限。溢出事件触发错误、清理与丢弃。阶段 1 不存储任何音频。
- locked 默认 10s 无人声取消；人声输入重置计时，非人声不重置。引擎最长时长由配置注入。
- 单修饰键物理按下期间其他键取消；判定点前取消不产生缓存放行动作，判定点后取消停止后续流。
- 重复按下忽略；识别和插入期间触发键忽略；sessionID 隔离过期回调。
- 录音状态请求安装 Esc 监听；退出录音状态请求移除。这里是动作契约，尚未创建 CGEventTap。
- 识别结果输出 insertOrCopy，由协调器检查当前焦点，执行后反馈 inserted / copiedToClipboard / failed。阶段 1 没有执行输入或剪贴板操作。
- 未授权麦克风、缺失云端凭据、未同意云端上传分别返回错误原因；未同意云端时三种模式均无采集或提交动作。执行层在放行时仍必须重新检查同意状态。

## 两个澄清

**无人声检测**：拟由阶段 2 的统一本地 PCM 能量检测器提供 speechDetected（电平阈值、连续帧与滞回），不使用厂商识别结果作判断。它是能量近似，不能保证区分人声与电视、键盘、环境噪声；具体阈值和连续帧长度要在实际麦克风上校准。当前 `AudioSignalEvidence` 只判断数字零静音，不具备这项能力。状态机只消费有效 PCM 时长和 speechDetected，因此可独立测试，不耦合检测算法。

**与 ShortcutCycle 的关系**：阶段 2 保留其物理键身份、左右修饰键、按键重复与完整按键周期校验，去除它对语音会话的直接回调。它输出归一化的 keyDown / keyUp / otherKeyDown；TriggerStateMachine 是唯一的手势及会话状态所有者。DualShortcutCycle 的生产路由需要替换为同一协调器的主键和独立点按键入口，不能两套同时决定开始或结束。阶段 1 未修改它们。

## 必须澄清的隐私边界

按修订后的规则，短按锁定和长按达到 T 都会开始上传。

- 因此第 4 条「锁定后按 Esc，没有任何上传」与判定点放行规则冲突。此时只能停止未来上传并丢弃本地音频／结果，不能撤回已经提交给引擎的音频。
- 第 5、13 条的零上传只适用于判定点之前出现的组合键。T 后再按字母仍取消，但无法承诺之前没有上传。
- 第 6 条在极短轻点及未达判定点结束时可零提交；达到 T 后再结束但不足 0.5s，可丢弃结果，之前的上传也无法撤回。

测试 `testChordBeforeThresholdDiscardsWithZeroCommitActions`、`testChordAfterCommitStopsStreamCannotUndoEarlierSubmission`、`testEscapeWhileLockedStopsAlreadyCommittedStream` 明确覆盖这些区别，不把停止上传写成从未上传。阶段 2 前需要审查这项用例边界。

## CGEventTap 权限核对（尚未实机验收）

Apple 的 WWDC19《Advances in macOS Security》明确区分：listen-only tap 需要输入监控授权；修改事件流的 defaultTap 需要辅助功能授权。

https://developer.apple.com/videos/play/wwdc2019/701/

阶段 2 只在录音期间尝试安装 active session tap，检查实际创建结果；失败尝试只监听降级，并明确显示 Esc 不被吞掉。退出录音后立即移除。回调只做快速事件判定，不执行录音、网络或 UI。超时禁用时仅在仍处于录音且权限有效时有限重启，否则降级并释放；用户禁用不强行循环重启。未在阶段 1 创建任何 tap，macOS 26 下的创建、吞键、降级及正常键盘输入均尚未验证。

## 16 条应用验收记录

以下是应用级用例，不把假时钟测试当实机通过。阶段 1 无新 UI，因此没有 HUD／设置截图；截图在阶段 3 提供。

| # | 用例 | 当前结论 | 阶段 1 证据／缺口 |
|---|---|---|---|
| 1 | 长按 1s，松开出字 | 未通过（未集成实测） | 长按放行和识别动作测试通过；实际录音及文字插入未验证 |
| 2 | 短按、说话、再次短按出字 | 未通过（未集成实测） | locked 及再次按下结束逻辑通过；真实音频未验证 |
| 3 | 短按后无声 10s 自动取消 | 未通过（未集成实测） | 默认与自定义超时、声音重置、噪声不重置逻辑通过；检测器未接入 |
| 4 | locked 后 Esc，丢弃且零上传 | 未通过（规格冲突） | Esc 丢弃逻辑通过；锁定放行后不能声称零上传 |
| 5 | Option 加字母取消，不保留、不上传 | 未通过（未集成实测） | T 前无放行动作通过；T 后零上传要求冲突；实际键盘与网络未测 |
| 6 | 极短轻点丢弃并提示太短 | 未通过（未集成实测） | 10ms、60ms 边界与 0.499/0.5s 音频边界通过；提示 UI 未接入 |
| 7 | 切应用，非编辑焦点复制并提示 | 未通过（未集成实测） | insertOrCopy 与 copiedToClipboard 回执通过；真实焦点和剪贴板未测 |
| 8 | 引擎最长时长自动结束识别 | 未通过（未集成实测） | holding、locked 最长时长逻辑通过；实际引擎上限未接入 |
| 9 | 识别期间按键被忽略，HUD 不乱 | 未通过（未集成实测） | recognizing/inserting 按键忽略通过；HUD 未接入 |
| 10 | 三种选择生效，仅按住保持行为 | 未通过（未集成实测） | hold/toggle/hybrid 逻辑通过；旧行为对照及设置未测 |
| 11 | 拒绝麦克风、缺凭据的操作提示 | 未通过（未集成实测） | 不同错误原因通过；权限实测与提示操作未接入 |
| 12 | 未同意云端，全部模式无音频请求 | 未通过（未集成实测） | 三种模式均无采集／放行动作通过；没有实际执行器网络日志证据 |
| 13 | 组合取消，日志或抓包确认零音频 | 未通过（未集成实测） | T 前 action trace 零放行通过；不作为实际抓包证据；T 后规则冲突 |
| 14 | 非录音 Esc 正常传递 | 未通过（未集成实测） | shouldInterceptEscape=false、escape 无动作通过；实际 tap 未测 |
| 15 | 重复事件不重复触发 | 未通过（未集成实测） | 重复键和重复 down 逻辑通过；实际系统事件未测 |
| 16 | 混合主键与独立点按键共存 | 未通过（未集成实测） | 独立点按开启／关闭及非对应 keyUp 逻辑通过；热键路由未接入 |

阶段 2、3、4 未开始；中英本地化资源复制、Brand.name、原生 Form、Preview、VoiceOver、减弱动态、提示音、菜单栏和 HUD 截图均留待对应阶段验证。
