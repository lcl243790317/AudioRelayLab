# 2026-10-07～08 草稿与工坊功能：本轮 macOS 验证

本报告记录当前会话用户明确回复“授权”后的远端验证，与 [首次本地验证](WORKSHOP-LOCAL-VALIDATION-ZH.md) 和历史 1.6.6 报告分别保留。只使用现有干净公开仓库 `lcl243790317/AudioRelayLab` 的 `feature/revoice-ios-1.6.0`，运行现有 `build-ios.yml` 的普通完整流程（`diagnosticOnly=false`）；没有合并 main、创建 Release、部署、变更云端配置或调用真实 GPU。

## 构建记录

| Actions run | 源码 | 本轮实际结果 |
|---|---|---|
| [23 / 37714884939](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37714884939) | `638f77b56b827152208dfaf9c9e4900ec3fbeee3` | Python 94 项通过（45.002 秒）；静态检查与工程生成通过。Simulator Debug 编译失败：`URLError.Code(rawValue:)` 非可选结果被用于可选绑定。未运行 XCTest／UI，未生成 IPA。 |
| [24 / 37715213394](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37715213394) | `39ad349e62195d4da76e142ea559a4d8de98435a` | Python 94 项通过（44.113 秒）；Simulator Debug 编译通过；274 项 XCTest 0 失败（108.681 秒）。UI 执行 20 项、18 通过、2 失败（1806.950 秒）；小屏、iPhoneOS Release 和 IPA 因 UI 失败未执行。 |
| [25 / 37733320493](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37733320493) | `1376df95974855ba329dae50a1eda84450a134a4` | 两处 UI 定位已修复。继续核对 D 时发现播放页保留滚动位置可能隐藏新素材，追加定位修复后主动取消这次过时运行；未完成全量测试，不计通过证据。 |
| [26 / 37733946738](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37733946738) | `75be5eb8211f9410594d1b66718a2a56f3ed33ac` | Python 94 项通过（44.078 秒）、静态检查、工程生成及 Simulator Debug 编译通过。XCTest 前 loopback HTTPS 夹具在约 13 秒等待内未就绪，curl 退出 7；尚未开始 XCTest／UI，没有 IPA。 |
| [27 / 37735342213](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37735342213) | `727a3469afa19f669d233b09f86098238b6b57f4` | Python 94 项通过（43.731 秒）；Simulator Debug 编译通过；274 项 XCTest 0 失败（107.583 秒）。20 项 UI 中 19 通过、1 失败（1806.800 秒）：退出多选后混音来源名称定位。小屏、iPhoneOS Release、IPA 因 UI 失败未执行。 |
| [28 / 37813461196](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37813461196) | `af65c32fe910a50bfe2685840da395ce1328ed1d` | 关机恢复后修正混音来源显示及定位；尚在排队时发现失败反馈会被长列表遮住，补充修复后取消这次过时运行。不计为测试通过证据。 |
| [29 / 37815191810](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37815191810) | `7a6dcc7d0386b0a953644e81058f73edac67dcaa` | 17:15 UTC 触发，17:30 UTC 平台结束：未取得托管 runner，主任务取消、workflow failure。步骤为空，无测试、无 Artifact、无 IPA；官方注释提示 macOS arm64 容量不足。 |
| [30 / 37817892773](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37817892773) | `5d92321905e7096a8f63cfb2158a4a0090173d4b` | Python 94 项通过（43.448 秒）；Simulator Debug 通过；274 项 XCTest 0 失败（131.142 秒）。UI 完成 15 项：13 通过、2 失败；第 16 项执行中超过 75 分钟任务时限，官方结论 cancelled，没有完整 UI 汇总。小屏、iPhoneOS Release、IPA 未执行。 |
| [31 / 37830588378](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37830588378) | `a89d6b303f13512915b99e5eab45121275d9e601` | 补充真实正式倒计时回归后主动取消过时验证，Simulator 编译中止；XCTest／UI／小屏／Release／IPA 未执行，不计全量通过。 |
| [32 / 37831419860](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37831419860) | `8c5a7ea4ad469c2046a39ccf9a7d8cf76139a413` | Simulator Debug、XCTest 步骤成功；UI 阶段触及 150 分钟任务时限，21:57 UTC 官方结论 cancelled。原始日志与 Artifact 不可用，不能核对实际用例数量／UI 失败位置。小屏／Release／IPA 未执行，无新 IPA。 |
| [33 / 37853382189](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37853382189) | `a3c7233316f10cf076c777e91205b0505cff32a1` | Python 98 项通过（46.071 秒）、Simulator Debug 通过；发现空草稿识别入口被旧云端任务误禁用，修订后取消过时运行，22:35 UTC 结束。原生测试尚未开始，小屏／Release／IPA 未执行。 |
| [34 / 37854548644](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37854548644) | `e9619d8e901245fc7b9a3330a9d4316f7fbcb6ea` | Simulator Debug 步骤成功；补齐批删用例实际时限后主动取消过时验证。原生测试阶段取消，UI／小屏／Release／IPA 未执行，不计全量通过。 |
| [35 / 37855655509](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37855655509) | `094cb0106e8dc9c9f12da4169080fea7666d48d6` | Python 98 项通过（46.100 秒）、Simulator Debug 通过；275 XCTest 0 失败（147.201 秒）。UI 日志记录 20 用例开始，17 通过、2 失败、1 超时；小屏／Release／IPA 因 UI 失败未执行。00:59 UTC 结束，结论 failure。阶段日志已取回，按用户要求暂停。 |

