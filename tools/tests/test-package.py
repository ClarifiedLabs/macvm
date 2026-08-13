#!/usr/bin/env python3
"""Behavioral regression checks for release artifact construction."""

from __future__ import annotations

import os
import pathlib
import plistlib
import shutil
import stat
import subprocess
import tempfile
import textwrap

from _checks import REPO_ROOT, read, require_absent, require_contains


PROFILES = (
    "android-sdk",
    "android-studio",
    "apple-development",
    "claude-code",
    "codex",
    "github-runner",
    "go",
    "homebrew",
    "ios-simulator",
    "python",
    "rust",
    "typescript",
)


def write_executable(path: pathlib.Path, contents: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def make_app(path: pathlib.Path, version: str) -> None:
    resources = path / "Contents/Resources/macvm_MacVMHostKit.bundle/Resources"
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Helpers").mkdir(parents=True)
    (path / "Contents/Resources").mkdir(parents=True, exist_ok=True)
    write_executable(path / "Contents/MacOS/MacVM", "#!/bin/sh\nexit 0\n")
    profile_lines = "\\n".join(f"{profile}\\tFixture" for profile in PROFILES)
    write_executable(
        path / "Contents/Helpers/macvm",
        textwrap.dedent(
            f"""\
            #!/bin/sh
            if [ "$1" = --version ]; then printf '%s\\n' {version}; exit 0; fi
            if [ "$1" = profiles ]; then printf '%b\\n' '{profile_lines}'; exit 0; fi
            exit 2
            """
        ),
    )
    (path / "Contents/Resources/Assets.car").write_bytes(b"assets")
    (path / "Contents/PkgInfo").write_bytes(b"APPL????")
    signature = path / "Contents/_CodeSignature"
    signature.mkdir()
    (signature / "CodeResources").write_bytes(b"fixture signature manifest")
    for relative in (
        "AppIcon.icns",
        "Bootstrap/bootstrap-tools.sh",
        "Provisioning/Profiles/.placeholder",
    ):
        destination = resources / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(relative, encoding="utf-8")
    (resources / "Provisioning/Profiles/.placeholder").unlink()
    for profile in PROFILES:
        directory = resources / "Provisioning/Profiles" / profile
        directory.mkdir(parents=True)
        (directory / "playbook.yml").write_text("---\n", encoding="utf-8")
        (directory / "profile.json").write_text("{}\n", encoding="utf-8")
    write_executable(resources / "Docker/macvm-docker-guest", "#!/bin/sh\nexit 0\n")
    write_executable(resources / "Clipboard/macvm-clipboard-guest", "#!/bin/sh\nexit 0\n")
    with (path / "Contents/Info.plist").open("wb") as output:
        plistlib.dump(
            {
                "CFBundleExecutable": "MacVM",
                "CFBundleIdentifier": "dev.macvm.macvm",
                "CFBundleShortVersionString": version,
            },
            output,
        )


def make_fixture(root: pathlib.Path, version: str) -> tuple[pathlib.Path, pathlib.Path]:
    app = root / "source/MacVM.app"
    make_app(app, version)
    dmg_root = root / "dmg-root"
    dmg_root.mkdir()
    shutil.copytree(app, dmg_root / "MacVM.app", symlinks=True, copy_function=shutil.copy2)
    (dmg_root / "Applications").symlink_to("/Applications")

    expanded = root / "pkg-expanded"
    component = expanded / "MacVM-component.pkg"
    payload = component / "Payload"
    shutil.copytree(app, payload / "Applications/MacVM.app", symlinks=True, copy_function=shutil.copy2)
    link = payload / "usr/local/bin/macvm"
    link.parent.mkdir(parents=True)
    link.symlink_to("../../../Applications/MacVM.app/Contents/Helpers/macvm")
    (component / "Bom").write_bytes(b"bom")
    (component / "PackageInfo").write_text(
        f'''<?xml version="1.0"?>
<pkg-info auth="root" identifier="dev.macvm.macvm.pkg" install-location="/" postinstall-action="none" relocatable="false" version="{version}">
  <payload numberOfFiles="1" installKBytes="1"/>
  <bundle path="./Applications/MacVM.app" id="dev.macvm.macvm" CFBundleShortVersionString="{version}" CFBundleVersion="1"/>
</pkg-info>\n''',
        encoding="utf-8",
    )
    (expanded / "Distribution").write_text(
        f'''<?xml version="1.0"?>
<installer-gui-script minSpecVersion="1">
  <options require-scripts="false" hostArchitectures="arm64"/>
  <pkg-ref id="dev.macvm.macvm.pkg"><bundle-version><bundle id="dev.macvm.macvm" path="Applications/MacVM.app"/></bundle-version></pkg-ref>
  <choice id="dev.macvm.macvm.pkg"><pkg-ref id="dev.macvm.macvm.pkg"/></choice>
  <pkg-ref id="dev.macvm.macvm.pkg" version="{version}">#MacVM-component.pkg</pkg-ref>
</installer-gui-script>\n''',
        encoding="utf-8",
    )
    dmg = root / f"MacVM-{version}.dmg"
    pkg = root / f"MacVM-{version}.pkg"
    dmg.write_bytes(b"fixture dmg")
    pkg.write_bytes(b"fixture pkg")
    return dmg, pkg


def make_fake_tools(root: pathlib.Path) -> pathlib.Path:
    directory = root / "bin"
    directory.mkdir()
    dispatcher = directory / "tool"
    dispatcher.write_text(
        textwrap.dedent(
            r'''#!/usr/bin/env python3
import os
import pathlib
import plistlib
import shutil
import sys

tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
log = pathlib.Path(os.environ["FAKE_TOOL_LOG"])
with log.open("a", encoding="utf-8") as output:
    output.write(tool + " " + " ".join(args) + "\n")

if tool == "hdiutil":
    state = pathlib.Path(os.environ["FAKE_HDI_STATE"])
    if args[:2] == ["info", "-plist"]:
        images = []
        if state.exists():
            images.append({
                "image-path": os.environ["FAKE_DMG_PATH"],
                "system-entities": [
                    {"dev-entry": "/dev/fake0"},
                    {"dev-entry": "/dev/fake0s1"},
                    {"dev-entry": "/dev/fake1", "mount-point": os.environ["FAKE_MOUNT_POINT"]},
                ],
            })
        plistlib.dump({"images": images}, sys.stdout.buffer)
        raise SystemExit(0)
    if args[0] == "verify":
        raise SystemExit(0)
    if args[0] == "attach":
        mount = pathlib.Path(args[args.index("-mountpoint") + 1])
        os.environ["FAKE_MOUNT_POINT"] = str(mount)
        pathlib.Path(os.environ["FAKE_MOUNT_FILE"]).write_text(str(mount))
        for source in pathlib.Path(os.environ["FAKE_DMG_ROOT"]).iterdir():
            destination = mount / source.name
            if source.is_symlink(): destination.symlink_to(os.readlink(source))
            elif source.is_dir(): shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)
            else: shutil.copy2(source, destination)
        state.write_text("attached")
        if os.environ.get("FAKE_MALFORMED_ATTACH") == "1":
            sys.stdout.write("not a plist")
        else:
            plistlib.dump({"system-entities": [
                {"dev-entry": "/dev/fake0"},
                {"dev-entry": "/dev/fake0s1"},
                {"dev-entry": "/dev/fake1", "mount-point": str(mount)},
            ]}, sys.stdout.buffer)
        raise SystemExit(0)
    if args[0] == "detach":
        raise SystemExit(0)
if tool == "pkgutil":
    if args[0] == "--expand-full":
        shutil.copytree(os.environ["FAKE_PKG_ROOT"], args[2], symlinks=True, copy_function=shutil.copy2)
        raise SystemExit(0)
    if args[0] == "--check-signature":
        if os.environ.get("FAKE_SIGNED") == "1":
            print("Developer ID Installer: Fixture Release (FIXTURE123)")
            raise SystemExit(0)
        raise SystemExit(1)
if tool == "plutil":
    key = args[args.index("-extract") + 1]
    path = pathlib.Path(args[-1])
    with path.open("rb") as source: value = plistlib.load(source)[key]
    print(str(value).lower() if isinstance(value, bool) else value)
    raise SystemExit(0)
if tool == "lipo":
    raise SystemExit(0)
if tool == "codesign":
    item = pathlib.Path(args[-1])
    if "--verify" in args:
        raise SystemExit(0)
    if "--entitlements" in args:
        entitlements = (
            {"com.apple.security.virtualization": True}
            if item.name in {"MacVM.app", "macvm"}
            else {}
        )
        plistlib.dump(entitlements, sys.stdout.buffer)
        raise SystemExit(0)
    if "--display" in args:
        identifiers = {
            "MacVM.app": "dev.macvm.macvm",
            "macvm": "dev.macvm.macvm.cli",
            "macvm-docker-guest": "dev.macvm.macvm.docker-guest",
            "macvm-clipboard-guest": "dev.macvm.clipboard-guest",
        }
        identifier = "dev.macvm.macvm.dmg" if item.suffix == ".dmg" else identifiers[item.name]
        print(f"Identifier={identifier}", file=sys.stderr)
        print("CodeDirectory v=20500 flags=0x10000(runtime)", file=sys.stderr)
        if os.environ.get("FAKE_SIGNED") == "1":
            print("TeamIdentifier=FIXTURE123", file=sys.stderr)
            print("Authority=Developer ID Application: Fixture Release (FIXTURE123)", file=sys.stderr)
        raise SystemExit(0)
if tool in {"spctl", "xcrun"}:
    raise SystemExit(0)
raise SystemExit(f"unsupported fake invocation: {tool} {args}")
'''
        ),
        encoding="utf-8",
    )
    dispatcher.chmod(0o755)
    for tool in ("codesign", "hdiutil", "lipo", "pkgutil", "plutil", "spctl", "xcrun"):
        (directory / tool).symlink_to(dispatcher.name)
    return directory


def run_verifier(
    root: pathlib.Path,
    dmg: pathlib.Path,
    pkg: pathlib.Path,
    *,
    mode: str = "unsigned",
    malformed_attach: bool = False,
) -> subprocess.CompletedProcess[str]:
    fake_bin = make_fake_tools(root)
    log = root / "tools.log"
    mount_file = root / "mount.txt"
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{fake_bin}:{environment['PATH']}",
            "FAKE_DMG_PATH": str(dmg.resolve()),
            "FAKE_DMG_ROOT": str(root / "dmg-root"),
            "FAKE_HDI_STATE": str(root / "hdi-state"),
            "FAKE_MOUNT_FILE": str(mount_file),
            "FAKE_MOUNT_POINT": str(root / "unused-mount"),
            "FAKE_PKG_ROOT": str(root / "pkg-expanded"),
            "FAKE_TOOL_LOG": str(log),
            "FAKE_MALFORMED_ATTACH": "1" if malformed_attach else "0",
            "FAKE_SIGNED": "1" if mode == "signed" else "0",
        }
    )
    return subprocess.run(
        [
            str(REPO_ROOT / "scripts/verify-release-artifacts.sh"),
            "--mode",
            mode,
            "--version",
            "1.2.3",
            "--dmg",
            str(dmg),
            "--pkg",
            str(pkg),
        ],
        env=environment,
        capture_output=True,
        text=True,
    )


