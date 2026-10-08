# AudioRelayLab 交接文档

更新时间：2026-10-07。本文不包含真实服务地址、API key、token、私钥或连接配置原值。

## 2026-10-07 当前本地实现：草稿、识别片段、任务、导航与试听

工作分支 `feature/revoice-ios-1.6.0`，开始时工作区干净，未找到适用 AGENTS.md。保留 1.6.6 / build 16 标记；首次本地交付未生成新 IPA、未提交或推送。用户随后在当前会话明确授权提交／推送及标准 macOS CI 验证；远端结果待实际运行后追加。历史授权不作为本轮授权。

- `RevoiceDraft.swift` 独立版本化编辑草稿，450 ms 合并写入，失活／后台和离开页面及时原子保存；恢复当前编辑内容优先于旧任务，凭据不进入草稿。保存失败可见且可重试。
- `RevoiceRecognitionRange.swift` 与配音页识别片段入口冻结音频及起止时间；长音频必须明确选片段，短音频默认全段。录音启动不清空文字，支持替换／追加、最近一次识别撤销、编辑期间保留更新的文字。
- 最近任务保留冻结内容与停止标记，旧任务可能仍执行时阻止新提交；停止后明确继续取回沿用 ID 和下载凭据。已接受任务直接下载；提交回执丢失时仅用同一 ID 幂等重试。区分拒绝、网络、认证、配置、过期、生成、校验和保存失败；允许修复连接配置。
- `AppNavigation.swift` 协调音频验证与播放标签切换，失败保留页面与原选择，跳转不播放。`PreviewLifecycle.swift` 管理各页面归属、标签退出、选择器／设置／分享退出及准备取消，正式延迟播放独立。

本轮实际结果：CPU Python **94 项通过（12.349 秒）**；项目静态安全检查通过；94 个 Swift 文件经 tree-sitter 语法解析无错误；`git diff --check` 通过。新增 **25 项 XCTest、2 项 UI XCTest**，并修订旧任务替换和清空文字的旧断言；这些 Swift 测试尚未执行。Windows 无 Swift／Xcode／Simulator／签名真机，不能声称 iOS 编译或测试通过。未调用付费 GPU，未修改服务端、声线、模型、snapshot 或云端配置。

详见 `WORKSHOP-DRAFT-TASKS-ZH.md` 和 `WORKSHOP-LOCAL-VALIDATION-ZH.md`。原始本地检查位于忽略目录 `dist/workshop-local-20261007/`，不发布该目录。本轮已获授权的远端范围：仅推送审核后的源码／测试／公开文档到现有公开功能分支，再触发现有 `build-ios.yml` 完整标准 macOS 构建；不合并 main、不发布、不部署。

## 2026-10-07 1.6.6 历史体验修复

此前已交付 **1.6.6 / build 16 无签名 IPA**，不包含上述本地新增功能。修复首次批删确认清单为空、多选时仍能展开详情、连接页主题、应用设置重置 App 音量、离开播放页后试听继续。详情见 `REVOICE-1.6.6-ZH.md`。

Python 94 项、Simulator XCTest 249 项、UI XCTest 18 项及 iPhone SE 小屏截图测试 1 项全部通过；Simulator Debug / iPhoneOS Release 构建成功。 [实际构建](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37570694763)；源码 `e6da54ddd7ee8680d7ef8acc93a9cb0479517fe7`；IPA `dist/AudioRelayLab-1.6.6-unsigned.ipa`；SHA256 `dbef75afc81150f26104e57786a611332b4e1e490f9fdcff4b0ca676e3980a87`。见 `REVOICE-1.6.6-TEST-REPORT-ZH.md`。沿用已授权的公开功能分支，不调整云端模型或部署，不合并 main。

## 2026-10-06 1.6.5 历史交付

此前已交付 **1.6.5 / build 15 无签名 IPA**。底部入口改为播放／工坊／音频库；增加音乐前奏与人声延后、统一手动生成、可编辑自动指令及切换确认、两种音频库批删、统一收键盘、浅深主题和按钮回弹。取消生成进度条，保留真实处理状态。详细说明见 `REVOICE-1.6.5-ZH.md`。

