# AudioRelayLab 音频接力实验室

当前检查点：沿 handoff 继续后，已完成失败录像与测试通信日志的诊断，修订正文输入定位、退出回听的实际长 PCM 夹具及状态等待预算。标准 CI 使用 `macos-15` Apple Silicon、固定 Xcode 16.4／iOS 18.5。第 39 次 UI 为 18 通过、2 失败；长短测试夹具跨启动遗留重复素材 ID 已由删除崩溃栈确认，正在修复并继续完整验证。当前状态记入 [验证报告](WORKSHOP-CI-VALIDATION-ZH.md)，handoff.md 保留此前暂停时的记录。

最近交付版本：**1.6.6 / build 16**。当前候选增加独立配音草稿自动保存、识别片段、最近任务取回、成品到播放页的导航及统一试听退出，版本号暂未递增。源码 `d3e99a805f64fc400fdd523d2b8e548a21ba5bb6` 的第 [39 次 CI](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37896992880) 原始归档已确认 Simulator Debug 编译成功、99 项 CPU 与 276 项 XCTest 全部通过；20 UI 中 18 通过、2 失败，小屏／Release／IPA 未执行。Windows 全量 CPU 99 项也已通过，不能替代 Xcode 或真机结果。使用说明见 [草稿与任务说明](WORKSHOP-DRAFT-TASKS-ZH.md)，首次检查见 [本地验证记录](WORKSHOP-LOCAL-VALIDATION-ZH.md)，远端结果见 [本轮 macOS 验证](WORKSHOP-CI-VALIDATION-ZH.md)。底部继续为“播放／工坊／音频库”，工坊提供“配音／混音”。

工作分支为 `feature/revoice-ios-1.6.0`。继续请求已推进源码提交／推送与标准完整 macOS CI，实际结果见 [本轮 macOS 验证](WORKSHOP-CI-VALIDATION-ZH.md)。不合并 main、不创建 Release、不部署。录音只在手机识别文字，云端生成仅接收文字及声线参数。

历史 1.6.6 交付：`dist/AudioRelayLab-1.6.6-unsigned.ipa`。当时 Python 94 项、Simulator XCTest 249 项、UI XCTest 18 项及 iPhone SE 小屏截图测试 1 项通过；Simulator Debug / iPhoneOS Release 构建成功。[历史构建](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37570694763)及 [历史验证报告](REVOICE-1.6.6-TEST-REPORT-ZH.md)。该 IPA 和这些 Xcode 结果不包含本轮改动。


预设切换恢复默认指令；手改自动指令先确认放弃，编辑和留空只影响下一次生成。两个固定参考声线保持认可的目标表达。自定义指令独立保存，配音成品最长 180 秒，混音成品最长 300 秒。Modal 双层认证、固定模型/资产哈希、单一 L4 池和 snapshot 保持，空闲窗口为 75 秒。部署说明见 [MODAL-DEPLOYMENT-ZH.md](MODAL-DEPLOYMENT-ZH.md)；先前 snapshot A/B 基准保留在 [SNAPSHOT-REPORT-ZH.md](SNAPSHOT-REPORT-ZH.md)。

现有 iPhone 项目的增量版本，最低 iOS 17.0，功能边界为 iOS 18.1.1；保留 SwiftUI、两套播放器、实验历史、诊断、XcodeGen 和原有 Git 历史。

播放页选择 Bundle 测试音或外部文件，系统授权 URL 经协调读取、真实 PCM 验证、UUID 沙盒复制后进入统一音频库。导入中的“取消导入”和“内置测试音”可恢复控制；旧任务不能覆盖新选择。原生 UIDocumentPicker 以复制模式只允许八种支持的音频类型，其他类型显示灰色；真实 PCM 验证决定是否接受；默认测试音固定 ID/test-tone.wav，升级合并旧重复副本，历史仍能解析。选音频后立即显示格式、时长、采样率、声道和大小。拖动起点，±10/±1/±0.1 秒精调，设 0.5～2x 倍速，从此处试听或试听 5 秒，再点击“应用这个播放设置”。编辑位置、preview playhead 与正式 applied 设置独立。