def assert_behavioral_verifier_fixtures() -> None:
    with tempfile.TemporaryDirectory(prefix="macvm-package-test-") as directory:
        root = pathlib.Path(directory)
        dmg, pkg = make_fixture(root, "1.2.3")
        result = run_verifier(root, dmg, pkg)
        if result.returncode != 0:
            raise AssertionError(f"valid fixture failed:\n{result.stdout}\n{result.stderr}")
        log = (root / "tools.log").read_text(encoding="utf-8")
        for expected in (
            f"hdiutil verify {dmg.resolve()}",
            "hdiutil detach -quiet /dev/fake1",
            "hdiutil detach -quiet /dev/fake0s1",
            "hdiutil detach -quiet /dev/fake0",
        ):
            require_contains(log, expected, "verifier tool log")

    with tempfile.TemporaryDirectory(prefix="macvm-package-test-") as directory:
        root = pathlib.Path(directory)
        dmg, pkg = make_fixture(root, "1.2.3")
        result = run_verifier(root, dmg, pkg, mode="signed")
        if result.returncode != 0:
            raise AssertionError(f"valid signed fixture failed:\n{result.stdout}\n{result.stderr}")

    with tempfile.TemporaryDirectory(prefix="macvm-package-test-") as directory:
        root = pathlib.Path(directory)
        dmg, pkg = make_fixture(root, "1.2.3")
        changed = root / "pkg-expanded/MacVM-component.pkg/Payload/Applications/MacVM.app/Contents/Resources/Assets.car"
        changed.write_bytes(b"different")
        result = run_verifier(root, dmg, pkg)
        if result.returncode == 0 or "manifests differ" not in result.stderr:
            raise AssertionError("verifier accepted different DMG and PKG app copies")

    with tempfile.TemporaryDirectory(prefix="macvm-package-test-") as directory:
        root = pathlib.Path(directory)
        dmg, pkg = make_fixture(root, "1.2.3")
        relative = pathlib.Path("Contents/Frameworks/Unexpected.framework")
        for app in (
            root / "dmg-root/MacVM.app",
            root / "pkg-expanded/MacVM-component.pkg/Payload/Applications/MacVM.app",
        ):
            unexpected = app / relative
            unexpected.mkdir(parents=True)
            (unexpected / "Unexpected").write_bytes(b"unexpected code")
        result = run_verifier(root, dmg, pkg)
        if result.returncode == 0 or "unexpected contents in Contents" not in result.stderr:
            raise AssertionError("verifier accepted identical unexpected app payloads")

    with tempfile.TemporaryDirectory(prefix="macvm-package-test-") as directory:
        root = pathlib.Path(directory)
        dmg, pkg = make_fixture(root, "1.2.3")
        (root / "dmg-root/README.txt").write_text("unexpected", encoding="utf-8")
        result = run_verifier(root, dmg, pkg)
        if result.returncode == 0 or "must contain exactly" not in result.stderr:
            raise AssertionError("verifier accepted an unexpected DMG root entry")

    with tempfile.TemporaryDirectory(prefix="macvm-package-test-") as directory:
        root = pathlib.Path(directory)
        dmg, pkg = make_fixture(root, "1.2.3")
        result = run_verifier(root, dmg, pkg, malformed_attach=True)
        if result.returncode == 0:
            raise AssertionError("verifier accepted malformed hdiutil attach output")
        log = (root / "tools.log").read_text(encoding="utf-8")
        for device in ("/dev/fake1", "/dev/fake0s1", "/dev/fake0"):
            require_contains(log, f"hdiutil detach -quiet {device}", "parser-failure cleanup")


