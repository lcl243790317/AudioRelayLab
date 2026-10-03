# AudioRelayLab 音频接力实验室

AudioRelayLab 是基于现有仓库持续迭代的 iPhone 音频实验工具，最低 iOS 17.0，Bundle ID 为 `com.audiorelaylab.AudioRelayLab`。它使用 Apple 公开音频 API，记录未来播放调度、音频中断、实际路由和用户回听结果。

首页先点击“准备实验”，准备成功后点击“开始实验”。可以选择测试音或导入音频、AVAudioPlayer / AVAudioEngine、延迟、播放时长和 App 音量。新实验只提供以下配置：

| 配置 | 行为 | 注意 |
|---|---|---|
| A | 播放 + 混音 | 普通微信语音消息录制的已有真机观察较稳定 |
| C | 播放和录音 + 混音 + 默认扬声器 | 输入会话可能被通话占用，准备失败应安全结束 |
| D | 播放和录音 + 混音 + 蓝牙 HFP | 允许 HFP 不等于已使用 HFP；首页显示实际路由 |
| E | Ambient | 受静音开关及系统音频环境影响 |

B 已从新实验中停用。旧 B JSON 继续支持读取、查看、导入和导出，显示“B（旧版普通播放，已停用）”。未知历史枚举和单条损坏记录不会阻断其余历史。

App 音量为 0%～100%，只控制本 App 播放器。用户此前在 iOS 18.1.1 真机上观察到 A 的音频进入普通微信语音消息、本人讲话与预设音频共同收录，以及 App 音量降至约 4% 后明显变小。这些是已有设备与版本上的用户观察，不能推广为全部设备保证。

用户已实测微信实时语音通话、系统电话期间 A / C / D 无法实现目标播放；旧版 C 在通话中点击准备曾闪退。本轮针对可观察通话、会话激活、路由、格式、生命周期与过期回调增加防御。未取得旧版 crash report，不能确定唯一崩溃根因。新版本的 C 通话准备回归仍需真机执行，是稳定发布的 release blocker。实时通话测试通过标准为：即使不能播放，App 也不崩溃、显示合理失败状态、留下诊断，并在通话结束后可重新实验。

当前音频环境不可用时，App 显示友好提示并允许稍后重新准备。系统只读通话观察不能可靠识别微信，也不能保证观察到所有 VoIP 通话；音频会话拒绝和中断本身仍需独立处理。中断恢复是有限的 best effort，不持续重复抢占音频会话。

Windows 负责编辑、静态检查与 Git；`project.yml` 是工程配置依据。GitHub Actions 在 macOS 上执行真实 XcodeGen、自动测试、Simulator Debug 和 iPhoneOS Release 构建，成功后上传 `AudioRelayLab-unsigned.ipa`。未签名 IPA 需要使用用户自己的合法证书重新签名，不能直接安装。真实构建、Artifact 与 SHA-256 以 BUILD-STATUS-ZH.txt 的本轮证据为准。

- [构建说明](README-BUILD-ZH.txt)
- [重新签名与安装](README-INSTALL-ZH.txt)
- [真机测试协议与通话回归](TEST-PROTOCOL-ZH.txt)
- [架构、错误与诊断边界](ARCHITECTURE-ZH.txt)
- [实际构建状态](BUILD-STATUS-ZH.txt)

诊断页支持 TXT / JSON 日志，历史页支持 JSON 导入及 JSON / CSV 导出。自动诊断避免私人设备名称、UID 与文件路径；人工备注和旧历史可能包含用户填写的信息，分享前可检查内容。调度成功、播放器时间线推进、扬声器发声和微信收录是不同证据，最终收录结果由用户回听填写。
