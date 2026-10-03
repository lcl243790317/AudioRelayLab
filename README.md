# AudioRelayLab 音频接力实验室

当前交付：**1.5.1 / build 9**。音频库按加入时间最新在前；电脑 AI 可直接从库选择原声，四种技术模式在高级转换设置中；手机详细参数在高级调音中。回听只试听，点击“使用”才改变当前播放音频；首页“开始延迟播放”一次完成准备和倒计时。起止范围仍须点击“应用这个播放设置”后用于正式播放；AI 从库选择默认使用全段，可展开“使用音频页的区间”沿用已应用范围。

安装包：`dist/AudioRelayLab-1.5.1-unsigned.ipa`，需要使用自己的证书重新签名。162 项 XCTest / 30 项 Python 和真实 iPhoneOS Release 已通过，见 `BUILD-STATUS-ZH.txt`。新声线是独立候选试听，尚未加入正式服务。


自然重新配音：原声只用于识别，文字交给 Qwen3-TTS 1.7B 重新说。用户已认可 Serena、Vivian，拒绝首轮普通设计女声；新增古风小生、可爱、慵懒等 8 组候选，独立试听后再接入 App，当前仍为 1.5.1。见 [扩展声线试听与复现](REVOICE-PALETTE-ZH.md) 和 [首轮流程验证](REVOICE-RESEARCH-ZH.md)。

现有 iPhone 项目的增量版本，最低 iOS 17.0，功能边界为 iOS 18.1.1；保留 SwiftUI、两套播放器、实验历史、诊断、XcodeGen 和原有 Git 历史。

Audio 页选择 Bundle 测试音或外部文件，系统授权 URL 经协调读取、真实 PCM 验证、UUID 沙盒复制后进入统一音频库。导入中的“取消导入”和“内置测试音”可恢复控制；旧任务不能覆盖新选择。原生 UIDocumentPicker 以复制模式只允许八种支持的音频类型，其他类型显示灰色；真实 PCM 验证决定是否接受；默认测试音固定 ID/test-tone.wav，升级合并旧重复副本，历史仍能解析。选音频后立即显示格式、时长、采样率、声道和大小。拖动起点，±10/±1/±0.1 秒精调，设 0.5～2x 倍速，从此处试听或试听 5 秒，再点击“应用这个播放设置”。编辑位置、preview playhead 与正式 applied 设置独立。

主实验继续以 AVAudioPlayer 为稳定路径，AVAudioEngine 为高级路径；两者共用起点、倍速、音量及可选源音频时长。1.2.1 正式倍速先用原生 TimePitch 离线生成 PCM，再用 1x player/graph 调度；等待秒数与内容速度独立。准备后的 PCM 限 512 MB，超限可缩短源时长或调整起点。预计实际时长 = 剩余/速度。先“准备实验”，再“开始实验”，倒计时由音频系统未来调度执行。A/C/D/E 可新建，旧 B 仅兼容历史。

Voice Lab 提供真实麦克风、独立 pitch/formant、EQ/动态/去齿音/dry-wet/gain、15 个预设和效果强度。Mixer 加入当前音乐及独立 Voice/Music/Master，音乐可在运行中独立 seek/变速。处理后录音和混合录音保存本地单声道 Float PCM CAF，可试听、应用到主音频、分享、删除。原生输出动态处理器提供余量保护；真人自然度和瞬态质量需要回听。

实时监听默认耳机优先；扬声器需主动启用。录制默认关闭现场监听。Voice Lab/Mixer 提供“允许后台继续当前 Voice / Mixer”开关：开启时只继续用户主动启动的真实输入、输出或录音，关闭则切后台时停止并保存。系统中断、实际设备/格式改变或媒体失效仍会安全停止，不完整录音丢弃；正常类别通知先核对硬件状态。跨 App 微信录音同时使用麦克风仍可能被系统中断；也可先保存混合 CAF，再使用主播放器延迟实验。

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

依赖 Signalsmith Stretch 1.3.2 与固定提交的 Signalsmith Linear，均 MIT，完整许可证进入 App resources。预设不是神经网络身份转换。诊断和历史可导出 TXT/JSON/CSV；本轮按需求加入文件 URL/名称/目标路径审计，分享前检查个人路径，设备 UID/私人路由名称仍不自动记录。

1.2.1 同硬件/格式的 category/override 通知不再直接判失败；启动前等待稳定路由，停止的同格式图最多重启一次。设备或格式真正改变仍安全结束，避免复用无效图。实际 Files 点击、5秒等待和 iOS 18.1.1 麦克风效果仍须按真机协议复测。


1.3.1 新增实验历史清空、所有按钮明显按压反馈、诊断/实验日志倒序；实时模式开放九项额外参数。电脑 AI 使用保留原话和语调的路径，网络错误与音频会话错误分开记录。Windows 服务关闭临时命令窗口后仍运行，异常退出有限重启。连接、操作与质量证据见 [电脑 AI 使用指南](AI-VOICE-GUIDE-ZH.md)。