第 24 次运行的两项 UI 失败均已定位到测试断言：

- 混音详情已经按本轮要求显示“人声：批删测试原声”，旧断言仍查找 UUID 前缀。改为验证可读名称，仍检查进入多选后详情隐藏、退出后恢复且折叠。
- 真实系统分享页已经出现，失败附件的 accessibility hierarchy 记录关闭按钮标识为 `header.closeButton`，label 为小写 `close`；旧测试只查找“关闭”或大写 `Close`。改为检查分享页出现、点击实际按钮、等待分享页消失，再核对回听已停止。没有改变产品分享流程或跳过分享回归。

第 24 次 Artifact `11524004560`（735,847,571 字节）已下载并核对官方 SHA-256：`4ca1b65ed9f1bb956bb27778bbe8a175399ba96b5f472add25a019931081179d`。原始失败记录保持，不把这次 UI 结果改记为通过。两处断言修复后继续标准完整流程；后续结果另行追加。

播放页定位使用独立的一次性导航请求和 `ScrollViewReader`，只在明确“用于播放”成功后显示素材卡片；普通返回、选择失败和过时回调不会消费新的请求。没有通过重设整个页面 identity 来清空编辑状态，也不开始播放或倒计时。

第 26 次失败产物 `11530793341`（137,590 字节）已核对官方 SHA-256：`2fb48c814eb6b47413ef4f013a23f0fc82c047d224ef2b07613a649dc79ae487`。夹具进程被清理时仍存在，`build-revoice-network.log` 为 0 字节，没有 Python 异常或应用测试失败记录；不据此推断具体宿主机性能原因。就绪检查改为最多 60 秒，检测进程提前退出并保留启动耗时及失败日志；只重试连接拒绝／连接超时，证书和 HTTP 错误立即失败，不放松生产 TLS 或跳过下载测试。

实际 runner 环境（第 23 次运行）：macOS 26.6.2 / 25G83，Xcode 26.6 / 17F113，iPhoneOS SDK 26.5，Apple Swift 6.3.3。该环境不能代替 iOS 18.1.1 签名真机。

