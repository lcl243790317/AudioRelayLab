# 2026-10-07 本轮本地实现与验证

工作区：`D:/Codex projectless/Wechat delay playback app`。分支 `feature/revoice-ios-1.6.0`，初始 HEAD `36fa6e3`，初始工作区干净。未找到适用的 AGENTS.md。首次本地交付只编辑源码、测试和文档，未提交／推送／触发 CI／构建 IPA／合并／发布／部署；版本仍为 1.6.6 / build 16。下表保留这一阶段的实际证据。

## 实际执行

| 检查 | 本轮结果 | 证据边界 |
|---|---|---|
| Python CPU 回归 `unittest discover -s tests -v` | 94 项通过，12.349 秒 | 本地模拟服务、锁定 API 依赖，未连接真实 GPU |
| `scripts/static_check.py` | 通过；72 App Swift 文件、21 XCTest 文件 | 词法安全与资源／配置检查，非编译 |
| tree-sitter Swift 语法解析 | 94 个 App／XCTest／UI Swift 文件，无语法错误 | 非类型检查、SDK 验证或运行测试 |
| `git diff --check` | 通过 | 补丁空白检查 |
| Simulator Debug／XCTest／UI XCTest／小屏截图／iPhoneOS Release | 未执行 | Windows 无 Swift／Xcode／Simulator |
| 签名真机／设备端语音识别／听感／iOS 后台调度 | 未执行 | 无已连接签名设备 |

最初使用通用 Python 环境时缺少 FastAPI；已有 `.venv` 也未装 API 测试依赖，UTF-8 模式修复了 Windows 夹具编码读取问题。随后仅在本轮忽略目录安装项目锁定的 FastAPI 0.142.2、HTTPX 0.28.1、Pydantic 2.13.5、Starlette 1.7.0 及其 CPU 依赖，再完成 94 项全量回归。未改既有虚拟环境，未安装 GPU 推理依赖。语法探针使用 tree-sitter 0.25.2 与 Swift grammar，仅用于本地检查。

原始日志与临时 CPU 依赖位于 `dist/workshop-local-20261007/`（Git 忽略），包括 `python-tests-complete.log`、`static-check.log`、`swift-syntax.json`；未写入或覆盖旧版本测试报告。历史 249 XCTest／18 UI XCTest 不作为本轮结果。

## 已增加但尚未运行的 Swift 回归

新增 25 项 XCTest 和 2 项 UI XCTest。旧任务被新生成自动抛弃、选音频自动清空文字的旧断言已按当前行为修订；已通过的 Python 回归未为凑次数重复运行。

| 测试 | 验证的真实行为 |
|---|---|
| `RevoiceDraftAndRangeTests`（15 项） | 未提交内容和手改自动指令重启恢复、合并／后台保存、旧版／损坏 JSON、恢复副本、删除输入、写入失败／重试、识别失败、替换／追加／撤销、撤销保留后续手改指令、云端停止与识别取消隔离、手打保护、长音频指定区域、采样边界、素材代次、播放／混音隔离、录音拒绝／准备失败／取消 |
| `WorkshopNavigationTests`（4 项） | 实际 WAV 校验和离线混音成品正确选择／导航、不自动播放、不重置草稿、文件缺失／操作锁定、准备退出、旧 owner 清理保护、回听错误归属、正式状态保护 |
| `RevoiceJobTests`（新增 4 项） | 新草稿优先恢复，旧成品身份与文字不覆盖草稿；停止后的明确恢复沿用 ID／无提交／单次保存；实际 HTTP 下载与损坏文件失败分类、过期和恢复动作 |
| `RevoiceTests`（新增 2 项） | 429 明确未接受、固定 ID 手动重试、配置不匹配时允许修复并继续原任务 |
| `InteractionUITests`（新增 2 项） | 三类素材跳到播放页且未准备；工坊回听在标签／功能／选择器／设置／分享退出后停止 |

长音频夹具为 90 秒、三段不同 PCM 电平；测试读取 65～70 秒的实际样本平均值，与开头区域区分，验证处理的是指定内容，同时比较原文件字节保持不变。录音和识别失败使用注入／延迟夹具，云端使用 URLProtocol 模拟响应及现有 CI 可信 loopback HTTPS 下载服务，无付费请求。

## 下一步 Xcode 验证

