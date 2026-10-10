当前版本 1.6.8 / build 18；源码 965a3485279b89b98235b86a02f36d0fd39af682。
标准完整 CI55 / 38046537225 成功：99 CPU、286 原生、25 UI、1 SE，0 失败；Simulator Debug／iPhoneOS Release 成功。
新 unsigned IPA：dist/AudioRelayLab-workshop-965a348-unsigned.ipa；大小 1,655,490 字节。
SHA-256：2f6e677ab9804ad877d766922a154c0d30049c67bfc6b3ab3adfd8c3c3998a15
代码与自动化验证完成，待真机验收；真机验收待用户复测。
安装后确认 App 版本 1.6.8 / build 18，并分别复测三个编辑框；清单与证据见 REVOICE-1.6.8-TEST-REPORT-ZH.md。
旧 1.6.7 的模拟器通过不能代表真机修复，本次不使用旧包。

音频接力实验室 — 重新签名与安装

上方列出的新 unsigned IPA 是未签名构建，不能直接作为已签名 App 安装。
请使用自己的合法 Apple 证书与兼容的签名方式，在本地重新签名。
可将真正的 IPA 导入自己使用的全能签 / eSign；具体操作以该工具与自己的签名配置为准。

签名工具需要有效证书，需要与设备、Bundle ID、签名方式兼容的 provisioning profile。
证书、P12 密码、描述文件只在自己的签名环境中使用，不上传到 GitHub 或 CI。
默认 Bundle ID：com.audiorelaylab.AudioRelayLab。
若签名工具修改 Bundle ID，最终 Bundle ID、描述文件、application-identifier 等签名 entitlements 必须匹配。
当前构建没有额外 entitlement 文件，没有推送、iCloud、App Groups 等能力。
后台音频通过 Info.plist 的 UIBackgroundModes = [audio] 配置。
签名工具应保留该配置，并生成与自己证书和描述文件相符的签名 entitlements。

最低系统 iOS 17.0；用户历史设备系统 iOS 18.1.1，本轮真实设备验收尚未执行。
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
