#!/usr/bin/env python3
"""Regression checks for installer package construction."""

from __future__ import annotations

import plistlib

from _checks import REPO_ROOT, read, require_contains


def main() -> None:
    package_script = read(REPO_ROOT / "scripts/package-release.sh")
    project = read(REPO_ROOT / "macvm.xcodeproj/project.pbxproj")
    component_plist_path = REPO_ROOT / "Support/macvm-component.plist"

    require_contains(
        package_script,
        '--component-plist "$COMPONENT_PLIST_PATH"',
        "package-release.sh",
    )
    require_contains(package_script, 'APP_SCHEME="MacVM App"', "package-release.sh")
    require_contains(package_script, 'APP_NAME="MacVM"', "package-release.sh")
    require_contains(project, "PRODUCT_MODULE_NAME = MacVM;", "project.pbxproj")
    require_contains(project, "PRODUCT_NAME = MacVM;", "project.pbxproj")

    with component_plist_path.open("rb") as component_plist_file:
        components = plistlib.load(component_plist_file)

    app_component = next(
        component
        for component in components
        if component.get("RootRelativeBundlePath")
        == "Applications/MacVM.app"
    )
    if app_component.get("BundleIsRelocatable") is not False:
        raise AssertionError(
            "MacVM.app must not be relocated away from /Applications"
        )


if __name__ == "__main__":
    main()
