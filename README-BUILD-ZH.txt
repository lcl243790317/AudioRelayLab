当前修订 1.6.8 / build 18：三个正式编辑框的键盘修复候选，当前 macOS CI／新 IPA 结果见 REVOICE-1.6.8-TEST-REPORT-ZH.md。真机验收待用户复测，禁止用下面旧 1.6.7 构建结论作为本轮通过证据。

以下开头保留上一版本的历史说明：
当前源码为 1.6.7 / build 17：修订语音识别后的连续键盘输入，取消识别片段设置，完整 0.3～60 秒音频用于识别，自动表达默认开启。版本 2 草稿忽略旧识别区间；旧草稿升级采用新默认一次，此后保存手动关闭选择，冻结旧任务保持原参数。功能见 WORKSHOP-DRAFT-TASKS-ZH.md；当前实际编译与交付状态见 REVOICE-1.6.7-TEST-REPORT-ZH.md 和 BUILD-STATUS-ZH.txt。此前 1.6.6 macOS 成功及 IPA 仅为历史证据。

AudioRelayLab — 构建与验证说明

1. 在现有工程上迭代
仓库：https://github.com/lcl243790317/AudioRelayLab
项目：AudioRelayLab；Bundle ID：com.audiorelaylab.AudioRelayLab。
最低 iOS 17.0，仅 iPhone。现有 Git 历史、源码、XcodeGen 与 IPA 校验流程均继续使用。
project.yml 是工程配置依据，Info.plist 和 .xcodeproj 由 XcodeGen 在 macOS 生成。
不手写 pbxproj，不重建仓库，不强制推送覆盖历史。

Windows 可以编辑、做 Python 静态检查、维护 Git，不能执行 Xcode iOS 编译。
真实 Swift 类型检查、单元测试和 iOS 编译必须在 macOS / Xcode 上完成。

2. 本地可执行检查
本轮 CI 固定 Python 3.12 与 server/ci-requirements.txt：
python scripts/static_check.py
python -m unittest discover -s tests -v
python scripts/verify_ipa.py dist/AudioRelayLab-unsigned.ipa

静态脚本检查源码风险标记、工程结构、资源、未来音频调度入口、通知和安全 CI 配置。
Python 单元测试验证 IPA 检查器等脚本行为；合成校验输入不属于真正构建产物。
Swift 自动测试由 CI 在真实 Apple 工具链执行，覆盖数据、状态机和参数。
具体测试入口与执行日志以 .github/workflows/build-ios.yml 和本轮 build-*.log 为准。
只有实际执行且返回 0 的测试可标为通过。静态检查不能代替 Swift 编译或真机回归。

3. 真实 GitHub Actions
Actions：https://github.com/lcl243790317/AudioRelayLab/actions
推送 main / develop、面向 main 的 PR 或 workflow_dispatch 可以触发。
手动运行：Actions → “iOS 无签名构建” → Run workflow → feature/revoice-ios-1.6.0。本轮使用功能分支 workflow_dispatch，checkout 使用确切源码 SHA。

CI 默认 contents: read，构建不扩大写权限。
不得提交 Apple certificate、private key、密码、provisioning profile、GitHub token 或账户秘密。
当前无用户签名材料时，保留合法无签名构建流程，不伪造签名成功。

在已正常登录 GitHub CLI 的环境，可使用：
git push -u origin feature/revoice-ios-1.6.0
gh workflow run build-ios.yml --ref feature/revoice-ios-1.6.0
gh run list --workflow build-ios.yml
gh run view <运行编号> --log-failed
gh run download <运行编号> --name AudioRelayLab-iOS-Build --dir dist

如果 Git 缺少凭据，完成正常账户登录后再拉取，不从浏览器或连接器提取 token。
通过连接器写入后，本机 Git 可能需要重新同步；不能以不相关本地提交冒充云端源码。
本次本地与远端提交 SHA 以及干净状态记录在 BUILD-STATUS-ZH.txt。

4. 必须完成的真实流水线
当前标准 runner 为 macos-15 Apple Silicon，以 DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer 固定 Xcode 16.4，并严格选择 iOS 18.5 Simulator，作为本项目 iOS 18 回归基线。
第 39 次实际环境已记录 macOS 15.7.9、iPhoneOS SDK 18.5、Swift 6.1.2、XcodeGen 2.46.0；每次仍打印 macOS、Xcode、SDK、Swift、XcodeGen 和源码 SHA，以该次原始日志为准。
历史第 29 次因 arm64 托管容量不足未取得 runner，后续曾使用 macos-26-intel；2026-10-09 转到上述固定工具链，完整测试步骤保持。
静态检查 / Python 测试 → xcodegen generate / xcodebuild -list。
xcodebuild Simulator Debug → 实际 iPhone Simulator 全部 XCTest → 完整 UI 回归 → iPhone SE 小屏检查 → generic iOS Release。
两次编译禁用代码签名，用 set -euo pipefail 与 tee 同时保留输出和真实退出码。
真机 Release 成功后再打包 IPA，执行 verify_ipa.py，检查日志错误与 warning。
具体执行次序和 XCTest destination 以 workflow 的完整命令为准。
标准完整任务有 240 分钟上限。UI 启用 XCTest 单用例时限：默认 600 秒，多退出上下文的试听、批量删除和连接页主题／大字体用例显式 1800 秒，最大 1800 秒；超时是测试失败，不能记为通过。批删在第 30 次实际通过耗时 697.099 秒；连接页十次设置访问在第 35 次超过 600 秒，日志在 781.83 秒仍有布局检查，故对该多场景用例单独配置更长时限，保留全部断言。
scripts/run-recorded-ui-tests.py 运行实际 xcodebuild，保留退出码，只清理自己创建的录屏／测试进程；录屏退出按 20／5／5 秒升级终止，视频必须经 ffmpeg 解码出真实画面。
在 XCTest 和完整 UI 阶段分别上传 AudioRelayLab-XCTest-Checkpoint、AudioRelayLab-UI-Logs，完整产物保留在 AudioRelayLab-iOS-Build；阶段日志可提前取回，不能用阶段成功替代整条流水线。
如果产生编译错误，必须修复真正源文件并再次 CI，不能只写一份成功报告。

