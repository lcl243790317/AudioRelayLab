"""Record evidence only after the real Actions build/test/package steps have succeeded.

Synthetic parser inputs in tests are not compilation evidence. This entry point
requires the GitHub Actions environment and re-verifies the actual unsigned IPA.
"""
import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

from verify_ipa import verify


def require_success(text, kind, label):
    clean = re.sub(r"\x1b\[[0-9;]*m", "", text)
    markers = re.findall(rf"^\s*\*\*\s+{re.escape(kind)}\s+(SUCCEEDED|FAILED)\s+\*\*\s*$", clean, re.M)
    if not markers or markers[-1] != "SUCCEEDED" or "FAILED" in markers:
        raise ValueError(f"{label} 缺少唯一成功结果或存在失败标记")


def parse_xctest(text, expected_count=None):
    require_success(text, "TEST", "XCTest")
    summaries = re.findall(r"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?", text)
    if not summaries or any(int(failures) != 0 for _, failures in summaries):
        raise ValueError("XCTest 缺少执行汇总或报告非零失败")
    count = int(summaries[-1][0])
    if count <= 0 or (expected_count is not None and count != expected_count):
        raise ValueError(f"XCTest 实际执行 {count} 项，与要求 {expected_count} 不一致")
    if re.search(r"Test Case[^\n]*\bskipped\b", text, re.I):
        raise ValueError("XCTest 存在跳过测试，不能记录完整通过")
    return count


def parse_python_tests(text):
    summaries = re.findall(r"^Ran\s+(\d+)\s+tests?\s+in\s+", text, re.M)
    if not summaries or not re.search(r"^OK\s*$", text, re.M) or re.search(r"^FAILED\b", text, re.M):
        raise ValueError("Python 自检缺少通过汇总或存在失败")
    count = int(summaries[-1])
    if count <= 0:
        raise ValueError("Python 自检未执行测试")
    return count


def validate_manifest(recorded, actual):
    if recorded != actual:
        raise ValueError("IPA manifest 与重新验证的实际文件大小、SHA-256 或结构不一致")


def validate_download_fixture(report):
    if (report.get("successfulDownloads", 0) < 4 or report.get("pendingResponses", 0) < 1
            or report.get("longTermCredentialHeadersSeen") is not False
            or report.get("fixtureOnly") is not True or report.get("productionTLSChanged") is not False):
        raise ValueError("缺少真实 HTTPS 下载/202 恢复证据，或下载请求暴露长期凭据")
    return report


def environment_info(environment_text, xcodegen_text):
    patterns = {
        "macOS": r"^ProductVersion:\s*(.+)$",
        "macOSBuild": r"^BuildVersion:\s*(.+)$",
        "xcode": r"^Xcode\s+(.+)$",
        "xcodeBuild": r"^Build version\s+(.+)$",
        "iPhoneOSSDK": r"^(\d+\.\d+(?:\.\d+)?)$",
        "swift": r"Apple Swift version\s+(\S+)",
    }
    result = {}
    for key, pattern in patterns.items():
        match = re.search(pattern, environment_text, re.M)
        if not match:
            raise ValueError(f"环境日志缺少真实 {key} 版本")
        result[key] = match.group(1).strip()
    match = re.search(r"^Version:\s*(.+)$", xcodegen_text, re.M)
    if not match:
        raise ValueError("环境日志缺少真实 XcodeGen 版本")
    result["xcodegen"] = match.group(1).strip()
    result["rawEnvironmentLog"] = environment_text
    result["rawXcodeGenLog"] = xcodegen_text
    return result


def collect_warnings(logs):
    result = []
    for name, text in logs.items():
        for line in text.splitlines():
            if "warning:" in line.lower():
                result.append({"log": name, "message": line.strip(),
                               "swiftCompiler": bool(re.search(r"\.swift:\d+(?::\d+)?:\s*warning:", line, re.I))})
    return result


