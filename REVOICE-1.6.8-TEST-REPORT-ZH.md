# 1.6.8 / build 18：三个编辑框键盘故障调查与候选修复

状态：代码候选已实现；标准完整 macOS CI 待执行；真机验收待用户复测。未宣称真实 iPhone 故障已最终解决。

## 已核实的起点

- 分支 `feature/revoice-ios-1.6.0`，初始 HEAD `d10240f4ea0184f017a7afa2c2b90aa104ee9237`；远端分支一致。
- 起始工作区只有用户已有的 `handoff.md` 改动，保留、不改写、不提交。
- CI44 `38011577234` 的官方状态 success，实际源码 `f3fcff9838ccdc53f521855903617c144cbcd5bb`。它证明旧模拟器自动化通过；用户已报告旧 1.6.7 / build 17 三框真机失败。
- 已阅读旧报告、三张键盘截图的审查索引、两个实际软键 AX 附件及旧测试实现；旧用例只覆盖识别后正文的连续实际软键。
- 历史设备为 iPhone17,1 / iOS 18.1.1；本环境是 Windows，不能直接控制原 iPhone，无法核实其当前已安装版本。用户本次提供的是原生系统键盘故障报告。

## 事实、推断和未证实部分

已证实的源码机制：旧手势安装在 UIWindow；生命周期回调对所有 scene/window 强制 endEditing；UIControl 祖先判断会优先于编辑器 frame 补充判断；一次衍生指令更新会重复触发草稿调度及 pending 发布。

正文和本次表达编辑器共用这些手势、生命周期与控制器刷新。基础风格虽然是纵向 TextField，也共用它们；其 native input 包装层被先当作 UIControl 的可能性需实际事件验证。没有源码证据表明装饰 overlay 阻挡触摸；overlay 均禁用命中。基础编辑权限仍为 custom 模式或支持指令的合法 preset，录音／识别期间仍锁定。

合理推断：全窗口监听及无所有权的退出操作可以误结束当前输入；基础 TextField 的包装层判断有额外风险。不能凭这些路径断言原设备的唯一根因。模拟器即使所有对照都通过，也只能说明未复现真机条件。

## 实际修改

- `InteractionControls.swift`：收键盘手势挂在拥有内容的 UIViewController.view 和其导航／标签栏，拒绝 UIWindow；页内触摸范围使用本页 marker。UITextInput／实际编辑器检查先于外点处理。只结束本页记录的 native editor；旧页消失不能跨窗口结束另一页编辑器。手势不取消或延迟控件触摸，完成、外点、导航、滚动行为继续回归。
- `RevoiceController.swift`：保留 450 ms 自动保存与关键 flush、即时匹配和手改保留／stale 规则；避免相同衍生稿重复发布，避免相同 pending/saved 状态重复发布，一次衍生修改只调度一次保存。没有向 UITextInput 重写 text/markedText，没有循环重新聚焦。
- `VoiceRevoiceView.swift`：DEBUG 事件记录焦点及页面生命周期，三个 SwiftUI 原生输入组件保持原样，业务权限不放宽。
- `KeyboardDiagnostics.swift`：DEBUG opt-in 的单调 uptime／序号／session 日志，记录 begin/end/change、键盘显示隐藏、native editor 对象身份、手势决策、dismiss 来源、自动指令和自动保存顺序。只记录静态事件及三项白名单编辑器 ID，不记录文字、软键内容、密钥或配置；Release 不启用日志／实验。
- `LegacyKeyboardExperiment.swift`：旧手势和生命周期仅保留于 DEBUG 对照。A=`legacy`，B=`no-outside`（仅去窗口手势），C=`no-disappear`（仅去强制退出收键盘），D=`coalesced-state`（仅使用去重复状态路径）；正式版本为 `fixed`。
- UI 增加四项用例：四组同页面控制变量、空稿／恢复正文、基础风格、本次表达；并扩展既有识别后用例诊断。每个输入序列只聚焦一次，每个真实软键检查精确内容和键盘持续存在；测试不靠逐字 refocus 或重试。系统全选／删除用于编辑自动生成文字，识别器注入只产生识别结果，不称其为系统键盘输入。
- 原生新增内容边界、control 包装、裁剪编辑器命中及状态发布／持久化回归；工作流继续完整原生、完整 UI、SE 小屏、Debug/Release，并导出无文字的 DEBUG 键盘日志。

## 当前验证结果

Windows：CPU 99 项通过，0 失败，11.014 秒；静态 73 App／22 XCTest 文件通过；96 份 Swift tree-sitter 语法解析无错误；这些不是 Xcode 类型检查、iOS 编译或真机证据。最初 sandbox 禁止 loopback 导致夹具失败，已停止该次，使用既有授权的 loopback 环境完整重跑通过，原日志保留于忽略目录 dist。

