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
            "scripts/package-ipa.sh", "scripts/verify_ipa.py"]
for name in required:
    if not (root / name).is_file():
        errors.append(f"缺少文件：{name}")
sources = list((root / "AudioRelayLab").rglob("*.swift"))
for path in sources:
    text = path.read_text(encoding="utf-8")
    if re.search(r"\b(TODO|FIXME|placeholder)\b|fatalError\s*\(|mock implementation", text, re.I):
        errors.append(f"源码存在未实现标记：{path.relative_to(root)}")
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
if "play(atTime: target)" not in player or "play(at: AVAudioTime(hostTime: hostTime))" not in engine:
    errors.append("缺少音频系统未来时间调度")
workflow = (root / ".github/workflows/build-ios.yml").read_text(encoding="utf-8")
for marker in ["macos-latest", "workflow_dispatch", "xcodegen generate", "set -euo pipefail", "CODE_SIGNING_ALLOWED=NO", "if: always()"]:
    if marker not in workflow:
        errors.append(f"CI 缺少配置：{marker}")
if "secrets." in workflow:
    errors.append("CI 不应依赖签名秘密")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"静态检查通过：{len(sources)} 个 Swift 文件；资源、真实调度入口、通知、CI 配置存在。")
print("此结果不代表 Xcode 编译成功，也不代表 unsigned IPA 已生成。")
