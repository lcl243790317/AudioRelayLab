"""Windows / CI 静态自检，不代表 Xcode 编译成功。仅使用 Python 标准库。"""
import json
import re
import struct
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

root = Path(__file__).resolve().parents[1]
errors = []
required = ["project.yml", ".github/workflows/build-ios.yml", "README-BUILD-ZH.txt",
            "README-INSTALL-ZH.txt", "TEST-PROTOCOL-ZH.txt", "AudioRelayLab/AudioRelayLabApp.swift",
            "scripts/package-ipa.sh", "scripts/verify_ipa.py",
            "AudioRelayLab/Experiments/ExperimentStateMachine.swift",
            "AudioRelayLab/Experiments/ExperimentParameters.swift",
            "AudioRelayLabTests/ExperimentStateMachineTests.swift",
            "AudioRelayLabTests/ParameterTests.swift",
            "VOICE-PROCESSING-RESEARCH-ZH.md", "VOICE-LAB-TEST-PROTOCOL-ZH.md",
            "AudioRelayLab/VoiceLab/DSP/VoiceDSP.cpp",
            "AudioRelayLab/VoiceLab/Vendor/LICENSE-stretch.txt",
            "AudioRelayLab/VoiceLab/Vendor/LICENSE-linear.txt",
            "AudioRelayLab/Resources/THIRD-PARTY-NOTICES.txt",
            "AudioRelayLabTests/VoiceLabTests.swift"]
for name in required:
    if not (root / name).is_file():
        errors.append(f"缺少文件：{name}")
def swift_code_only(source):
    """Strip Swift comments/literals for a conservative lexical safety audit, not compilation."""
    output = []
    index = 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
            output.append(" ")
        elif source.startswith("/*", index):
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    if source[index] == "\n":
                        output.append("\n")
                    index += 1
            output.append(" ")
        elif source[index] == '"':
            delimiter = '"""' if source.startswith('"""', index) else '"'
            index += len(delimiter)
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source.startswith(delimiter, index):
                    index += len(delimiter)
                    break
                else:
                    if source[index] == "\n":
                        output.append("\n")
                    index += 1
            output.append(" ")
        else:
            output.append(source[index])
            index += 1
    return "".join(output)


sources = list((root / "AudioRelayLab").rglob("*.swift"))
test_sources = list((root / "AudioRelayLabTests").rglob("*.swift"))
for path in sources + test_sources:
    text = path.read_text(encoding="utf-8")
    if re.search(r"\b(TODO|FIXME|placeholder)\b|mock implementation", text, re.I):
        errors.append(f"源码存在未实现标记：{path.relative_to(root)}")
    code = swift_code_only(text)
    if re.search(r"\btry\s*!|\bas\s*!|\b(?:fatalError|preconditionFailure)\s*\(", code):
        errors.append(f"存在强制执行或可恢复错误崩溃入口：{path.relative_to(root)}")
    if re.search(r"(?:\b[A-Za-z_]\w*|[)\]])!(?!=)", code):
        errors.append(f"存在强制解包或隐式解包：{path.relative_to(root)}")
    if re.search(r"Button\([^\n]*\)\s*\{\s*\}", text):
        errors.append(f"存在空按钮：{path.relative_to(root)}")
for path in (root / "AudioRelayLab/Assets.xcassets").rglob("*.json"):
    try:
        json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:
        errors.append(f"资源 JSON 无效：{path.name}：{error}")
icon = root / "AudioRelayLab/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
if icon.is_file():
    data = icon.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (1024, 1024):
        errors.append("图标必须是 1024 × 1024 PNG")
else:
    errors.append("缺少 App 图标")
session = (root / "AudioRelayLab/Audio/AudioSessionManager.swift").read_text(encoding="utf-8")
for symbol in ["interruptionNotification", "routeChangeNotification", "mediaServicesWereLostNotification",
               "mediaServicesWereResetNotification", "silenceSecondaryAudioHintNotification"]:
    if symbol not in session:
        errors.append(f"缺少会话通知：{symbol}")
player = (root / "AudioRelayLab/Audio/AVAudioPlayerPlaybackEngine.swift").read_text(encoding="utf-8")
engine = (root / "AudioRelayLab/Audio/AVAudioEnginePlaybackEngine.swift").read_text(encoding="utf-8")
if not re.search(r"\.play\(atTime:", player) or not re.search(r"\.play\(at:\s*AVAudioTime\(hostTime:", engine):
    errors.append("缺少音频系统未来时间调度")
profile = (root / "AudioRelayLab/Audio/AudioSessionProfile.swift").read_text(encoding="utf-8")
if not re.search(r'case\s+playback\s*=\s*"B"', profile):
    errors.append("缺少历史 B 兼容枚举值")
if "selectableCases" not in profile or "isSelectable" not in profile:
    errors.append("缺少 A/C/D/E 新实验选择白名单和 B 停用校验")
for view in (root / "AudioRelayLab/Views").rglob("*.swift"):
    if "AudioSessionProfile.allCases" in swift_code_only(view.read_text(encoding="utf-8")):
        errors.append(f"新实验 UI 不应暴露历史 B 配置：{view.relative_to(root)}")
spec = (root / "project.yml").read_text(encoding="utf-8")
for marker in ["AudioRelayLabTests:", "bundle.unit-test", "testTargets:", "CallKit.framework", "'1.2.1'"]:
    if marker not in spec:
        errors.append(f"XcodeGen 缺少配置：{marker}")
if not test_sources or any("@testable import AudioRelayLab" not in p.read_text(encoding="utf-8") for p in test_sources):
    errors.append("Swift 单元测试必须直接导入真实 AudioRelayLab 模块")
workflow = (root / ".github/workflows/build-ios.yml").read_text(encoding="utf-8")
for marker in ["macos-latest", "workflow_dispatch", "xcodegen generate", "set -euo pipefail", "CODE_SIGNING_ALLOWED=NO",
               "if: always()", "contents: read", "simctl list devices available --json", "build-xctest.log", "test 2>&1",
               "BUILD-STATUS-ZH.txt", "dist/SHA256SUMS.txt"]:
    if marker not in workflow:
        errors.append(f"CI 缺少配置：{marker}")
if "secrets." in workflow:
    errors.append("CI 不应依赖签名秘密")
if re.search(r"contents:\s*write", workflow):
    errors.append("只为构建的 CI 不能扩大仓库写权限")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"静态检查通过：{len(sources)} 个 App Swift 文件，{len(test_sources)} 个 XCTest 文件；危险入口、资源、调度、通知、兼容值、CI 配置已审查。")
print("这是静态检查；Swift 单元测试以真实 Simulator xcodebuild test 的结果为准；不能据此宣称编译或音频真机行为通过。")