Python 94 项、Simulator XCTest 241 项、UI XCTest 13 项及 iPhone SE 小屏截图测试 1 项全部通过；Simulator Debug / iPhoneOS Release 构建成功。 [实际构建](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37542874118)；源码 `229f1950a6b430c2f2b68ae0b0a3c4b4bf91786e`；IPA `dist/AudioRelayLab-1.6.5-unsigned.ipa`；SHA256 `a81e44e6cf6839f3b0eaf1eb5a5bb108246a43635e19bbec2382b6f9bcc657f4`。见 `REVOICE-1.6.5-TEST-REPORT-ZH.md`。本轮不调整云端模型或部署，不合并 main。

## 2026-10-06 1.6.4 历史交付

前一版本已交付 **1.6.4 / build 14 无签名 IPA**：音乐在成品中的加入时间、0～60 秒尾声、可选自动表达 instruction、离开两种音频库停止回听。功能说明见 `REVOICE-1.6.4-ZH.md`。自动表达采用设备端文字/标点规则，非新增云端语义模型；可查看预览、关闭开关，固定参考声线不支持覆盖。

Python 94 项、Simulator XCTest 226 项、UI XCTest 10 项全部通过；Simulator Debug / iPhoneOS Release 构建成功。 [实际构建](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37465511866)；源码 `f021781327ab9790051502b76187eeb08392f580`；IPA `dist/AudioRelayLab-1.6.4-unsigned.ipa`；SHA256 `47d5aa953c79a262b4327fb21dbfa069c521e94e64e1ee5c48942c91dca048d6`。详见 `REVOICE-1.6.4-TEST-REPORT-ZH.md`。下面的 1.6.3 结果属于历史记录。

本轮云端接口、模型、固定参考与 GPU 配置无需改变。代码基于当前清洁功能分支，不合并 main、不正式发布。真实服务地址、凭据和本机历史备份不加入公开仓库。

## 1.6.3 迁移与交付记录（2026-10-04）

- 最近交付：**1.6.3 / build 13 无签名 IPA**，等待用户重签名后的真机验收。
- **公开迁移已完成并通过未登录访问验证。** 原私有仓库已改名为 `lcl243790317/AudioRelayLab-private-history`；同名 `lcl243790317/AudioRelayLab` 是新建的独立公开仓库，没有沿用旧仓库的 PR、缓存或 Actions 附件。
- 功能分支：`feature/revoice-ios-1.6.0`。**main 不合并，继续等待签名验收。**
- 当前本机工作区：`D:/Codex projectless/Wechat delay playback app`。
- 原功能分支提交：`60075f4f5afbde32d56bedde0ab03863fcd1eab0`；原 main：`ddcac1e0e4ee41673893e262b5dedf6fe1d1660f`。
- IPA 构建源码：`72914ebcdf279415c098dd8cd535a7e1aff6ba39`。文档更新没有重新构建 IPA。
- 本轮没有修改 App/服务端功能、模型、固定参考或云端部署，没有运行 GPU 推理。

## 公开目的与 Actions 额度

**本次公开的主要目的是避免后续构建超过每月 2,000 分钟的 GitHub Actions 包含额度。** 用户提供的当前周期用量为 1,808 / 2,000 分钟（约 90%），剩余 192 分钟；这是用户反馈的数值，并非本轮重新查询的账单。

