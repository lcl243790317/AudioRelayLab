历史 1.5.0 / build 8 增量：双圆点起止范围、AI 原声录制/转换最高 60 秒、右上角一键日夜切换；见 AI-VOICE-GUIDE-ZH.md。

当前源码基于 1.6.6 / build 16，版本号暂未递增。声音工坊分“配音／混音”，增加草稿自动保存、独立识别片段、最近任务取回、成品跳到播放页及统一回听退出；使用说明见 WORKSHOP-DRAFT-TASKS-ZH.md。录音在手机设备端识别，云端只收到文字及声线参数。认可声线与云端配置保持原状，手机实时处理已移除。

本轮只在 feature/revoice-ios-1.6.0 验证，不合并 main、不发布。当前候选的确切源码、构建结果、IPA 路径和哈希见 WORKSHOP-CI-VALIDATION-ZH.md 与 BUILD-STATUS-ZH.txt；历史 dist/AudioRelayLab-1.6.6-unsigned.ipa 不包含本轮改动，不能用来验收新功能。原 modal-client.json 继续可用；工具 → 云端连接设置 → 从文件导入，或粘贴完整 JSON。签名后的本轮真机操作清单见 WORKSHOP-LOCAL-VALIDATION-ZH.md。


音频接力实验室 — 重新签名与安装

AudioRelayLab-unsigned.ipa 是未签名构建，不能直接作为已签名 App 安装。
请使用自己的合法 Apple 证书与兼容的签名方式，在本地重新签名。
可将真正的 IPA 导入自己使用的全能签 / eSign；具体操作以该工具与自己的签名配置为准。

签名工具需要有效证书，需要与设备、Bundle ID、签名方式兼容的 provisioning profile。
证书、P12 密码、描述文件只在自己的签名环境中使用，不上传到 GitHub 或 CI。
默认 Bundle ID：com.audiorelaylab.AudioRelayLab。
若签名工具修改 Bundle ID，最终 Bundle ID、描述文件、application-identifier 等签名 entitlements 必须匹配。
当前构建没有额外 entitlement 文件，没有推送、iCloud、App Groups 等能力。
后台音频通过 Info.plist 的 UIBackgroundModes = [audio] 配置。
签名工具应保留该配置，并生成与自己证书和描述文件相符的签名 entitlements。

最低系统 iOS 17.0；主要真机测试系统 iOS 18.1.1。
实验的录音配置在准备前请求麦克风权限；声音工坊仅在主动录音时保存原声，配音在校验成功后保存。手机语音输入还需语音识别权限及设备端 zh-CN 识别支持；不可用时可以手动输入。
普通播放配置无需麦克风权限。

安装后首次启动自动使用约 11.7 秒的内置测试 WAV，重复选择只保留同一个文件。
先按 TEST-PROTOCOL-ZH.txt 做前台控制实验，再切换微信做同机扬声器 → 空气 → 麦克风实验。
微信由本人手动切换和录音，项目不控制微信。

若安装失败，先核对：
1. 是否拿到真正的 IPA，而不是 Artifact 外层 ZIP。
2. 是否已重新签名，证书是否有效、描述文件是否匹配设备与 Bundle ID。
3. 重签后是否保留 Info.plist 和正确的可执行文件结构。
4. 系统是否至少为 iOS 17.0。
保留签名工具的实际错误信息在自己的本地环境中排查。