第 29 次属于 runner 分配失败，不能计为应用编译或测试失败。为继续验证，工作流改用标准 `macos-26-intel`（[GitHub 官方标准 runner 表](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)），仅改变 CI 宿主机架构，保持全部测试、下载夹具、签名禁用、SHA 核对和 IPA 校验。公开仓库使用该标准池免费；没有选择 larger runner。

就绪检查修订后，Windows 本地 YAML 解析、项目静态检查与 `git diff --check` 通过；现有 `test_record_ci_result.py` 的 12 项证据判定回归通过（0.004 秒）。这些检查不计为 Swift 编译或 Simulator 测试结果。

2026-10-08 关机后恢复检查：源码和测试已保存在 `727a346`，仅两份验证文档尚未提交，均保留。远端 CI 不依赖本机持续开机，第 27 次运行已完成。新增的成品导航（86.260 秒）与工坊回听退出（160.642 秒）UI 均通过；可信 HTTPS 夹具实际在 40 秒后就绪，9 次成功下载、2 次 202、0 次拒绝，未收到长期凭据。

第 27 次 Artifact `11533690648`（744,099,195 字节）已核对官方 SHA-256：`d30b83322c9daa0e088f94cae85c435bb531c6e054d06ea7f00a4b9d9f600e4b`。失败测试录像显示混音来源已展开，旧素材显示名包含来源类型和短 ID，导致旧固定前缀查询未命中。来源栏改用原素材名称，加上稳定的 accessibility 标识；回归继续检查多选时隐藏、退出后折叠、再展开后两种原素材名称可见且不追加内部短 ID。保留这次真实失败记录，继续全量标准 CI。

随后补齐“用于播放”失败反馈：验证／操作锁定失败时统一展示可读错误弹窗，原页面及有效选择保持。扩展现有导航 UI 回归，以 DEBUG 专属已删除的本地成品实际触发失败，确认弹窗、原页面、原选择和未准备状态；单元回归继续确认正式状态不变。测试数量仍为 274 XCTest／20 UI，不增加付费服务请求。

第 30 次 Artifact `11571264458`（320,712,162 字节）已下载并核对官方 SHA-256：`c7a5d71e4ca0478226e48c363474a2c692bcb959410255e23384807a25834fb3`。官方任务注释明确为 `The job has exceeded the maximum execution time of 1h15m0s`；18:56 UTC 发出的停止请求用于取得诊断，不能把这次取消记为通过。失败录像显示选择器已出现且键盘已收起，3 秒 AX 等待未及时结束；另一失败时 11.7 秒音频已接近结束。修订键盘检查，先等待选择页出现，再验证键盘消失；普通试听退出使用 DEBUG 专属实际长 PCM 文件。五秒试听自然结束后保留本页实际进度，退出／取消仍清零，UI 核对真实进度和退出状态，并新增原生播放器完成／准备取消／播放取消回归（当前应执行 275 XCTest／20 UI）。正式五秒时限保持不变。任务总时限改为 150 分钟，保持全量测试与小屏、Release、IPA 检查。

第 31 次（run `37830588378`，源码 `a89d6b3`）启动后，继续核对发现正式播放保护回归仅覆盖准备阶段。现扩展同一回归：实际调用开始并等待原生播放器进入未来倒计时，再验证选择失败和页面试听清理保持正式状态与有效选择。测试总数不变；取消这次过时运行，修订后继续标准完整流程，不把部分步骤记为全量通过。

第 32 次官方注释为 `The job has exceeded the maximum execution time of 2h30m0s`。Simulator Debug 步骤 19:26:18～19:30:27、XCTest 步骤 19:30:27～20:00:33 成功；完整 UI 步骤 20:00:33～21:53:06 被取消。最终上传 21:53:09 开始，主任务 21:57:18 结束，API 没有任何 Artifact；job 日志接口 404，下载的整 run 日志 ZIP 为 22 字节空归档。不能从步骤成功推断实际 275 项全部执行，也不能断定卡在 UI 用例或录屏清理。