def replace_status(text, evidence):
    end = text.find("真机已有观察")
    starts = [text.find(marker) for marker in ["待本轮真实 CI 更新：", "本轮真实 CI 证据："]]
    starts = [position for position in starts if 0 <= position < end]
    if len(starts) != 1:
        raise ValueError("BUILD-STATUS 缺少或重复真实 CI 证据区块标记")
    env = evidence["environment"]
    ipa = evidence["ipa"]
    messages = sorted({re.split(r"warning:", item["message"], maxsplit=1, flags=re.I)[-1].strip() for item in evidence["warnings"]})
    warning_summary = "；".join(messages) if messages else "无"
    block = (
        "本轮真实 CI 证据：\n"
        f"- 源码提交：{evidence['sourceCommit']}\n"
        f"- Actions run：{evidence['workflowRunURL']}\n"
        "- XcodeGen 已生成真实工程；Simulator Debug 与 iPhoneOS Release 均记录 BUILD SUCCEEDED。\n"
        f"- 实际 iPhone Simulator XCTest：{evidence['xctestCount']} 项，0 失败，TEST SUCCEEDED。\n"
        f"- UI 测试：{evidence.get('uiTestCount',0)} 项通过；真实录屏见 build/ui-interaction.mp4。\n"
        f"- 小屏布局：iPhone SE（第三代）UI 截图测试 {evidence.get('smallScreenUITestCount',0)} 项通过；常规屏及小屏附件展示已选音乐后的浅色、深色和大字体时间控件。\n"
        f"- 隔离 HTTPS 下载：{evidence.get('downloadFixture',{}).get('successfulDownloads',0)} 次成功，202 续取回已验证；未发送长期密钥。\n"
        f"- Python 自检：{evidence['pythonTestCount']} 项通过。\n"
        "- 上述 xcodebuild 命令由此前工作流步骤的 set -euo pipefail 保证返回 0，证据步骤才会运行。\n"
        f"- unsigned IPA：dist/AudioRelayLab-unsigned.ipa；{ipa['bytes']} 字节。\n"
        f"- SHA-256：{ipa['sha256']}\n"
        "- verify_ipa 重新检查通过，结果与 ipa-manifest.json 完全一致；未签名，需用户证书重新签名。\n"
        f"- 环境：macOS {env['macOS']} / {env['macOSBuild']}；Xcode {env['xcode']} / {env['xcodeBuild']}；"
        f"iPhoneOS SDK {env['iPhoneOSSDK']}；Swift {env['swift']}；XcodeGen {env['xcodegen']}。\n"
        f"- Swift 编译警告：{evidence['swiftWarningCount']}；全部构建警告：{warning_summary}\n"
        "- Artifact 同时包含 dist/build-evidence.json、环境/构建日志、xcresult、生成工程和 IPA manifest。\n"
        "- 编译和自动测试不证明新版本通话中音频行为；下方真机 release blocker 仍须实测。\n\n"
    )
    updated = text[:starts[0]] + block + text[end:]
    # Keep earlier evidence wording current as the Python suite grows.
    updated = re.sub(r"- \d+ 项 Python IPA 校验器测试通过。", "- Python IPA/CI 证据校验器测试已运行，当前数量见本轮真实 CI 证据。", updated)
    return updated