def main() -> None:
    package_script = read(REPO_ROOT / "scripts/package-release.sh")
    verifier_script = read(REPO_ROOT / "scripts/verify-release-artifacts.sh")
    makefile = read(REPO_ROOT / "Makefile")
    project = read(REPO_ROOT / "macvm.xcodeproj/project.pbxproj")
    component_plist_path = REPO_ROOT / "Support/macvm-component.plist"

    for needle in (
        '--component-plist "$COMPONENT_PLIST_PATH"',
        'APP_SCHEME="MacVM App"',
        'APP_NAME="MacVM"',
        'DMG_IDENTIFIER="$BASE_BUNDLE_IDENTIFIER.dmg"',
        '--identifier "$DMG_IDENTIFIER"',
        'ARTIFACT_VERIFIER_PATH="$ROOT_DIR/scripts/verify-release-artifacts.sh"',
        "Signed release artifacts must be notarized",
        'notarize_item "$DMG_PATH" "MacVM disk image"',
        "spctl --assess --type open --context context:primary-signature",
        'ln -s "../../../Applications/$APP_NAME.app/Contents/Helpers/$CLI_NAME" "$CLI_LINK_PATH"',
        'lipo "$CLIPBOARD_GUEST_HELPER_PATH" -verify_arch arm64',
        '--mode "$verification_mode"',
    ):
        require_contains(package_script, needle, "package-release.sh")
    for forbidden in (
        'ditto --norsrc --noextattr "$CLI_PRODUCT"',
        "PAYLOAD_ROOT/usr/local/bin/$RESOURCE_BUNDLE_NAME",
        "DMG_ROOT/usr/local/bin",
    ):
        require_absent(package_script, forbidden, "package-release.sh")

    for needle in (
        "hdiutil verify",
        "record_image_devices",
        "DMG_ATTACH_STARTED=1",
        "assert_exact_dmg_root",
        "assert_package_layout",
        "compare_app_manifests",
        '"sha256": digest.hexdigest()',
        "assert_cli_self_check",
        "dev.macvm.macvm.docker-guest",
        "dev.macvm.clipboard-guest",
        "com.apple.security.virtualization",
        "hardened runtime",
        "xcrun stapler validate",
        "spctl --assess --type install",
    ):
        require_contains(verifier_script, needle, "verify-release-artifacts.sh")
    require_absent(verifier_script, "hdiutil mount", "verify-release-artifacts.sh")

    for needle in (
        "verify-package:",
        "VERIFY_MODE ?= unsigned",
        "PACKAGE_OUTPUT_DIR ?= dist",
        "./scripts/verify-release-artifacts.sh",
        '--mode "$(VERIFY_MODE)"',
    ):
        require_contains(makefile, needle, "Makefile")

    for needle in (
        "PRODUCT_MODULE_NAME = MacVM;",
        "PRODUCT_NAME = MacVM;",
        "dstPath = Contents/Helpers;",
        "CodeSignOnCopy",
        'name = "MacVM CLI";',
        "PRODUCT_BUNDLE_IDENTIFIER = dev.macvm.clipboard-guest;",
        'PRODUCT_NAME = "macvm-clipboard-guest";',
        "ARCHS = arm64;",
    ):
        require_contains(project, needle, "project.pbxproj")

    with component_plist_path.open("rb") as component_plist_file:
        components = plistlib.load(component_plist_file)
    app_component = next(
        component
        for component in components
        if component.get("RootRelativeBundlePath") == "Applications/MacVM.app"
    )
    if app_component.get("BundleIsRelocatable") is not False:
        raise AssertionError("MacVM.app must not be relocated away from /Applications")

    assert_behavioral_verifier_fixtures()


if __name__ == "__main__":
    main()