根据这次证据缺失，小范围修订 CI：XCTest／UI 结束分别先上传轻量日志，最终大产物使用压缩级别 1；录屏进程清理改为有时限的自有进程组操作，保留真实测试退出码并解码验证视频。UI 默认单用例 600 秒，多上下文试听回归显式 1800 秒，最大 1800 秒；依据 [Apple XCTest 时限说明](https://developer.apple.com/documentation/xctest/xctestcase/executiontimeallowance) 和 [Xcode 11.4 参数说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-11_4-release-notes)，超时必须记为失败。任务总时限 240 分钟，完整 275 XCTest／20 UI／小屏／Release／IPA 均保留；没有改 App 行为、跳过断言、自动重试失败用例或更改 GPU。

2026-10-08 本地新增验证：4 项实际子进程清理回归通过（1.753 秒）；全部 Python CPU 回归 98 项通过、0 失败／错误／跳过（测试 14.332 秒，含发现用例共 15.500 秒），实际本地模拟服务运行，不调用真实 GPU。受限沙箱内的第一次 loopback 测试被网络边界阻断，保留未完成日志，仅精确终止本轮自有 launcher 与子进程；授权后的完整执行另存日志。实际 H.264 MP4 解码出画面，损坏 MP4 被拒绝。静态检查仍为 72 App／21 XCTest 文件通过；新 workflow YAML 与修改的 UI Swift 语法解析、`git diff --check` 通过。这些 Windows 结果不计为 Swift 编译或 Simulator 运行。

第 33 次运行期间继续核对入口：文字为空且已经选音频时，底部“识别文字”仍复用了云端生成的禁用条件，旧任务会使设备端识别不可操作。现按实际操作区分：识别只受本地音频操作锁限制并直接调用识别器；有文字时的新生成仍受旧任务限制。扩展现有原生回归，在旧任务保留时实际识别空草稿、撤销并继续并发识别／停止云端等待；同一 UI 回归增加空稿＋真实本地输入的启用检查及旧取回入口保护。总数仍为 275 XCTest／20 UI，未触发实际云端请求。4 个修改的 Swift 文件语法解析与项目静态检查通过，Xcode 行为须由下一次完整运行确认。

第 33 次的轻量检查点 `11582654967` 已实际下载并核对官方 SHA-256：`edecfe11fdf8ac88ac256fc0a86ca4120296d9d47ea48b4e3e0710d6a558b6d3`（22,890 字节）。原始日志确认 Python 98 项 0 失败／错误／跳过（46.071 秒）及 Simulator Debug BUILD SUCCEEDED，尚没有 build-xctest.log。阶段日志在取消后仍能取回，不等于未执行的 XCTest／UI／Release／IPA 已通过。

补充核对第 30 次全部已完成用例耗时：批量删除回归实际通过耗时 697.099 秒，超过新增的 600 秒默认单用例上限。该多步骤用例也显式设为 1800 秒，其他断言与数量不变；修订后需要新的标准完整运行，第 34 次作为过时验证取消，不计为当前源码全量通过。

第 35 次 XCTest 检查点 `11584782692`（61,075 字节）已实际下载并核对官方 SHA-256：`869c93d5e4fe9edbcfdc3709715451539dac83047cfe620d0c35bdb940d65ea8`。原始日志确认 Python 98 项通过（46.100 秒），Simulator Debug BUILD SUCCEEDED，275 XCTest 全部通过、0 失败（147.201 秒）；新增的草稿／区间 15 项、导航／试听 5 项及旧任务保留时空草稿识别的扩展回归均已执行。实际环境为 macOS 26.6.1 / 25G76、Xcode 26.6 / 17F113、iPhoneOS SDK 26.5、Swift 6.3.3，不能代替签名真机。实时网页只显示部分日志行，不能从可见末行判断截图命令卡住；阶段归档确认本次运行继续并完成原生测试，未因此修改工作流或取消正在推进的验证。原生日志有两条测试代码 `defer` 位于作用域末尾的编译提示，清理仍执行，测试未失败。完整 UI 于 23:10:32 UTC 开始，其结果、小屏、Release 和 IPA 另行核对，不从该检查点推断。

## 第 35 次 UI 阶段结果与暂停点

2026-10-09 00:57 UTC 完整 UI 步骤失败，阶段日志上传成功；00:59:36 UTC 整个 run 以 failure 结束（本地日期仍为 10 月 8 日）。已下载 `AudioRelayLab-UI-Logs`，Artifact `11589165108`，87,819 字节，官方 SHA-256 核对通过：`4827f536ffe04b7d5ee2efd4493f132b82ec21c4987146583eecfcc2e116cbeb`。原始日志记录 20 个用例开始、17 个 passed、2 个 failed，另外连接页用例超过 600 秒。后半段 XCTest 汇总为 15 项／2 失败，不能用这段局部汇总代替全次用例记录；最终明确列出三个问题并记录 `TEST FAILED`。

| 剩余问题 | 本次原始证据 | 明确继续后的诊断入口 |
|---|---|---|
| 连接页主题／大字体回归超时 | `testCloudConnectionBothEntriesFollowThemeAndLargeType` 超过 10 分钟时限；日志随后仍有操作，到 781.83 秒后需附上 xcresult 的提示 | 核对各布局操作的附件和时间线，判断必要时限及是否有异常等待；不从网页截断归因 |
| 独立混音回归失败 | `InteractionUITests.swift:184` 等待保存提示时，快照报 Lost connection to the application；397.007 秒 failed | 下载该用例的 xcresult、系统／应用崩溃资料和录像，区分应用退出与测试通信问题；当前日志未确定根因 |
| 选择模式回归失败 | `InteractionUITests.swift:373` 展开混音详情后，等待来源 StaticText 出现的断言失败；90.255 秒 failed | 核对点击目标、滚动位置、实际详情和 AX 层级，再决定修订；不先删除断言或把所有等待一律加长 |

本轮成品导航 UI 通过（365.334 秒）、工坊回听五类退出入口通过（524.836 秒）、旧任务／新草稿隔离及空草稿识别入口通过（134.021 秒）。播放页试听退出、两处音频库回听退出、音量独立、自动表达、手改草稿、大字体输入、音乐片段设置、键盘、批删和单删等其余通过记录均保存在本 run 的独立日志中。

录屏清理日志为 `forced=False; exit=0`，没有强制终止；本次完整视频和 xcresult 尚未在本地取回，不能把清理状态视为本地视频检查。远端已导出失败诊断截图并上传主 Artifact，小屏、iPhoneOS Release、IPA 和最终成功证据核对均被跳过。没有新 IPA，也没有签名真机结果。

按当前用户要求，本小阶段到此暂停。已保留两个轻量检查点和本轮文档修改，不开始新的源码修订、推送或 CI。下一次明确继续时先取回第 35 次主诊断 Artifact，再处理以上三个真实问题；后续仍需完整 UI、小屏、Release 与 IPA 校验，不使用旧 IPA 补齐证据。

主诊断归档 `AudioRelayLab-iOS-Build`，Artifact `11588743405`，658,541,416 字节，官方元数据摘要为 `a662d10d487d265b2da568509100ad1f4f54534ae6f2d07627809c252159f8b8`，远端保留到 2026-10-23 00:58:02 UTC；本地尚未下载，恢复时须核对实际文件摘要。监测辅助进程已随 run 结束退出。

## 恢复继续后的第 35 次根因核对

用户明确继续后，完整主 Artifact `11588743405` 已下载，658,541,416 字节，与官方 SHA-256 `a662d10d487d265b2da568509100ad1f4f54534ae6f2d07627809c252159f8b8` 一致。原始归档、`.ips`、AX 层级和分析记录保留在同一 run 的忽略目录，前述“尚未下载”为暂停时的历史状态。

独立混音的 `.ips` 确认应用 SIGABRT，触发线程在 `RateAdjustedAudio.swift:23`：mainMixerNode → GetOutputNode → AURemoteIO::Initialize → _ReportRPCTimeout。旧代码先访问 mixer 才启用离线模式；倍速准备和最终混音两处现均先进入 offline manual rendering，再连接图节点。Apple 的[离线渲染说明](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing)说明该模式使引擎 I/O 脱离硬件。新增 native 回归在未激活的 record-only 会话内从后台实际执行倍速和混音，核对 PCM 时长、首段／尾声能量、会话参数及原文件保持不变；预计原生总数增至 276，结果待后续 CI。

选择模式的失败 AX 层级和 expanded 标记证实混音来源已打开且两种素材名称正确；子文字实际 identifier 为父 DisclosureGroup 的 `library.mix.details.<id>`，而非测试查询的 `library.mix.sources.<id>`。修订查询为该素材实际 identifier 与“人声：”前缀的交集，保留所有显示、隐藏、折叠恢复和内容断言，未放宽等待时间。

连接页附件已覆盖浅色常规／大字体、深色常规两种入口；在十次设置访问结束前超出 600 秒，日志到 781.83 秒仍执行布局检查。该多场景测试单独设 1800 秒，与已有长场景上限一致，未移除场景或断言。工作流整体、GPU 和云端配置保持。三个修订须由新源码的完整实际运行确认，第 35 次仍记录失败。

## 后续完整验证：恢复构建状态文档接口

离线修订已提交为 `37477af69cfee2e6a51b6e7a69a558b188036c71`，第 36 次标准运行 `37872594672` 启动后，交付脚本复核发现 BUILD-STATUS 的说明标题缺少 `record-ci-result.py` 要求的区块标记，会使最终证据生成失败。已取消这条过时运行，恢复文档标记；新增回归实际读取仓库文档并在内存调用替换函数，验证保留真机说明且重复生成一致。修复前 13 项证据测试中该项明确失败，修复后的结果另记；合成输入不会写成真实构建证据。此修订不改变 App 或测试的行为断言，当前 Python 总数增至 99。

恢复标记后，本地 13 项 CI 证据回归全部通过（0.002 秒），静态检查及补丁检查通过；仅执行受影响的 Python 测试，新一轮标准 CI 再执行完整 99 项。第 36 次已于 02:03:50 UTC cancelled；只执行到静态／CPU 步骤，没有运行 Simulator 编译或 XCTest，不计作通过。

## 验证边界与继续状态

用户随后明确继续，要求后续不再阶段暂停，也不再例行更新 handoff.md。本次继续从上述 11 份修改提交并验证；当前状态以本报告、README 和 BUILD-STATUS 为准，交接文档中的暂停为历史检查点。

本地修复收尾已完成并按用户要求暂停：4 份修改 Swift 语法解析、72 App／21 XCTest 文件静态检查和 `git diff --check` 均通过。11 份修改仍未提交，没有新的远端运行或 IPA；下次继续先提交审查后的修订，再运行完整标准 CI。276 原生／20 UI 为预期发现数量，不能计为本次通过。

本轮真机设备端语音识别、权限、听感、路由、锁屏和微信／通话期间行为尚未验证。具体操作步骤与剩余行为限制见 [本地验证记录](WORKSHOP-LOCAL-VALIDATION-ZH.md#真机操作清单)。自动回归使用 PCM 夹具、注入识别器、URLProtocol 与现有可信 loopback HTTPS 服务；不请求付费 GPU。

原始 CI 日志、下载归档和后续 IPA 将保存到本地忽略目录 `dist/workshop-ci-20261007/<run-id>/`，每次运行单独保留。旧 `dist/AudioRelayLab-1.6.6-unsigned.ipa` 与旧测试报告保持不变；远端产物只作为本轮候选，无签名 IPA 不证明重签后可安装或真机行为已通过。