def record(root, environ):
    if environ.get("GITHUB_ACTIONS") != "true":
        raise ValueError("只允许在真实 GitHub Actions 的成功步骤之后记录构建证据")
    sha = environ.get("AUDIOLAB_SOURCE_COMMIT", environ.get("GITHUB_SHA", ""))
    repository = environ.get("GITHUB_REPOSITORY", "")
    run_id = environ.get("GITHUB_RUN_ID", "")
    server = environ.get("GITHUB_SERVER_URL", "").rstrip("/")
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("GitHub Actions 提交或仓库标识无效")
    if not run_id.isdigit() or int(run_id) <= 0:
        raise ValueError("GitHub Actions run ID 无效")
    url = urlsplit(server)
    if url.scheme != "https" or not url.netloc or url.path or url.query or url.fragment:
        raise ValueError("GitHub Actions server URL 无效")
    run_url = f"{server}/{repository}/actions/runs/{run_id}"
    names = ["build-simulator.log", "build-device.log", "build-xctest.log", "build-tests.log",
             "build-environment.log", "build-xcodegen-version.log", "build-static.log", "build-uitest.log", "build-small-uitest.log"]
    logs = {name: (root / name).read_text(encoding="utf-8") for name in names}
    require_success(logs["build-simulator.log"], "BUILD", "Simulator Debug")
    require_success(logs["build-device.log"], "BUILD", "iPhoneOS Release")
    if not re.search(rf"^源码提交：{re.escape(sha)}\s*$", logs["build-environment.log"], re.M):
        raise ValueError("真实环境日志提交与本次 GITHUB_SHA 不一致，拒绝使用旧日志")
    expected_count = sum(len(re.findall(r"\bfunc\s+test\w+", path.read_text(encoding="utf-8")))
                         for path in (root / "AudioRelayLabTests").glob("*.swift"))
    count = parse_xctest(logs["build-xctest.log"], expected_count)
    expected_ui = sum(len(re.findall(r"\bfunc\s+test\w+", path.read_text(encoding="utf-8")))
                      for path in (root / "AudioRelayLabUITests").glob("*.swift"))
    ui_count = parse_xctest(logs["build-uitest.log"],expected_ui)
    small_ui = logs["build-small-uitest.log"]
    small_ui_count = parse_xctest(small_ui,1)
    screenshots = {}
    for name in ("ui-attachments", "ui-small-attachments"):
        images = sorted((root / "build" / name).rglob("*.png"))
        if len(images) < 8:
            raise ValueError(f"{name} 缺少已选音乐的浅色、深色及大字体截图")
        screenshots[name] = [{"path":str(path.relative_to(root)), "sha256":hashlib.sha256(path.read_bytes()).hexdigest()} for path in images]
    download_fixture = validate_download_fixture(json.loads((root / "build/revoice-download-fixture-report.json").read_text(encoding="utf-8")))
    if not (root / "build/ui-interaction.mp4").is_file(): raise ValueError("缺少真实 UI 测试录屏")
    if "静态检查通过：" not in logs["build-static.log"]:
        raise ValueError("缺少静态检查通过结果")
    if not (root / "AudioRelayLab.xcodeproj/project.pbxproj").is_file():
        raise ValueError("缺少 XcodeGen 实际生成工程")
    ipa = verify(root / "dist/AudioRelayLab-unsigned.ipa")
    manifest = json.loads((root / "dist/ipa-manifest.json").read_text(encoding="utf-8"))
    validate_manifest(manifest, ipa)
    warnings = collect_warnings({name: logs[name] for name in ["build-simulator.log", "build-device.log", "build-xctest.log", "build-uitest.log"]})
    evidence = {
        "schemaVersion": 1,
        "generatedAtUTC": datetime.now(timezone.utc).isoformat(),
        "sourceCommit": sha,
        "repository": repository,
        "workflowRunID": int(run_id),
        "workflowRunURL": run_url,
        "xctestCount": count,
        "uiTestCount": ui_count,
        "uiTestFailures": 0,
        "smallScreenUITestCount": small_ui_count,
        "smallScreenUITestFailures": 0,
        "smallScreenDestination": (root / "build-small-destination.log").read_text(encoding="utf-8").strip(),
        "screenshots": screenshots,
        "downloadFixture": download_fixture,
        "expectedXCTestCount": expected_count,
        "xctestFailures": 0,
        "pythonTestCount": parse_python_tests(logs["build-tests.log"]),
        "simulatorDebug": "BUILD SUCCEEDED",
        "iPhoneOSRelease": "BUILD SUCCEEDED",
        "xctest": "TEST SUCCEEDED",
        "successGatedByWorkflowPipefail": True,
        "ipa": ipa,
        "environment": environment_info(logs["build-environment.log"], logs["build-xcodegen-version.log"]),
        "warnings": warnings,
        "swiftWarningCount": sum(item["swiftCompiler"] for item in warnings),
        "logs": {name: {"sha256": hashlib.sha256((root / name).read_bytes()).hexdigest(),
                        "bytes": (root / name).stat().st_size} for name in names},
        "deviceValidationRequired": True,
    }
    report = root / "BUILD-STATUS-ZH.txt"
    updated_report = replace_status(report.read_text(encoding="utf-8"), evidence)
    output = root / "dist/build-evidence.json"
    output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report.write_text(updated_report, encoding="utf-8")
    print(f"真实 CI 证据已核对：XCTest {count} 项；IPA {ipa['bytes']} 字节；SHA-256 {ipa['sha256']}；Swift 警告 {evidence['swiftWarningCount']}")


if __name__ == "__main__":
    record(Path(__file__).resolve().parents[1], os.environ)
