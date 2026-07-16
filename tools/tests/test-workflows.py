#!/usr/bin/env python3
"""Regression checks for GitHub Actions release wiring."""

from __future__ import annotations

from _checks import REPO_ROOT, read, require_absent, require_contains, require_count


def main() -> None:
    test_workflow = read(REPO_ROOT / ".github/workflows/test.yml")
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
        "name: release",
        "- release-ci",
        "v*.*.*",
        "require-tests:",
        "name: Require macOS tests",
        "runs-on: ubuntu-24.04",
        "actions: write",
        "TEST_WORKFLOW_FILE: test.yml",
        "TEST_TIMEOUT_SECONDS: 7200",
        "TEST_DISPATCH_GRACE_SECONDS: 120",
        "head_sha",
        "/dispatches",
        "Required test workflow passed",
        "needs: require-tests",
        "Verify release commit is on main",
        "runs-on: macos-26",
        "BUNDLE_IDENTIFIER: dev.macvm.macvm",
        "APP_STORE_CONNECT_KEY_ID",
        "APP_STORE_CONNECT_ISSUER_ID",
        "APP_STORE_CONNECT_PRIVATE_KEY",
        "DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64",
        "DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64",
        "security find-identity -v -p basic \"$keychain_path\"",
        "developer_id_application=\"$(find_identity \"Developer ID Application\")\"",
        "developer_id_installer=\"$(find_identity \"Developer ID Installer\")\"",
        "MACVM_SIGN_RELEASE=1",
        "MACVM_NOTARIZE=1",
        "./scripts/package-release.sh",
        "MacVM-${{ steps.version.outputs.version }}.pkg",
        "MacVM-${{ steps.version.outputs.version }}.dmg",
        "gh release create",
        '"$package_path" "$disk_image_path"',
        "if: startsWith(github.ref, 'refs/tags/v')",
        "Upload installer package artifact",
        "Upload Homebrew disk image artifact",
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
        "dist-cli:",
        "dist-app:",
        "./scripts/stage-cli.sh",
        "./scripts/stage-app.sh",
    ):
        require_contains(makefile, needle, "Makefile")

    require_absent(makefile, "dev-app", "Makefile")
    require_count(
        manager_scheme,
        'parallelizable = "NO"',
        2,
        "MacVM App.xcscheme",
    )
    require_absent(
        manager_scheme,
        'parallelizable = "YES"',
        "MacVM App.xcscheme",
    )

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
