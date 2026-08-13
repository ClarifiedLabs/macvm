#!/usr/bin/env python3
"""Behavioral and structural checks for GitHub Actions release wiring."""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import tempfile

from _checks import REPO_ROOT, read, require_absent, require_contains, require_count


def extract_run_step(workflow: str, name: str) -> str:
    lines = workflow.splitlines()
    marker = f"- name: {name}"
    for index, line in enumerate(lines):
        if line.strip() != marker:
            continue
        for run_index in range(index + 1, len(lines)):
            if lines[run_index].strip() == "run: |":
                indent = len(lines[run_index]) - len(lines[run_index].lstrip())
                body: list[str] = []
                for body_line in lines[run_index + 1 :]:
                    body_indent = len(body_line) - len(body_line.lstrip())
                    if body_line.strip() and body_indent <= indent:
                        break
                    body.append(body_line[indent + 2 :] if body_line else "")
                return "\n".join(body) + "\n"
            if lines[run_index].strip().startswith("- name:"):
                break
    raise AssertionError(f"workflow step not found: {name}")


def assert_mode_resolution(workflow: str) -> None:
    script = extract_run_step(workflow, "Resolve E2E mode")
    scenarios = (
        ("push", "refs/heads/main", "", "smoke", "docker-e2e"),
        ("push", "refs/tags/v1.2.3", "", "smoke", "docker-e2e"),
        ("push", "refs/heads/release-ci", "", "full", "release-ci"),
        ("schedule", "refs/heads/main", "", "full", "docker-e2e"),
        ("workflow_dispatch", "refs/heads/main", "", "smoke", "docker-e2e"),
        ("workflow_dispatch", "refs/heads/main", "full", "full", "docker-e2e"),
        ("workflow_dispatch", "refs/heads/release-ci", "smoke", "smoke", "release-ci"),
    )
    with tempfile.TemporaryDirectory(prefix="macvm-workflow-test-") as directory:
        for event, ref, requested, expected_suite, expected_environment in scenarios:
            output = pathlib.Path(directory) / "output"
            environment = os.environ.copy()
            environment.update(
                {
                    "GITHUB_EVENT_NAME": event,
                    "GITHUB_REF": ref,
                    "GITHUB_OUTPUT": str(output),
                    "INPUT_SUITE": requested,
                }
            )
            subprocess.run(["bash", "-c", script], env=environment, check=True)
            values = dict(
                line.split("=", 1)
                for line in output.read_text(encoding="utf-8").splitlines()
            )
            assert values == {
                "environment": expected_environment,
                "suite": expected_suite,
            }, (event, ref, requested, values)
            output.unlink()

        output = pathlib.Path(directory) / "invalid-output"
        environment = os.environ.copy()
        environment.update(
            {
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_OUTPUT": str(output),
                "INPUT_SUITE": "destructive",
            }
        )
        result = subprocess.run(
            ["bash", "-c", script], env=environment, capture_output=True, text=True
        )
        if result.returncode == 0 or "must be smoke or full" not in result.stderr:
            raise AssertionError("manual Docker E2E mode accepted an invalid suite")


