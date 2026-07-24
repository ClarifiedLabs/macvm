#!/usr/bin/env python3
"""Classify Docker compatibility results and write machine-readable reports."""

from __future__ import annotations

import argparse
import csv
import json
import sys
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from pathlib import Path


EXPECTED_HEADER = ["test_id", "status", "duration_ms", "policy", "note"]
VALID_STATUSES = {"PASS", "FAIL", "SKIP"}
VALID_POLICIES = {"required", "optional"}


class ReportError(ValueError):
    pass


@dataclass(frozen=True)
class Result:
    test_id: str
    status: str
    duration_ms: int
    policy: str
    note: str
    source: str


@dataclass(frozen=True)
class ExpectedFailure:
    target: str
    test_id: str
    reference: str
    reason: str


@dataclass(frozen=True)
class ClassifiedResult:
    test_id: str
    raw_status: str
    classification: str
    policy: str
    duration_ms: int
    note: str
    source: str
    baseline_status: str | None
    baseline_note: str | None
    xfail_reference: str | None
    xfail_reason: str | None


def read_results(path: Path) -> list[Result]:
    try:
        handle = path.open(newline="", encoding="utf-8")
    except OSError as error:
        raise ReportError(f"cannot read results {path}: {error}") from error
    with handle:
        reader = csv.reader(handle, delimiter="\t")
        try:
            header = next(reader)
        except StopIteration as error:
            raise ReportError(f"{path}: empty results file") from error
        if header != EXPECTED_HEADER:
            raise ReportError(
                f"{path}: expected tab-separated header {EXPECTED_HEADER!r}, got {header!r}"
            )
        results: list[Result] = []
        for line_number, row in enumerate(reader, start=2):
            if len(row) != len(EXPECTED_HEADER):
                raise ReportError(
                    f"{path}:{line_number}: expected {len(EXPECTED_HEADER)} fields, got {len(row)}"
                )
            test_id, status, duration_text, policy, note = row
            if not test_id:
                raise ReportError(f"{path}:{line_number}: test_id cannot be empty")
            if status not in VALID_STATUSES:
                raise ReportError(f"{path}:{line_number}: invalid status {status!r}")
            if policy not in VALID_POLICIES:
                raise ReportError(f"{path}:{line_number}: invalid policy {policy!r}")
            try:
                duration_ms = int(duration_text)
            except ValueError as error:
                raise ReportError(
                    f"{path}:{line_number}: duration_ms is not an integer"
                ) from error
            if duration_ms < 0:
                raise ReportError(f"{path}:{line_number}: duration_ms cannot be negative")
            results.append(
                Result(test_id, status, duration_ms, policy, note, str(path))
            )
    return results


