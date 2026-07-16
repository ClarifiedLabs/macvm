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
    require_contains(project, "dstPath = Contents/Helpers;", "project.pbxproj")
    require_contains(project, "CodeSignOnCopy", "project.pbxproj")
    require_contains(project, 'name = "MacVM CLI";', "project.pbxproj")
    require_contains(
        package_script,
        'EMBEDDED_CLI_PRODUCT="$APP_PRODUCT/Contents/Helpers/$CLI_NAME"',
        "package-release.sh",
    )
    require_contains(
        package_script,
        'ln -s "../../../Applications/$APP_NAME.app/Contents/Helpers/$CLI_NAME" "$CLI_LINK_PATH"',
        "package-release.sh",
    )
    if 'ditto --norsrc --noextattr "$CLI_PRODUCT"' in package_script:
        raise AssertionError("package-release.sh must not stage a standalone CLI product")
    if 'PAYLOAD_ROOT/usr/local/bin/$RESOURCE_BUNDLE_NAME' in package_script:
        raise AssertionError("package-release.sh must not stage a loose resource bundle")

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