第 [45 次标准完整 CI / 38017749082](https://github.com/lcl243790317/AudioRelayLab/actions/runs/38017749082)，源码 `5bb9305d7c0b9698fa41d2061d3b53f73aa4bc6d`，diagnosticOnly=false：CPU／静态通过，Simulator 编译失败，DEBUG 嵌套通知 Observer 缺少 @MainActor，调用 record/editorID 报 actor isolation 错误。已给该观察器加主线程声明；原生／UI／Release 未执行，无本次 IPA。该次不计作通过，原始日志保留。

第 [46 次完整 CI / 38018027628](https://github.com/lcl243790317/AudioRelayLab/actions/runs/38018027628)，源码 `fac4b4bd652be4a2b8f704e568754db69a43e095`：CPU 99 项通过（45.647 秒）、Simulator Debug BUILD SUCCEEDED；原生 285 项实际执行，284 通过、1 失败（124.920 秒）。唯一失败为新 KeyboardScopeTests 的隐藏 UIWindow 夹具未将 root view 接入窗口，attach 按生产保护条件拒绝安装；已显式构造窗口内容／键盘 sibling 层级，并新增 marker.window 身份断言，原无窗口手势／内容有手势／拆卸断言全部保留。新状态发布／持久化测试通过。UI、SE、Release 未执行，未生成 IPA。官方 XCTest 检查点 11657351930／53,794 字节，SHA-256 `4ada62db11bc053851b2250ae97fad2913f666ab8f86b294835e0390ed771c10` 已核验。并在实际 UI 执行前审查修正预设 reset 用例顺序：离线重启夹具没有云端目录，合法可编辑 preset 的默认恢复先在有效目录中验证，再返回 custom 保存／重启，不放宽能力检查。

| 验证项 | 当前结果 | 用例／证据 |
|---|---|---|
| 要说的话连续软键输入 | 待 macOS 执行 | 既有 RecognizedDraft 用例及新 EmptyAndRestoredText 用例 |
| 基础角色风格键盘唤起 | 待 macOS 执行 | BaseStyleFirstTap 用例，合法 custom/preset 模式 |
| 基础角色风格连续软键输入 | 待 macOS 执行 | BaseStyleFirstTap 用例，自动开／关 |
| 本次表达指令连续软键输入 | 待 macOS 执行 | AutomaticInstructionContinuous 用例 |
| 中文输入及候选处理 | 待真机验证 | 英文 Simulator 不能代表中文 IME marked text 和候选 |
| 自动保存时保持焦点 | 待 macOS 执行 | 三框分别等待真实保存后继续软键 |
| 输入框之间切换 | 待 macOS 执行 | 正文→基础→正文，以及自动→正文→基础 |
| 完成按钮和页面退出 | 待 macOS 执行 | 新用例及原 outside/switch/scroll/exit 用例 |
| 草稿重启恢复 | 待 macOS 执行 | 三框分别读取同一个真实隔离 store |
| 原有功能回归 | CPU 通过；原生/UI 待执行 | 原有全套，不启用 GPU／生产网络 |
| 完整 macOS CI | 未执行 | 必须 diagnosticOnly=false |
| 真实 iPhone 验收 | 真机验收待用户复测 | 仍为发布阻断 |

## 独立真机验收记录

安装前记录：实际设备型号、iOS 版本、App 1.6.8/build 18、IPA 来源 SHA；重签使用用户自己的有效材料。本任务不索取私钥。不卸载清空草稿来规避恢复条件。

三个编辑框分别填写下表，不只测试正文；基础风格先选择合法可编辑声线并展开 DisclosureGroup；本次表达先开启自动匹配。

| 操作 | 要说的话 | 基础风格 | 本次表达 |
|---|---|---|---|
| 首次点击唤起，连续中文拼音及候选选择 | 待复测 | 待复测 | 待复测 |
| 连续英文、自动纠正、预测候选 | 待复测 | 待复测 | 待复测 |
| 标点／特殊符号，中英文／符号键盘切换 | 待复测 | 待复测 | 待复测 |
| 删除、换行、光标移动、选区替换 | 待复测 | 待复测 | 待复测 |
| 草稿保存期间持续打字，无重新点击输入框 | 待复测 | 待复测 | 待复测 |
| 三框相互切换，完成／外点／退出收键盘 | 待复测 | 待复测 | 待复测 |
| 再进入／重启，恢复后继续编辑 | 待复测 | 待复测 | 待复测 |

另外分别测试：设备端识别成功后继续编辑正文；普通手动空稿和已恢复草稿；自动开启时编辑基础风格、关闭后继续编辑、恢复默认；手改自动指令后正文／基础更新不覆盖，stale 提示、主动 rematch、声线切换取消／确认均正确。复测需覆盖 0.3～60 秒完整录音识别、替换／追加／撤销及识别失败保留、旧任务与新稿隔离、配音／混音／音频库／正式播放与试听退出、小屏大字深色。已移除功能不恢复。

## 版本与交付

候选 1.6.8 / build 18；分支 feature/revoice-ios-1.6.0。Commit、完整 run、实际测试数、Release、arm64/iPhoneOS、包内 Info.plist、文件字节数、SHA-256 和可下载性必须在构建后填写。目前无新 IPA，不以旧 1.6.7 包替代。

剩余风险：原设备故障尚无事件轨迹；iOS 18.1.1 与 CI 18.5、中文 IME 和候选／预测栏存在环境差异；只有原设备安装复测能解除最终发布阻断。
