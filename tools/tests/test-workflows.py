#!/usr/bin/env python3
"""Behavioral and structural checks for GitHub Actions release wiring."""

from __future__ import annotations

import re

from _checks import REPO_ROOT, read, require_absent, require_contains, require_count


def main() -> None:
    test_workflow = read(REPO_ROOT / ".github/workflows/test.yml")
    release_workflow = read(REPO_ROOT / ".github/workflows/release.yml")
    if (REPO_ROOT / ".github/workflows/docker-e2e.yml").exists():
        raise AssertionError("docker-e2e.yml must not be present")
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
        "needs: require-tests",
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

    for forbidden in ("require-docker-e2e", "docker-e2e.yml", "DOCKER_E2E"):
        require_absent(release_workflow, forbidden, "release.yml")

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
        "\n".join((test_workflow, release_workflow)),
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