def main() -> None:
    test_workflow = read(REPO_ROOT / ".github/workflows/test.yml")
    docker_workflow = read(REPO_ROOT / ".github/workflows/docker-e2e.yml")
    actionlint_config = read(REPO_ROOT / ".github/actionlint.yaml")
    release_workflow = read(REPO_ROOT / ".github/workflows/release.yml")
    makefile = read(REPO_ROOT / "Makefile")
    manager_scheme = read(
        REPO_ROOT / "macvm.xcodeproj/xcshareddata/xcschemes/MacVM App.xcscheme"
    )

    for needle in (
        "name: test",
        "- main",
        "- release-ci",
        "pull_request:",
        "workflow_dispatch:",
        "runs-on: macos-26",
        "PROJECT: macvm.xcodeproj",
        "SCHEME: MacVM App",
        "make test",
        "XCODE_RESULT_BUNDLE_PATH: .build/ci/xcresults/MacVMTests.xcresult",
        "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd",
        "actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae",
        "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
    ):
        require_contains(test_workflow, needle, "test.yml")

    for needle in (
        "name: docker-e2e",
        "schedule:",
        'cron: "17 9 * * *"',
        "Authorize trusted revision",
        "CANONICAL_REPOSITORY: ClarifiedLabs/macvm",
        "git merge-base --is-ancestor \"$sha\" origin/main",
        "group: docker-e2e-seed-${{ vars.MACVM_DOCKER_E2E_SEED || 'unconfigured' }}",
        "cancel-in-progress: false",
        "environment: ${{ needs.authorize.outputs.environment }}",
        "Create disposable exact-SHA checkout",
        "git -C \"$MACVM_E2E_CHECKOUT\" checkout --detach FETCH_HEAD",
        "MACVM_DOCKER_E2E_KEEP_VM: \"0\"",
        "Snapshot immutable seed",
        "Verify seed remained immutable",
        "if: always()",
        "Collect runner and clone diagnostics",
        "Upload Docker compatibility diagnostics",
        "Remove disposable clones and checkout",
        "make test-docker-e2e",
        "- self-hosted",
        "- macOS",
        "- ARM64",
        "- macvm-docker-e2e",
        "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd",
        "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
    ):
        require_contains(docker_workflow, needle, "docker-e2e.yml")
    require_absent(docker_workflow, "pull_request", "docker-e2e.yml")
    require_count(docker_workflow, "- self-hosted", 1, "docker-e2e.yml")
    require_count(docker_workflow, "uses: actions/checkout@", 1, "docker-e2e.yml")
    require_contains(actionlint_config, "- macvm-docker-e2e", "actionlint.yaml")
    assert_mode_resolution(docker_workflow)

    for needle in (
        "name: release",
        "- release-ci",
        "v*.*.*",
        "require-tests:",
        "name: Require macOS tests",
        "actions: write",
        "TEST_WORKFLOW_FILE: test.yml",
        "TEST_TIMEOUT_SECONDS: 7200",
        "head_sha",
        "/dispatches",
        "Required test workflow passed",
        "require-docker-e2e:",
        "name: Require exact-SHA Docker E2E",
        "actions: read",
        "DOCKER_E2E_WORKFLOW_FILE: docker-e2e.yml",
        'release_ref = os.environ["RELEASE_REF"]',
        'release_sha = os.environ["RELEASE_SHA"]',
        'expected_suite = "full" if release_ref == "refs/heads/release-ci" else "smoke"',
        'if run.get("head_sha") == release_sha',
        'and run.get("event") == "push"',
        'run.get("head_branch") == expected_branch',
        'actions/runs/{run_id}/jobs?per_page=100',
        'expected_name = f"Docker real-guest E2E ({expected_suite})"',
        "suite_runs = [run for run in runs if has_expected_suite(run)]",
        "Required exact-SHA Docker E2E passed",
        "the trusted workflow must run independently",
        "- require-tests",
        "- require-docker-e2e",
        "Verify release commit is on main",
        "runs-on: macos-26",
        "APP_STORE_CONNECT_KEY_ID",
        "APP_STORE_CONNECT_ISSUER_ID",
        "APP_STORE_CONNECT_PRIVATE_KEY",
        "DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64",
        "DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64",
        "MACVM_SIGN_RELEASE=1",
        "MACVM_NOTARIZE=1",
        "./scripts/package-release.sh",
        "Verify signed release artifacts",
        "make verify-package",
        "VERIFY_MODE=signed",
        "MacVM-${{ steps.version.outputs.version }}.pkg",
        "MacVM-${{ steps.version.outputs.version }}.dmg",
        "gh release create",
        '"$package_path" "$disk_image_path"',
        "if: startsWith(github.ref, 'refs/tags/v')",
        "DMG_SHA256=",
    ):
        require_contains(release_workflow, needle, "release.yml")

    for needle in (
        "VERSION ?=",
        "AUTOPUSH ?= 0",
        "RELEASE ?= ./tools/release.py",
        "release-list:",
        "release:",
        "VERSION is required",
        "test-release:",
        "tools/tests/test-release.py",
        "tools/tests/test-workflows.py",
        "all: dist",
        "dist: dist-cli dist-app",
        "./scripts/stage-cli.sh",
        "./scripts/stage-app.sh",
        "verify-package:",
        "VERIFY_MODE ?= unsigned",
        "./scripts/verify-release-artifacts.sh",
    ):
        require_contains(makefile, needle, "Makefile")

    require_absent(makefile, "dev-app", "Makefile")
    require_count(manager_scheme, 'parallelizable = "NO"', 2, "MacVM App.xcscheme")
    require_absent(manager_scheme, 'parallelizable = "YES"', "MacVM App.xcscheme")

    action_references = re.findall(
        r"^\s*uses:\s*([^\s]+)",
        "\n".join((test_workflow, docker_workflow, release_workflow)),
        flags=re.MULTILINE,
    )
    if not action_references:
        raise AssertionError("workflows must contain pinned action references")
    for reference in action_references:
        if not re.fullmatch(r"[^@]+@[0-9a-f]{40}", reference):
            raise AssertionError(f"action reference must use an exact commit SHA: {reference}")

    for forbidden in (
        "draft: true",
        "make release       Run tests and build",
        "upload_to_testflight",
        "TestFlight",
        "app-store-connect",
    ):
        require_absent(release_workflow, forbidden, "release.yml")


if __name__ == "__main__":
    main()
