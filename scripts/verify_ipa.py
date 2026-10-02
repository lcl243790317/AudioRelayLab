"""核对 unsigned IPA 的结构、配置、Mach-O 平台及 SHA-256；不验证签名后能否安装。"""
import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")


def verify(path):
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError(f"ZIP 校验失败：{bad}")
        names = set(archive.namelist())
        root = "Payload/AudioRelayLab.app/"
        required = {root + "Info.plist", root + "AudioRelayLab", root + "Assets.car"}
        if not required <= names:
            raise ValueError(f"IPA 缺少文件：{required - names}")
        if any(name.startswith("/") or ".." in Path(name).parts for name in names):
            raise ValueError("IPA 含无效路径")
        if any(name.endswith("embedded.mobileprovision") or "/_CodeSignature/" in name for name in names):
            raise ValueError("IPA 包含签名资料")
        info = plistlib.loads(archive.read(root + "Info.plist"))
        expected = {"CFBundleIdentifier": "com.audiorelaylab.AudioRelayLab", "CFBundleExecutable": "AudioRelayLab", "MinimumOSVersion": "17.0"}
        for key, value in expected.items():
            if info.get(key) != value:
                raise ValueError(f"{key} 应为 {value}，实际为 {info.get(key)}")
        if "audio" not in info.get("UIBackgroundModes", []):
            raise ValueError("未配置后台音频")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("不是 iPhoneOS 构建")
        executable = archive.read(root + "AudioRelayLab")
        if len(executable) < 32:
            raise ValueError("可执行文件为空或过短")
        magic, cpu_type, _, _, command_count, _, _, _ = struct.unpack_from("<8I", executable)
        if magic != 0xFEEDFACF or cpu_type != 0x0100000C:
            raise ValueError("可执行文件不是 arm64 Mach-O")
        offset, platform, min_version = 32, None, None
        for _ in range(command_count):
            command, size = struct.unpack_from("<II", executable, offset)
            if size < 8 or offset + size > len(executable):
                raise ValueError("Mach-O load command 无效")
            if command == 0x1D:
                raise ValueError("可执行文件包含 LC_CODE_SIGNATURE，不能作为无签名产物")
            if command == 0x32:
                platform, min_version = struct.unpack_from("<II", executable, offset + 8)
            offset += size
        if platform != 2 or min_version != 0x00110000:
            raise ValueError(f"Mach-O 平台或最低版本不正确：platform={platform}，minOS={min_version}")
    result = {**expected, "UIBackgroundModes": info["UIBackgroundModes"],
              "platform": "iPhoneOS", "architecture": "arm64", "unsigned": True,
              "sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest(), "bytes": Path(path).stat().st_size}
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    result = verify(args.ipa)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    print(text)
    if args.manifest:
        args.manifest.write_text(text + "\n", encoding="utf-8")