def read_xfails(path: Path) -> dict[tuple[str, str], ExpectedFailure]:
    registry: dict[tuple[str, str], ExpectedFailure] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ReportError(f"cannot read XFAIL registry {path}: {error}") from error
    for line_number, line in enumerate(lines, start=1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            raise ReportError(
                f"{path}:{line_number}: expected target, test_id, reference, and reason"
            )
        target, test_id, reference, reason = fields
        if target != "macvm":
            raise ReportError(
                f"{path}:{line_number}: invalid target {target!r}; only 'macvm' failures can be expected"
            )
        if not all(fields):
            raise ReportError(f"{path}:{line_number}: XFAIL fields cannot be empty")
        key = (target, test_id)
        if key in registry:
            raise ReportError(f"{path}:{line_number}: duplicate XFAIL for {target}/{test_id}")
        registry[key] = ExpectedFailure(target, test_id, reference, reason)
    return registry


def unique_results(paths: list[Path]) -> list[Result]:
    results: list[Result] = []
    seen: dict[str, str] = {}
    for path in paths:
        for result in read_results(path):
            if result.test_id in seen:
                raise ReportError(
                    f"duplicate MacVM test_id {result.test_id!r} in "
                    f"{seen[result.test_id]} and {path}"
                )
            seen[result.test_id] = str(path)
            results.append(result)
    if not results:
        raise ReportError("MacVM results contain no tests")
    return results


def classify(
    macvm: list[Result],
    baseline: list[Result],
    xfails: dict[tuple[str, str], ExpectedFailure],
) -> tuple[list[ClassifiedResult], list[str]]:
    baseline_by_id = {result.test_id: result for result in baseline}
    if len(baseline_by_id) != len(baseline):
        raise ReportError("baseline results contain duplicate test IDs")
    classified: list[ClassifiedResult] = []
    failures: list[str] = []
    for result in macvm:
        expected = xfails.get(("macvm", result.test_id))
        if expected and result.status == "FAIL":
            classification = "XFAIL"
        elif expected and result.status == "PASS":
            classification = "XPASS"
            failures.append(
                f"{result.test_id}: XPASS; remove or update {expected.reference}"
            )
        elif result.status == "FAIL":
            classification = "FAIL"
            failures.append(f"{result.test_id}: unexpected failure: {result.note}")
        elif result.status == "SKIP" and result.policy == "required":
            classification = "FAIL"
            failures.append(f"{result.test_id}: required test was skipped: {result.note}")
        else:
            classification = result.status

        baseline_result = baseline_by_id.get(result.test_id)
        classified.append(
            ClassifiedResult(
                test_id=result.test_id,
                raw_status=result.status,
                classification=classification,
                policy=result.policy,
                duration_ms=result.duration_ms,
                note=result.note,
                source=result.source,
                baseline_status=baseline_result.status if baseline_result else None,
                baseline_note=baseline_result.note if baseline_result else None,
                xfail_reference=expected.reference if expected else None,
                xfail_reason=expected.reason if expected else None,
            )
        )

    return classified, failures


def write_tap(path: Path, results: list[ClassifiedResult]) -> None:
    lines = ["TAP version 13", f"1..{len(results)}"]
    for index, result in enumerate(results, start=1):
        if result.classification in {"PASS", "SKIP", "XFAIL"}:
            directive = ""
            if result.classification == "SKIP":
                directive = f" # SKIP {result.note}"
            elif result.classification == "XFAIL":
                directive = (
                    f" # TODO {result.xfail_reference}: {result.xfail_reason}"
                )
            lines.append(f"ok {index} - {result.test_id}{directive}")
        else:
            lines.append(f"not ok {index} - {result.test_id}")
            lines.append("  ---")
            lines.append(f"  classification: {json.dumps(result.classification)}")
            lines.append(f"  message: {json.dumps(result.note)}")
            lines.append("  ...")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_junit(path: Path, results: list[ClassifiedResult]) -> None:
    failure_ids = {
        result.test_id
        for result in results
        if result.classification in {"FAIL", "XPASS"}
    }
    suite = ET.Element(
        "testsuite",
        {
            "name": "docker-compatibility",
            "tests": str(len(results)),
            "failures": str(len(failure_ids)),
            "skipped": str(
                sum(
                    result.classification in {"SKIP", "XFAIL"}
                    for result in results
                )
            ),
            "time": f"{sum(result.duration_ms for result in results) / 1000:.3f}",
        },
    )
    for result in results:
        case = ET.SubElement(
            suite,
            "testcase",
            {
                "classname": "docker.compatibility",
                "name": result.test_id,
                "time": f"{result.duration_ms / 1000:.3f}",
            },
        )
        if result.classification in {"FAIL", "XPASS"}:
            failure = ET.SubElement(
                case, "failure", {"type": result.classification}
            )
            failure.text = result.note or result.classification
        elif result.classification in {"SKIP", "XFAIL"}:
            skipped = ET.SubElement(
                case, "skipped", {"type": result.classification}
            )
            skipped.text = (
                result.xfail_reason
                if result.classification == "XFAIL"
                else result.note
            )
        output = ET.SubElement(case, "system-out")
        output.text = json.dumps(asdict(result), sort_keys=True)
    ET.indent(suite)
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def write_comparison(path: Path, results: list[ClassifiedResult]) -> None:
    lines = [
        "# Docker compatibility comparison",
        "",
        "| Contract | MacVM | Baseline | Policy |",
        "| --- | --- | --- | --- |",
    ]
    for result in results:
        baseline = result.baseline_status or "not run"
        lines.append(
            f"| `{result.test_id}` | {result.classification} | {baseline} | {result.policy} |"
        )
    lines.append("")
    lines.append(
        "The baseline is diagnostic: it identifies host-specific limitations but "
        "does not waive MacVM contract failures."
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--macvm-results",
        action="append",
        type=Path,
        required=True,
        help="MacVM TSV result file; may be supplied more than once",
    )
    parser.add_argument("--baseline-results", type=Path)
    parser.add_argument("--xfails", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--suite", choices=("smoke", "full"), required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        macvm = unique_results(args.macvm_results)
        baseline = (
            read_results(args.baseline_results) if args.baseline_results else []
        )
        xfails = read_xfails(args.xfails)
        results, failures = classify(macvm, baseline, xfails)
    except ReportError as error:
        print(f"docker compatibility report error: {error}", file=sys.stderr)
        return 2

    args.output_dir.mkdir(parents=True, exist_ok=True)
    counts: dict[str, int] = {}
    for result in results:
        counts[result.classification] = counts.get(result.classification, 0) + 1
    summary = {
        "schema_version": 1,
        "run_id": args.run_id,
        "suite": args.suite,
        "passed": not failures,
        "counts": counts,
        "failures": failures,
        "results": [asdict(result) for result in results],
    }
    (args.output_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    write_tap(args.output_dir / "results.tap", results)
    write_junit(args.output_dir / "junit.xml", results)
    write_comparison(args.output_dir / "comparison.md", results)

    print(
        "Docker compatibility: "
        + ", ".join(f"{name}={count}" for name, count in sorted(counts.items()))
    )
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
