# 音频接力实验室

真实 iOS 音频实验项目，最低 iOS 17.0，主要测试设备为 iPhone / iOS 18.1.1。

点击“准备并开始”时，在前台通过 `AVAudioPlayer.play(atTime:)` 或 `AVAudioPlayerNode.play(at:)` 提前调度未来播放。用户手动切换到微信，观察音频会话中断、路由和扬声器声音能否被同一台手机的麦克风收录。

Windows 负责开发，`project.yml` 是工程配置依据；GitHub Actions 在 macOS 上运行 XcodeGen 和真实 Xcode 编译，成功后上传 `AudioRelayLab-unsigned.ipa`。CI 不使用 Apple 证书或描述文件。

- [构建说明](README-BUILD-ZH.txt)
- [重新签名与安装](README-INSTALL-ZH.txt)
- [真机测试协议](TEST-PROTOCOL-ZH.txt)
- [架构和诊断说明](ARCHITECTURE-ZH.txt)

系统可能中断或挂起后台播放。调度成功、播放器状态、扬声器实际发声和微信录入是不同证据；成功或失败都应保存为真实实验结果。