只有 xcodebuild exit code = 0 才能说对应配置“编译成功”。
编译成功不证明通话中不会闪退、不证明后台连续播放，也不证明微信收录。
C 在电话 / 微信实时通话中点击准备的真机回归仍是 release blocker。
CI 完成的 IPA 可以作为用户自行签名后的回归测试构建；稳定发布还需真机证据。

5. 真正的 unsigned IPA 与校验
输入：build/device/Build/Products/Release-iphoneos/AudioRelayLab.app。
打包：dist/Payload/AudioRelayLab.app → dist/AudioRelayLab-unsigned.ipa。
校验 Payload、.app、可执行文件、Assets.car、Info.plist、arm64 Mach-O、
iPhoneOS 平台、最低版本、Background Audio 与无签名状态。
ipa-manifest.json 保存真实 SHA-256 和产物属性。

在成功运行底部下载 AudioRelayLab-iOS-Build Artifact，并解压外层 ZIP。
安装前重新签名的输入是其中的 AudioRelayLab-unsigned.ipa，不是外层 Artifact ZIP。
这是编译完成但未签名的 IPA，需要使用你的证书重新签名。
本轮实际 IPA 路径、字节数、哈希、run / commit / Artifact 链接见 BUILD-STATUS-ZH.txt。

Artifact 至少应含 IPA、ipa manifest、build log、environment info、generated xcodeproj、
合理大小的 xcresult、BUILD-STATUS-ZH.txt 与 TEST-PROTOCOL-ZH.txt。
报告的构建 SHA 与 Artifact 打包时文件之间应能核对；构建后的报告更新不能虚构进旧 Artifact。

6. macOS 手动复现
brew install xcodegen ffmpeg
python3 scripts/generate-audio-fixtures.py
xcodegen generate
xcodebuild -project AudioRelayLab.xcodeproj -list
按 .github/workflows/build-ios.yml 运行自动测试、模拟器和真机编译完整命令。
真机编译成功后：bash scripts/package-ipa.sh。
不要把 generic iOS Simulator build 当成 generic iPhoneOS build。

7. 实现边界
使用公开音频 API、合法 background audio 与真实音频，无静音保活、私有 API、
微信注入、电话音频抓取、越狱 hook 或系统音量修改。
公开资料：
https://developer.apple.com/documentation/callkit/cxcallobserver
https://developer.apple.com/documentation/swift/handling-cocoa-errors-in-swift
https://developer.apple.com/documentation/avfaudio/avaudioplayernode/play(at:)
https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md

8. 当前音频与工坊复现
CI 在 XcodeGen 前用 Python 自有正弦信号生成 Bundle 测试 WAV，并通过 ffmpeg 真正编码
MP3/M4A/AAC/WAV/AIFF/AIFC/CAF/FLAC。夹具不含用户人声，不把扩展名改名冒充格式。
请先运行 generate-audio-fixtures.py，否则 codec XCTest 缺少资源应真实失败。
ffmpeg 仅用于 CI 夹具生成，不进入 iOS App。App 解码使用 AVFoundation。
手机实时 Voice DSP 已在 1.6.1 移除，不再编译 vendored C++ 或实时麦克风处理链。
当前设备端识别使用 Speech；混音和音频处理使用 AVFoundation，云端生成只接收文字与目标参数。
XCTest 使用本地 PCM、录音／识别注入和 URLProtocol 模拟提交；异步结果下载使用隔离的可信 loopback HTTPS 服务。
夹具就绪等待最多 60 秒，证书或 HTTP 错误直接失败；不放松生产 TLS，不调用真实付费 GPU。

自动测试包括真实编码读取／复制、AVAudioPlayer 参数、frame seek、CAF 裁剪、历史兼容、
原生 AVAudioEngine 离线混音、音量独立、起点与 rate，以及草稿原子保存／恢复、旧草稿升级、完整音频识别与超长拒绝、
冻结任务重试／停止／取回／单次入库、导航失败保护和页面回听取消。
识别准备回归比较完整输入的实际 PCM，检查超长音频未被截取、原文件保持不变，以及播放／混音参数不影响识别。
UI 回归检查识别后连续真实软键输入、保存后焦点、完成与外点收键盘，以及真实标签、系统分享页、选择器、失败提示和布局；合成 PCM 不证明真人语音质量或实际麦克风。
具体最终测试数/工具链/IPA SHA 以 BUILD-STATUS 和 dist/build-evidence.json 为准。

9. 保留的音频与真机问题回归
DeviceBugRegressionTests 检查原生 picker delegate→真实 MP3 导入、取消、默认测试音
ID/文件/修改时间复用及旧副本合并；0.5/1/2x 真实离线 PCM 时长与非零能量；
两套真实播放器 2x 内容在 0.8 秒 deadline 前／后的时间线；当前录音器与离线 Mixer 的
CAF 保存及通知处理，另注入同类通知检查未变路由不误停。
CI 仅给临时 iPhone Simulator 的本 App 授予麦克风权限；不改变用户设备权限。
Simulator 录音可能为零输入，不能证明真人音色、声学延迟或 18.1.1 Files 点击。
本轮真机逐步清单见 WORKSHOP-LOCAL-VALIDATION-ZH.md；VOICE-LAB-TEST-PROTOCOL-ZH.md 中旧实时流程仅为历史资料。