在 macOS 使用现有 `build-ios.yml` 全量标准流程：安装锁定 CPU 依赖、生成音频夹具与 XcodeGen 工程、Simulator Debug build、启动可信本地 HTTPS 下载夹具、全部 XCTest、UI XCTest、小屏截图、iPhoneOS Release 和 IPA 结构验证。新增测试自动包含在源码目录目标内。重点看以下测试类以及既有音频安全、会话安全、任务恢复、混音、历史兼容和 UI 回归。

```text
RevoiceDraftAndRangeTests / WorkshopNavigationTests
RevoiceTests / RevoiceJobTests / RevoiceAutomaticInstructionTests
AudioSafetyTests / SessionSafetyTests / CoordinatorSafetyTests
VoiceMixTests / VoiceLabTests / AudioRangeAndDurationTests
HistoryCompatibilityTests / PlaybackLibraryRepairTests / LibraryVoiceFeedbackTests
InteractionUITests
```

首次本地交付后，用户在当前会话明确回复“授权”。本轮据此提交并推送已审查的源码、测试和公开文档到现有干净公开仓库 `lcl243790317/AudioRelayLab` 的 `feature/revoice-ios-1.6.0`，触发 `build-ios.yml` 普通完整运行（`diagnosticOnly=false` 默认），并修复构建中实际发现的问题。不合并 main，不创建 Release，不部署，不访问私有历史作为构建源；下载验证材料放入新的 run 专属目录，不覆盖历史证据。远端结果须另行记录，不能用本地静态结果代替。

## 真机操作清单

1. 在新源码的签名构建中编辑文字、自定义基础指令与自动手改指令，选择输入和识别片段；切后台再重启，核对全部恢复，确认没有自动生成。
2. 先写原稿，拒绝麦克风／语音识别权限，取消录音，模拟准备失败或设备端识别不可用；每步确认原稿和输入仍在。分别测试替换、追加、撤销；识别期间手打或切换素材后确认旧结果不覆盖新上下文。
3. 导入超过 60 秒、不同时间有不同语句的录音，选择后半段 0.3～60 秒；核对识别语句来自该片段。修改播放起止、倍速、试听位置和音乐片段后再次核对识别区间未变。
4. 手动生成一份任务，马上编辑新文字与新声线；切到微信／锁屏／断网后返回，确认仍取回原 ID 和原内容，新草稿不变。取回同时识别新片段，分别取消识别／停止云端等待，确认互不误停。停止等待后返回／重启，确认迟到结果不入库，再在最近任务手动继续取回，核对只入库一次。
5. 在有旧任务时打开并修复连接配置，核对提示和取回动作；观察真实忙碌／限流、网络、认证、过期、生成、校验和存储失败时的对应路径，不使用付费 GPU 做普通回归。
6. 配音、混音和音频库分别“用于播放”，核对正确名称、播放标签、延迟与主要操作，确认没有自动试听／倒计时。删除目标文件或在正式播放期间操作，确认保留页面和有效选择并显示错误。
7. 普通／五秒试听、库回听、配音／混音及电脑成品回听分别在准备中和播放中切标签、切功能、打开选择器／连接／分享，确认停止且返回不恢复；马上从另一页面回听，确认旧页面清理不误停新回听。
8. 手动启动正式延迟播放，切页并触发试听退出清理，确认正式倒计时和播放继续。检查 App 正式音量与试听音量的独立效果。
9. iPhone SE 等小屏、普通字号和辅助大字体、浅／深主题检查键盘、底部生成按钮、Tab 栏、片段字段和成品按钮。

## 剩余边界

没有发现并保留已知未修复的本轮源码缺陷；Swift 类型检查与上述行为运行尚未完成，因此仍可能在 Xcode 验证中发现问题。强制终止发生在 450 ms 合并写入之前时，最新按键可能未持久化；正常失活／后台会立即 flush。存储空间或文件保护错误会明确报告失败。撤销只保留当前会话最近一次识别修改。

旧同步服务没有异步取回能力，仅保留前台兼容路径；完整任务恢复针对现有 asyncJobs 服务。停止后仍未知状态的旧任务须明确取回或等待窗口过期，保持单任务策略。真机设备端识别质量、重签名权限、听感、路由和 iOS 后台调度尚无本轮证据。
