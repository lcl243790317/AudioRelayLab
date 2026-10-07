# AudioRelayLab 音频接力实验室

当前测试版本：**1.6.6 / build 16**。底部入口为“播放／工坊／音频库”，工坊提供“配音／混音”。混音支持音乐先播、人声先播及尾声；配音统一手动生成，自动表达指令可编辑并保留手改稿。两个音频库支持批量删除，输入支持失焦收键盘，浅深主题和按钮反馈统一。

本轮从 `feature/revoice-ios-1.6.0` 构建无签名 IPA，签名真机验收后再合并 main。功能与操作见 [1.6.6 修复说明](REVOICE-1.6.6-ZH.md)及 [1.6.5 功能说明](REVOICE-1.6.5-ZH.md)，构建结果见 [构建状态](BUILD-STATUS-ZH.txt)。录音只在手机识别文字，云端生成仅接收文字及声线参数；本轮不调整云端模型或部署。

本版完整 CI 尚待执行，目标交付 `dist/AudioRelayLab-1.6.6-unsigned.ipa`；实际测试数量、源码和 SHA256 将在通过后记录。1.6.5 验证报告属于历史证据。无签名 IPA 需自行重签名，听感、后台及通话环境继续由真机验收。


预设切换恢复默认指令；手改自动指令先确认放弃，编辑和留空只影响下一次生成。两个固定参考声线保持认可的目标表达。自定义指令独立保存，配音成品最长 180 秒，混音成品最长 300 秒。Modal 双层认证、固定模型/资产哈希、单一 L4 池和 snapshot 保持，空闲窗口为 75 秒。部署说明见 [MODAL-DEPLOYMENT-ZH.md](MODAL-DEPLOYMENT-ZH.md)；先前 snapshot A/B 基准保留在 [SNAPSHOT-REPORT-ZH.md](SNAPSHOT-REPORT-ZH.md)。

现有 iPhone 项目的增量版本，最低 iOS 17.0，功能边界为 iOS 18.1.1；保留 SwiftUI、两套播放器、实验历史、诊断、XcodeGen 和原有 Git 历史。

播放页选择 Bundle 测试音或外部文件，系统授权 URL 经协调读取、真实 PCM 验证、UUID 沙盒复制后进入统一音频库。导入中的“取消导入”和“内置测试音”可恢复控制；旧任务不能覆盖新选择。原生 UIDocumentPicker 以复制模式只允许八种支持的音频类型，其他类型显示灰色；真实 PCM 验证决定是否接受；默认测试音固定 ID/test-tone.wav，升级合并旧重复副本，历史仍能解析。选音频后立即显示格式、时长、采样率、声道和大小。拖动起点，±10/±1/±0.1 秒精调，设 0.5～2x 倍速，从此处试听或试听 5 秒，再点击“应用这个播放设置”。编辑位置、preview playhead 与正式 applied 设置独立。

主实验继续以 AVAudioPlayer 为稳定路径，AVAudioEngine 为高级路径；两者共用起点、倍速、音量及可选源音频时长。1.2.1 正式倍速先用原生 TimePitch 离线生成 PCM，再用 1x player/graph 调度；等待秒数与内容速度独立。准备后的 PCM 限 512 MB，超限可缩短源时长或调整起点。预计实际时长 = 剩余/速度。先“准备实验”，再“开始实验”，倒计时由音频系统未来调度执行。A/C/D/E 可新建，旧 B 仅兼容历史。

原声录音使用轻量原生组件，输入 0.3–60 秒，权限与中断处理保留。独立混音页自由选择已有原声或配音和本地音乐，使用完整人声时长；音乐起止与倍速独立于音频页。离线渲染为单声道 PCM WAV，保留来源与配音参数，可回听、分享和用于延迟播放。两个库按新增时间倒序；旧录音、元数据及历史仍可读取。

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
