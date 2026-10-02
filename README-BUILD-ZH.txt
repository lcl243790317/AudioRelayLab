音频接力实验室 — 构建说明

1. 工程与环境
项目根目录包含 project.yml、AudioRelayLab Swift 源码、Assets、scripts、.github/workflows。
工程名称：AudioRelayLab
Bundle ID：com.audiorelaylab.AudioRelayLab
最低系统：iOS 17.0；仅 iPhone。
Windows 可以编辑、运行静态检查、维护 Git，不能运行 Xcode 或编译 iOS App。
project.yml 是工程配置的唯一依据。Info.plist 和 .xcodeproj 在 macOS 的 XcodeGen 步骤生成。
不手动维护 pbxproj。CI 的 Artifact 会保存生成后的真实 .xcodeproj。

2. 本地静态检查
需要 Python 3.10 或更高，命令：
python scripts/static_check.py
python -m unittest discover -s tests -v
如果本机 Python 不在 PATH，可使用 Codex 配置的 Python 可执行文件完整路径。
脚本仅做结构和内容校验，不是 Swift 类型检查，也不是 Xcode 构建。
重新生成图标可执行 python scripts/generate-icon.py，需要 Pillow；正常构建不需要 Pillow。

3. GitHub 与 Actions
现有仓库：https://github.com/lcl243790317/AudioRelayLab
Actions：https://github.com/lcl243790317/AudioRelayLab/actions
推送 main/develop 或创建面向 main 的 PR 时触发。
手动运行：Actions → “iOS 无签名构建” → Run workflow → main → Run workflow。
首次使用 GitHub 时先完成自己的正常登录流程；不向本项目提交认证秘密。

在安装并登录 GitHub CLI 的 Windows 环境，也可使用：
gh auth login
git push -u origin main
gh workflow run build-ios.yml
gh run list --workflow build-ios.yml
gh run view <运行编号> --log-failed
gh run download <运行编号> --name AudioRelayLab-iOS-Build --dir dist

若通过 GitHub 连接器上传后，本机尚未建立 Git 拉取凭据，先完成正常 Git 登录，再拉取远端。
本次源码已使用连接器提交，本地 main 通过 Git 对象 SHA 校验同步了同一远端历史。
原 Windows 初始提交保留在 windows-initial 分支；这不包含 GitHub 登录凭据。
不要强制推送覆盖远端历史。确需另建工作副本时可运行：
git clone https://github.com/lcl243790317/AudioRelayLab.git AudioRelayLab-clone

4. 真实 CI 流程
macos-latest 上打印 sw_vers、Xcode 版本、iPhoneOS SDK、Swift 版本与提交 SHA。
安装 XcodeGen → 静态检查 → xcodegen generate → xcodebuild -list。
Debug / generic iOS Simulator 编译通过后，执行 Release / generic iOS 真机编译。
两次编译均禁用代码签名，使用 set -euo pipefail 与 tee 保留真实退出码和错误输出。
无 Apple P12、密码、provisioning profile、Apple ID 或 App Store Connect Key。
无论成功还是失败，最后尽可能上传日志、xcresult、生成的工程和中文文档。

5. unsigned IPA 与下载
只有 device Release 编译成功后才打包：
build/device/Build/Products/Release-iphoneos/AudioRelayLab.app
→ dist/Payload/AudioRelayLab.app
→ dist/AudioRelayLab-unsigned.ipa
验证可执行文件、Info.plist、Assets.car、arm64 Mach-O、iPhoneOS 平台、最低版本、后台音频与无签名状态。
CI 会保存 IPA 的 SHA-256 和 ipa-manifest.json。
在成功的 Actions 运行页底部下载 AudioRelayLab-iOS-Build Artifact，解压外层 ZIP。
需要的安装输入是其中真实的 AudioRelayLab-unsigned.ipa，不是整个 Artifact ZIP。

6. macOS 手动复现
brew install xcodegen
xcodegen generate
xcodebuild -project AudioRelayLab.xcodeproj -list
使用 build-ios.yml 中完整的模拟器与真机编译命令。
真机编译成功后：bash scripts/package-ipa.sh
下载的 IPA 可以在 Windows 再运行：
python scripts/verify_ipa.py dist/AudioRelayLab-unsigned.ipa

7. 判定与错误修复
只有真实 xcodebuild 返回 0 才能宣称该 SDK / configuration 编译成功。
只有 Artifact 真实含 IPA 才能宣称 IPA 已生成。
编译成功不能证明后台调度不中断、扬声器发声或微信收录。
编译失败时先查看 build-simulator.log / build-device.log 的文件、行号、符号和 availability，
修复真实源文件，提交后重新 CI，保留核心功能。
查看 BUILD-STATUS-ZH.txt 了解本次交付的实际验证状态。

8. API 资料
Apple AVAudioPlayerNode.play(at:)：
https://developer.apple.com/documentation/avfaudio/avaudioplayernode/play(at:)
Apple 麦克风注入能力（18.2+，仅读取）：
https://developer.apple.com/documentation/avfaudio/avaudiosession/ismicrophoneinjectionavailable
XcodeGen 工程规范：
https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
