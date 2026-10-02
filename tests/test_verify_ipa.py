"""IPA 校验器的合成输入测试，不是 iOS 构建产物。"""
import importlib.util
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("verify_ipa", Path(__file__).resolve().parents[1] / "scripts/verify_ipa.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VerificationTests(unittest.TestCase):
    def fixture(self, folder, platform=2, signed=False, background=True):
        path = Path(folder) / "synthetic.ipa"
        commands = struct.pack("<6I", 0x32, 24, platform, 0x00110000, 0x001A0000, 0)
        if signed:
            commands += struct.pack("<4I", 0x1D, 16, 0, 0)
        binary = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 2 if signed else 1, len(commands), 0, 0) + commands
        info = {"CFBundleIdentifier": "com.audiorelaylab.AudioRelayLab", "CFBundleExecutable": "AudioRelayLab",
                "MinimumOSVersion": "17.0", "CFBundleSupportedPlatforms": ["iPhoneOS"],
                "UIBackgroundModes": ["audio"] if background else []}
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/AudioRelayLab.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/AudioRelayLab.app/AudioRelayLab", binary)
            archive.writestr("Payload/AudioRelayLab.app/Assets.car", b"synthetic resource")
        return path

    def test_structurally_valid_input(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(module.verify(self.fixture(folder))["architecture"], "arm64")

    def test_rejects_simulator_arm64(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, "平台"):
                module.verify(self.fixture(folder, platform=7))

    def test_rejects_code_signature(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, "LC_CODE_SIGNATURE"):
                module.verify(self.fixture(folder, signed=True))

    def test_rejects_missing_background_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, "后台音频"):
                module.verify(self.fixture(folder, background=False))

    def test_rejects_missing_executable(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "empty.zip"
            with zipfile.ZipFile(path, "w"):
                pass
            with self.assertRaisesRegex(ValueError, "缺少文件"):
                module.verify(path)


if __name__ == "__main__":
    unittest.main()
