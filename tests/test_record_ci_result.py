"""CI 日志判定器的合成输入测试；不代表任何 iOS 编译或真机行为。"""
import importlib.util
import sys
import unittest
from pathlib import Path

scripts = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("record_ci_result", scripts / "record-ci-result.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CIEvidenceTests(unittest.TestCase):
    def test_requires_build_success_marker(self):
        with self.assertRaisesRegex(ValueError, "缺少"):
            module.require_success("compilation started", "BUILD", "Simulator")

    def test_rejects_build_failed_even_if_success_marker_exists(self):
        with self.assertRaises(ValueError):
            module.require_success("** BUILD SUCCEEDED **\n** BUILD FAILED **\n", "BUILD", "Device")

    def test_rejects_tests_without_test_success(self):
        for marker in ["", "** TEST EXECUTE FAILED **", "** TEST EXECUTE FAILED **\n** TEST SUCCEEDED **"]:
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                module.parse_xctest("Executed 65 tests, with 0 failures\n"+marker)

    def test_rejects_nonzero_test_failures(self):
        with self.assertRaisesRegex(ValueError, "非零失败"):
            module.parse_xctest("Executed 65 tests, with 1 failure\n** TEST SUCCEEDED **\n")

    def test_reads_final_aggregate_test_count(self):
        for marker in ["** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **"]:
            with self.subTest(marker=marker):
                text = "Executed 12 tests, with 0 failures\nExecuted 65 tests, with 0 failures\n"+marker+"\n"
                self.assertEqual(module.parse_xctest(text, 65), 65)

    def test_rejects_incomplete_test_execution(self):
        with self.assertRaisesRegex(ValueError, "不一致"):
            module.parse_xctest("Executed 12 tests, with 0 failures\n** TEST SUCCEEDED **\n", 65)

    def test_rejects_skipped_test_execution(self):
        with self.assertRaisesRegex(ValueError, "跳过"):
            module.parse_xctest("Test Case 'synthetic' skipped\nExecuted 65 tests, with 0 failures\n** TEST SUCCEEDED **\n", 65)

    def test_rejects_manifest_hash_or_size_mismatch(self):
        actual = {"bytes": 123, "sha256": "a" * 64, "unsigned": True}
        for recorded in [{**actual, "bytes": 124}, {**actual, "sha256": "b" * 64}]:
            with self.assertRaisesRegex(ValueError, "不一致"):
                module.validate_manifest(recorded, actual)

    def test_warning_classification_keeps_metadata_separate(self):
        warnings = module.collect_warnings({"synthetic.log": "file.swift:10:2: warning: synthetic\nwarning: Metadata extraction skipped\n"})
        self.assertEqual(len(warnings), 2)
        self.assertTrue(warnings[0]["swiftCompiler"])
        self.assertFalse(warnings[1]["swiftCompiler"])

    def test_rejects_failing_python_tests(self):
        with self.assertRaises(ValueError):
            module.parse_python_tests("Ran 5 tests in 0.01s\nFAILED (failures=1)\n")

    def test_download_evidence_requires_actual_downloads_and_pending_retry(self):
        report = dict(successfulDownloads=4, pendingResponses=1, longTermCredentialHeadersSeen=False,
                      fixtureOnly=True, productionTLSChanged=False)
        self.assertEqual(module.validate_download_fixture(report), report)
        for failed in [{**report, "successfulDownloads": 0}, {**report, "pendingResponses": 0}]:
            with self.assertRaises(ValueError):
                module.validate_download_fixture(failed)

    def test_download_evidence_rejects_long_term_keys_or_production_tls_changes(self):
        report = dict(successfulDownloads=4, pendingResponses=1, longTermCredentialHeadersSeen=False,
                      fixtureOnly=True, productionTLSChanged=False)
        for failed in [{**report, "longTermCredentialHeadersSeen": True}, {**report, "productionTLSChanged": True},
                       {**report, "fixtureOnly": False}]:
            with self.assertRaises(ValueError):
                module.validate_download_fixture(failed)


if __name__ == "__main__":
    unittest.main()
