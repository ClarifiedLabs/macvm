#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "compare-docker-compat.py"
SPEC = importlib.util.spec_from_file_location("compare_docker_compat", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


HEADER = "test_id\tstatus\tduration_ms\tpolicy\tnote\n"
SUITE_PATH = ROOT / "Tests" / "DockerCompatibility" / "suite.sh"
HARNESS_PATH = ROOT / "scripts" / "test-docker-e2e.sh"


class DockerCompatibilityReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.macvm = self.root / "macvm.tsv"
        self.baseline = self.root / "baseline.tsv"
        self.xfails = self.root / "xfail.tsv"
        self.output = self.root / "report"
        self.xfails.write_text("", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_report(self, *, baseline: bool = False) -> int:
        arguments = [
            "--macvm-results",
            str(self.macvm),
            "--xfails",
            str(self.xfails),
            "--output-dir",
            str(self.output),
            "--run-id",
            "test-run",
            "--suite",
            "full",
        ]
        if baseline:
            arguments.extend(["--baseline-results", str(self.baseline)])
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return MODULE.main(arguments)

    def summary(self) -> dict:
        return json.loads((self.output / "summary.json").read_text(encoding="utf-8"))

    def test_pass_and_optional_skip_succeed(self) -> None:
        self.macvm.write_text(
            HEADER
            + "engine.cli\tPASS\t10\trequired\tok\n"
            + "architecture.amd64\tSKIP\t0\toptional\tnot installed\n",
            encoding="utf-8",
        )
        self.assertEqual(self.run_report(), 0)
        self.assertTrue(self.summary()["passed"])
        self.assertEqual(self.summary()["counts"], {"PASS": 1, "SKIP": 1})
        self.assertTrue((self.output / "junit.xml").exists())
        self.assertTrue((self.output / "results.tap").exists())

    def test_required_skip_and_unexpected_failure_fail(self) -> None:
        self.macvm.write_text(
            HEADER
            + "engine.cli\tSKIP\t0\trequired\tmissing CLI\n"
            + "ports.tcp\tFAIL\t10\trequired\tconnection refused\n",
            encoding="utf-8",
        )
        self.assertEqual(self.run_report(), 1)
        summary = self.summary()
        self.assertFalse(summary["passed"])
        self.assertEqual(summary["counts"], {"FAIL": 2})

    def test_registered_failure_is_xfail_but_pass_is_xpass(self) -> None:
        self.xfails.write_text(
            "macvm\tbind.inotify\thttps://example.invalid/1\tknown limitation\n",
            encoding="utf-8",
        )
        self.macvm.write_text(
            HEADER + "bind.inotify\tFAIL\t10\trequired\tno event\n",
            encoding="utf-8",
        )
        self.assertEqual(self.run_report(), 0)
        self.assertEqual(self.summary()["counts"], {"XFAIL": 1})

        self.macvm.write_text(
            HEADER + "bind.inotify\tPASS\t10\trequired\tfixed\n",
            encoding="utf-8",
        )
        self.assertEqual(self.run_report(), 1)
        self.assertEqual(self.summary()["counts"], {"XPASS": 1})

    def test_baseline_is_reported_but_does_not_waive_macvm_failure(self) -> None:
        self.macvm.write_text(
            HEADER + "ports.tcp\tFAIL\t10\trequired\tmacvm failure\n",
            encoding="utf-8",
        )
        self.baseline.write_text(
            HEADER + "ports.tcp\tFAIL\t10\trequired\thost failure\n",
            encoding="utf-8",
        )
        self.assertEqual(self.run_report(baseline=True), 1)
        result = self.summary()["results"][0]
        self.assertEqual(result["baseline_status"], "FAIL")
        self.assertEqual(result["classification"], "FAIL")

    def test_duplicate_test_ids_are_rejected(self) -> None:
        second = self.root / "second.tsv"
        self.macvm.write_text(
            HEADER + "engine.cli\tPASS\t10\trequired\tok\n", encoding="utf-8"
        )
        second.write_text(
            HEADER + "engine.cli\tPASS\t10\trequired\tok\n", encoding="utf-8"
        )
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = MODULE.main(
                [
                    "--macvm-results",
                    str(self.macvm),
                    "--macvm-results",
                    str(second),
                    "--xfails",
                    str(self.xfails),
                    "--output-dir",
                    str(self.output),
                    "--run-id",
                    "test-run",
                    "--suite",
                    "smoke",
                ]
            )
        self.assertEqual(code, 2)

    def test_empty_macvm_results_are_rejected(self) -> None:
        self.macvm.write_text(HEADER, encoding="utf-8")
        self.assertEqual(self.run_report(), 2)


class DockerCompatibilityHarnessRegressionTests(unittest.TestCase):
    def test_guest_wrapper_supplies_homebrew_path_to_readiness_probe(self) -> None:
        source = HARNESS_PATH.read_text(encoding="utf-8")
        guest_start = source.index("guest() {")
        guest_wrapper = source[guest_start : source.index("\n}\n", guest_start)]
        readiness_start = source.index("wait_for_docker() {")
        readiness = source[
            readiness_start : source.index("\n}\n", readiness_start)
        ]
        self.assertIn("/opt/homebrew/bin:/opt/homebrew/sbin", guest_wrapper)
        self.assertIn("guest \"$name\"", readiness)
        self.assertNotIn("\"$macvm\" ssh", readiness)

    def test_swarm_create_is_detached_before_bounded_poll(self) -> None:
        source = SUITE_PATH.read_text(encoding="utf-8")
        swarm_start = source.index("test_swarm_bind() {")
        swarm_case = source[swarm_start : source.index("\n}\n", swarm_start)]
        self.assertIn("docker service create --detach=true", swarm_case)
        self.assertIn("deadline=$(( $(date +%s) + 120 ))", swarm_case)

    def test_stream_socket_uses_short_unix_socket_path(self) -> None:
        source = SUITE_PATH.read_text(encoding="utf-8")
        socket_start = source.index("test_stream_socket() {")
        socket_case = source[socket_start : source.index("\n}\n", socket_start)]
        self.assertIn("mktemp -d /private/tmp/mvm-dc.XXXXXX", socket_case)
        self.assertNotIn("socket_path=\"$CASE_DIR", socket_case)

    def test_background_fixtures_are_recorded_for_exit_cleanup(self) -> None:
        source = SUITE_PATH.read_text(encoding="utf-8")
        self.assertIn('stop_recorded_process "$WORK_ROOT/http-server-pid"', source)
        self.assertIn('stop_recorded_process "$WORK_ROOT/stream-server-pid"', source)
        self.assertIn('>"$WORK_ROOT/http-server-pid"', source)
        self.assertIn('>"$WORK_ROOT/stream-server-pid"', source)

    def test_wait_diff_commit_case_is_required(self) -> None:
        source = SUITE_PATH.read_text(encoding="utf-8")
        start = source.index("test_container_wait_diff_commit() {")
        case = source[start : source.index("\n}\n", start)]
        self.assertIn("docker image inspect", case)
        self.assertNotIn("docker history", case)
        self.assertIn(
            "run_case container.wait-diff-commit required test_container_wait_diff_commit",
            source,
        )

    def test_apfs_detach_retries_without_hiding_a_leaked_mount(self) -> None:
        source = SUITE_PATH.read_text(encoding="utf-8")
        self.assertIn("detach_apfs_device() {", source)
        self.assertIn('while [ "$attempt" -le 10 ]; do', source)
        start = source.index("test_bind_apfs_volume() {")
        case = source[start : source.index("\n}\n", start)]
        self.assertIn('if detach_apfs_device "$device"; then', case)
        self.assertIn('rm -f "$WORK_ROOT/apfs-device"', case)

    def test_local_registry_build_loads_the_source_image(self) -> None:
        source = SUITE_PATH.read_text(encoding="utf-8")
        start = source.index("test_local_registry() {")
        case = source[start : source.index("\n}\n", start)]
        self.assertIn("docker buildx build --load", case)
        self.assertNotIn("docker build -q", case)

    def test_degraded_recovery_restores_homebrew_from_exit_trap(self) -> None:
        source = HARNESS_PATH.read_text(encoding="utf-8")
        self.assertIn("restore_secondary_homebrew() {", source)
        restore_start = source.index("restore_secondary_homebrew() {")
        restore = source[restore_start : source.index("\n}\n", restore_start)]
        self.assertIn("/bin/sync", restore)
        start = source.index("lifecycle_degraded_recovery() {")
        case = source[start : source.index("\n}\n", start)]
        self.assertIn("trap finish_degraded_recovery EXIT", case)
        self.assertIn("restore_secondary_homebrew", case)


if __name__ == "__main__":
    unittest.main()