私有仓库使用 GitHub 托管 runner 会消耗仓库所有者账户的包含额度；公开仓库使用标准 GitHub 托管 runner 免费。现有工作流使用标准 `macos-latest`，后续构建应在新的公开仓库运行。原私有仓库只保留历史证据，不再作为日常构建来源。[GitHub Actions 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

私有历史备份的 Actions 已关闭，防止误触发继续消耗额度。公开仓库完成上传后恢复 Actions；本轮没有为源码迁移重复运行已通过的构建。

公开不会退还或清零本周期已经使用的 1,808 分钟；账户额度按账单周期恢复，其他私有仓库仍会消耗额度。大型 runner 即使在公开仓库也收费，不能把“大型 runner”作为本方案的免费构建替代。Modal 云端 GPU 的费用独立于 GitHub Actions，此迁移不会改变 Modal 的计费。[Actions runner 价格与范围](https://docs.github.com/en/billing/reference/actions-runner-pricing)

## 本轮用户要求与公开前检查

用户要求先检查凭据，再公开仓库，并交付本文；随后明确要求 **真实服务地址也隐藏**。用户已授权为审计在本机内存中使用临时签名链接下载历史产物，不保存链接或凭据。用户现已选定上述方案 1，并要求本文同步记录节省 Actions 额度的主要目的；不再等待发布方式选择。

已完成的检查：

| 范围 | 结果 |
|---|---|
| Git 全历史 | 52 个本地提交、615 个历史 blob；未发现真实访问凭据 |
| 当前追踪文件 | 182 个；私有配置路径被 Git 排除 |
| 远端引用 | 两个分支及 PR head/merge；自动合并树与已扫描的功能分支一致，元数据未发现凭据 |
| Actions | 33 次运行的 33 份完整日志、33 份产物；产物逐份核验官方 SHA256 |
| 解包内容 | ZIP/IPA 递归检查；8,479 份唯一内容，累计检查 2,204,353,499 字节 |
| 已知凭据精确比对 | 本机私有配置中的 9 个不同凭据，连同 UTF-16、Base64 和 URL 编码形式；没有命中 |
| 独立规则扫描 | 官方 Gitleaks v8.30.1，Git 历史、全部 Actions 日志及解包内容均未发现凭据 |
| 最新 1.6.3 IPA | 没有发现真实凭据或真实服务地址；哈希与交付记录一致 |
| PR/发布记录 | 一个 PR，无评论/审查记录，无 Release；已检查元数据 |

**发现了需要处理的地址残留：**历史部署文档中共 6 处真实 Modal 服务地址；12 份旧 Actions 附件也包含这些文档。日志及当前 PR 元数据没有发现这些地址。它们不是认证凭据，但按用户要求不能随公开仓库对外展示。

### 已准备的干净候选

- 本地候选 Git 仓库：`dist/publication-audit-20261004/public-source.git`。
- 使用固定的官方 git-filter-repo v2.47.0，并核验其 Git blob SHA：`a40bce548d2c0bd0b8d5e233e8930d462e35e495`。
- 候选全部历史中的真实工作区域名已替换为示例工作区；完整对象检查没有发现凭据或真实服务地址。
- 清理后 main：`c5ea32e7ec5cef3791ed43a499ca00a3c5c34e63`；功能分支：`d722a64b5cf29dbc922fa4cdfe9e16a9d8080977`。这些是加入本交接文件之前的候选提交。
- 两个分支的 App 和服务端源码逐文件一致。功能分支仅部署文档的地址占位符变化；main 的文件内容不变。
- 历史清理在候选副本中完成；原始历史和本机审计产物保留作为私有备份，不是公开仓库的上传来源。

### 已完成的公开迁移

公开仓库：[AudioRelayLab](https://github.com/lcl243790317/AudioRelayLab)，ID `1404688151`，`private=false`、`fork=false`、默认分支 `main`，已验证未登录可访问。私有历史备份：[AudioRelayLab-private-history](https://github.com/lcl243790317/AudioRelayLab-private-history)，保留原 ID `1402390040`，`private=true`，Actions 已关闭。

上述两个清理后的候选提交均已与远端逐一核对；其后的交接与保护规则提交只修改文档、历史证据链接和忽略规则。文档不能记录自身提交哈希；最终分支 SHA 和交付包 SHA256 记录在本机 `dist/publication-audit-20261004/migration-state.json`、`public-export-audit.json` 及交付包旁的 `.sha256` 文件中。

不能仅强推清理后的分支就把原仓库公开。GitHub 的旧提交 SHA、PR 引用和缓存可能继续提供旧内容，旧 Actions 附件也不会随 Git 改写而自动清理。GitHub 官方说明：<https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository>。

认证已通过官方 Git Credential Manager 的浏览器登录接通。仓库管理使用 GitHub 官方 API，上传使用原生 Git；凭据仅由登录工具管理并在进程内使用，不写入 Git、文档、审计报告或命令行。

迁移执行与复核步骤：

1. 使用普通独立空仓库，**不要从旧仓库 fork 或直接导入旧历史**。
2. 只上传已经清理并复核的候选历史和安全交接文档，保留 main 与功能分支的关系。
3. 旧 Actions、PR 和历史原件留在私有备份；不要把原始旧 Artifact 上传到公开仓库。旧 CI 与 PR 链接应使用 `AudioRelayLab-private-history` 路径，不要因原名称被新仓库复用而错误链接到公开仓库中的同号记录。
4. 本机旧 `.git` 保留在忽略目录 `dist/publication-audit-20261004/legacy-root.git`，其远端指向私有备份。工作区 `.git` 改为清洁历史，`origin` 指向新公开仓库。**不要把旧 `.git` 或未经清理的旧历史推回公开仓库。**
5. 更新旧 CI/PR 链接和提交映射，验证新仓库 `private=false`，在未登录环境检查可访问内容。
6. 如需重建 IPA，在公开净版使用标准 `macos-latest` workflow_dispatch；不要因此合并 main，也不要在私有备份触发新的日常构建。
7. 旧交接原稿 `HANDOFF-ZH.md` 是本机未追踪资料，保留原件但不加入公开仓库；公开交接使用本文件 `handoff.md`。

审计原始结果位于 `dist/publication-audit-20261004/`，属于本地忽略目录。报告只记录位置与类别，不记录凭据原值。历史产物保存在本机，用于私有留档；临时签名下载链接文件已经清理。

## 当前 App 行为

### 重新配音

手机设备端识别中文为主的语音，用户可校对文本；云端只接收文字与目标参数，不接收用户声纹、音高、气口或原声节奏。不做时长对齐或自动润色。

- 预设声线 6 个；自定义区支持 Serena、Vivian、Dylan、Uncle_Fu、Eric、Ryan、Aiden、Ono_Anna、Sohee。
- 原声录制与识别片段 0.3–60 秒；输入文件可更长，但识别须在配音页明确选片段。文本最多 1,000 Unicode scalar；instruction 最多 500 scalar；配音成品大于 0、最长 180 秒；混音含前奏与尾声最长 300 秒。
- Serena 原版、Vivian 原版、古风温润小生、清冷淡然支持指令编辑；切换预设恢复默认，留空表示自然表达。
- 清润书生、清脆动漫可爱声使用固定参考，不接受指令覆盖。
- 编辑草稿独立持久化。每次手动生成冻结文字、speaker、instruction；旧任务执行或状态未确认时保留新草稿并阻止新提交。取回沿用原任务参数，不覆盖当前草稿。
- JSON 连接导入采用复制模式文档选择器，也支持粘贴；凭据保存到 Keychain。
- 两个音频库按新增时间倒序；稳定选择页、键盘“完成”、深浅色和大字体继续保留。

### 取回与后台

1.6.3 前台直接通过 HTTPS GET 流取回 WAV，避免系统临时下载文件的权限故障；后台继续系统 URLSession 下载，回前台后取回同一个任务，不重复推理。

任务状态与停止等待标记持久化，代次标识阻止迟到回调覆盖新任务。24 小时取回窗口、按任务限定的只读下载凭据、来源/WAV/SHA256/采样率/真实时长验证和只保存一次保持。后台失败时保留任务，等待前台恢复；用户手动划掉 App 后需重新打开。

最近任务展示服务端已知状态与客户端真实阶段。主动停止的任务不自动恢复，需明确点击继续取回；未确定结束前可能继续占用单任务云端位置。连接设置不再因待取回任务而被锁死；有已验证下载凭据的任务可直接取回，无回执且配置不匹配的任务需导入原配置。

### 混音与瘦身

工坊顶部“配音／混音”。独立混音可选已有原声或已生成配音，再选背景音乐，不依赖最新配音。保留完整人声，音乐片段、速度与其他页面独立；成品保留来源及配音元数据。

首次混音默认：人声 100%、音乐 4%、总音量 90%；后续保留用户音量设置。音乐从头、1x；切换音乐重置片段。

“手机实时”板块、DSP 与 Signalsmith 依赖已移除。保留轻量原声录音、电脑变声高级入口、离线混音、回听、分享及延迟播放。

## 云端与本地配置

- GPU worker 与常规 CPU API 的 `scaledown_window=75`；准备/清理任务使用短窗口。
- 单一 L4 池，min=0、max=1、buffer=0，生成并发 1；GPU snapshot 保持开启。
- CustomVoice/Base 按需切换，GPU 同时只保留一个模型；固定资产及模型锁定哈希不变。
- 双层认证、请求校验、限流、去重、任务状态/结果存储及过期清理已接入。
- 真实连接配置只在本机 `server/.private/modal-client.json`；Modal CLI 登录配置在用户目录 `.modal.toml`。不要输出、追踪或上传这些文件。
- 不向公开文档写入当前服务地址。连接说明使用生成工具导出到私有目录，或从现有私有 JSON 导入 App。

## 1.6.3 历史交付与真实验证

- IPA：`dist/AudioRelayLab-1.6.3-unsigned.ipa`。
- SHA256：`098b3dd53c87daee95c37ccbd4ab7eaf785e27c07f7295dd3cd6eba705fd6e69`。
- IPA 1,386,525 字节，可执行文件 4,971,304 字节。
- 原 Actions 成功运行 ID：`37193385965`；原 Artifact ID：`11300425280`。
- 旧 CI 入口为 [私有历史构建记录](https://github.com/lcl243790317/AudioRelayLab-private-history/actions/runs/37193385965)，原 PR 为 [私有历史 PR #1](https://github.com/lcl243790317/AudioRelayLab-private-history/pull/1)；两者属于私有历史备份，不是新公开仓库的构建或 PR。
- Python：94 项通过；模拟器 XCTest：202 项通过；UI XCTest：8 项通过；iPhoneOS Release 构建成功。
- 4 次真实 L4：默认指令、修改指令、留空指令、固定参考均通过；去重、409 参数冲突、WAV/哈希/时长/身份校验通过，实测后确认 GPU 缩到 0。
- 本轮没有重新做 GPU snapshot A/B，也没有重新构建 IPA。

详细文档：`REVOICE-1.6.3-ZH.md`、`REVOICE-1.6.3-TEST-REPORT-ZH.md`。原始 CI 证据位于 `dist/ci-run-37193385965/`，GPU 证据位于 `dist/revoice-1.6.3/gpu/report.json`；这些目录不能直接上传为公开资料。

## 必须由用户真机验收

草稿重启恢复、权限拒绝／准备失败／取消后的文字保留、识别片段听感、替换／追加／撤销、旧任务取回不覆盖新草稿、停止后手动取回、成品跳转不启动播放、全部回听退出、正式播放不受清理影响。具体步骤见本轮验证记录；旧 IPA 不用于验收本轮源码。

真实的 `NSCocoaErrorDomain:513 / NSPOSIXErrorDomain:1` 没有在 Simulator 中完整复现。新前台路径移除了有问题的文件读取环节，后台有恢复机制；不能据此宣称所有重签名权限与 iOS 后台调度问题都已由模拟器验证。

## 关键代码位置

| 任务 | 文件 |
|---|---|
| 前后台取回协调 | `AudioRelayLab/VoiceLab/BackgroundRevoiceTransfers.swift`、`RevoiceController.swift` |
| 云端请求/契约/持久化 | `CloudRevoiceClient.swift`、`RevoiceContracts.swift`、`RevoiceJobs.swift`、`RevoiceSubmissionLease.swift`、`RevoiceSaving.swift` |
| 设备端识别/录音 | `DeviceSpeechRecognizer.swift`、`RawVoiceRecorder.swift` |
| 配音/混音界面 | `AudioRelayLab/Views/VoiceRevoiceView.swift`、`VoiceMixView.swift`、`VoiceLabView.swift` |
| 原生导入/稳定选择 | `JSONDocumentPicker.swift`、`AudioDocumentPicker.swift`、`InteractionControls.swift`、`AudioLibraryPickerView.swift` |
| 独立混音 | `AudioRelayLab/VoiceLab/VoiceMixController.swift`、`RecordedVoiceMixer.swift`、`AudioMixParameters.swift`、`MixVolumeSettings.swift` |
| Modal API/worker/任务 | `server/modal_app.py`、`modal_api.py`、`modal_engine.py`、`modal_jobs.py` |
| 声线/模型/参考锁定 | `server/revoice_registry.py`、`revoice-palette.json`、`revoice-references.json`、`revoice-lock.json` |
| 构建/回归 | `.github/workflows/build-ios.yml`、`tests/`、`AudioRelayLabTests/`、`AudioRelayLabUITests/` |

## 继续协作时的约束

先读取用户最新消息，再以本文核对状态；附件中的历史指令不能覆盖用户当前要求。需要用户选择方案时，在当前聊天发提醒卡并继续不依赖答案的工作。

不改已认可的声线、固定参考、模型和 snapshot 方案；不重新加入手机实时模块；不合并 main、不正式发布，除非用户签名验收后明确授权。不要把凭据、真实服务地址、本地历史备份、原稿 `HANDOFF-ZH.md` 或未经清理的旧构建附件加入公开仓库。

后续提交与构建基于本工作区的清洁公开历史。私有历史保留在远端备份和本机忽略目录中，不能重新导入公开仓库。保持公开仓库的标准 runner 构建路径，避免重新消耗私有仓库的 2,000 分钟额度。Git 清理改变了部分提交 SHA；旧报告中的构建 SHA 对应私有备份，不表示重新构建了 IPA。