主实验继续以 AVAudioPlayer 为稳定路径，AVAudioEngine 为高级路径；两者共用起点、倍速、音量及可选源音频时长。1.2.1 正式倍速先用原生 TimePitch 离线生成 PCM，再用 1x player/graph 调度；等待秒数与内容速度独立。准备后的 PCM 限 512 MB，超限可缩短源时长或调整起点。预计实际时长 = 剩余/速度。先“准备实验”，再“开始实验”，倒计时由音频系统未来调度执行。A/C/D/E 可新建，旧 B 仅兼容历史。

原声录音使用轻量原生组件，录制 0.3–60 秒。配音页可从长文件中明确选择 0.3～60 秒识别片段；该区间独立于播放设置、倍速和混音。选择音频、录音失败或识别失败保留文字；识别结果可替换／追加并撤销最近一次修改。编辑草稿与冻结任务分别持久化；停止等待保留任务，须手动继续取回，尚未结束的旧任务只阻止新云端提交，仍可识别空草稿所选片段。独立混音使用完整人声，音乐片段与倍速仍独立；成品和音频库的用于播放操作在验证成功后切到播放页，手动开始延迟播放。

| 格式证据分类 | 本轮范围 |
|---|---|
| Confirmed audio formats | 每个实际导入文件通过 AVAudioFile 打开、PCM 读取、metadata 校验才接受 |
| Tested audio formats | CI 实际编码夹具：MP3、M4A/AAC、AAC/ADTS、WAV/PCM、AIFF、AIFC、CAF、FLAC；Bundle WAV |
| Runtime-validated additional formats | 选择器限制到上述八种音频类型；仍逐文件实际解码，不按后缀保证编码有效 |
| iOS 18.1.1 真机已验证 | 本轮新版本尚无真机结果，所有 picker/监听/录音/收录矩阵待填写 |

文件后缀不代表全部编码子类型受支持。CI 使用更新 SDK/Simulator，不能代替 18.1.1 真机。

代码审查确认旧导入任务的 isImporting 共用锁会同时阻止外部和默认音选择，缺少取消/替换入口；旧 Files 路径也没有 provider 协调读取，授权在异步工作中才申请。现已修复这些可复现代码风险。没有此次失败的设备日志，不能把它们宣称为该真机事件的唯一根因。

此前用户在 iOS 18.1.1 观察到 A 能进入普通微信语音消息，App 音量约 4% 明显变小；这些不是本轮独立复测。旧 C 通话中准备曾闪退，缺少 .ips；新版通话准备稳定性仍是发布前真机阻断项。App 不读取微信、不注入麦克风、不抓取电话音频；系统会话允许播放和实际声学收录分开记录。

Windows 做编辑与静态检查，GitHub Actions/macOS 执行真实 Simulator Debug、XCTest、iPhoneOS Release 和 unsigned IPA 验证。最终源码 SHA、run、Artifact、环境、测试数、IPA 路径和 SHA-256 见 [构建状态](BUILD-STATUS-ZH.txt)。未签名 IPA 需自行重新签名。

- [构建与复现](README-BUILD-ZH.txt)
- [安装说明](README-INSTALL-ZH.txt)
- [架构](ARCHITECTURE-ZH.txt)
- [音频导入与主实验真机矩阵](TEST-PROTOCOL-ZH.txt)
- [Voice 技术研究、依赖和许可证](VOICE-PROCESSING-RESEARCH-ZH.md)
- [Voice Lab / Mixer 真机协议](VOICE-LAB-TEST-PROTOCOL-ZH.md)

诊断和历史可导出 TXT/JSON/CSV；连接凭据仅在本机 Keychain，源码与 IPA 不含实际密钥。诊断导出可能带本机音频名称与路径。

以下为历史版本记录：手机实时和 Signalsmith 已在 1.6.1 移除，旧技术研究文档只作为历史资料。

1.2.1 同硬件/格式的 category/override 通知不再直接判失败；启动前等待稳定路由，停止的同格式图最多重启一次。设备或格式真正改变仍安全结束，避免复用无效图。实际 Files 点击、5秒等待和 iOS 18.1.1 麦克风效果仍须按真机协议复测。


1.3.1 新增实验历史清空、所有按钮明显按压反馈、诊断/实验日志倒序；实时模式开放九项额外参数。电脑 AI 使用保留原话和语调的路径，网络错误与音频会话错误分开记录。Windows 服务关闭临时命令窗口后仍运行，异常退出有限重启。连接、操作与质量证据见 [电脑 AI 使用指南](AI-VOICE-GUIDE-ZH.md)。
