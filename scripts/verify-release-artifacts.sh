#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: verify-release-artifacts.sh --mode unsigned|signed --version X.Y.Z \
    --dmg PATH --pkg PATH

Verifies the exact MacVM disk-image and installer-package layouts. Signed mode
requires consistent Developer ID identities, hardened runtime, exact
entitlements, and successful notarization/stapling assessments.
EOF
}

fail() {
    echo "Release artifact verification failed: $*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

MODE=
VERSION=
DMG_PATH=
PKG_PATH=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) MODE=${2:-}; shift 2 ;;
        --version) VERSION=${2:-}; shift 2 ;;
        --dmg) DMG_PATH=${2:-}; shift 2 ;;
        --pkg) PKG_PATH=${2:-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$MODE" in
    unsigned|signed) ;;
    *) echo "--mode must be unsigned or signed" >&2; usage >&2; exit 2 ;;
esac
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "--version must be a three-part numeric version"
fi
[ -f "$DMG_PATH" ] || fail "disk image not found: $DMG_PATH"
[ -f "$PKG_PATH" ] || fail "installer package not found: $PKG_PATH"
DMG_PATH=$(cd "$(dirname "$DMG_PATH")" && pwd -P)/$(basename "$DMG_PATH")
PKG_PATH=$(cd "$(dirname "$PKG_PATH")" && pwd -P)/$(basename "$PKG_PATH")

for tool in codesign hdiutil lipo pkgutil plutil python3; do
    require_tool "$tool"
done
if [ "$MODE" = signed ]; then
    require_tool spctl
    require_tool xcrun
fi

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/macvm-release-verify.XXXXXX")
DMG_MOUNT_POINT="$TEMP_ROOT/dmg"
DMG_ATTACH_STARTED=0
mkdir -p "$DMG_MOUNT_POINT"

record_image_devices() {
    destination=$1
    info_plist="$TEMP_ROOT/hdiutil-info-$RANDOM.plist"
    hdiutil info -plist > "$info_plist" || return 1
    python3 - "$info_plist" "$DMG_PATH" > "$destination" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    value = plistlib.load(source)
image_path = os.path.realpath(sys.argv[2])
for image in value.get("images", []):
    candidate = image.get("image-path")
    if not candidate or os.path.realpath(candidate) != image_path:
        continue
    for entity in reversed(image.get("system-entities", [])):
        device = entity.get("dev-entry")
        if device:
            print(device)
PY
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ "$DMG_ATTACH_STARTED" = 1 ]; then
        cleanup_devices="$TEMP_ROOT/cleanup-devices.txt"
        if record_image_devices "$cleanup_devices"; then
            while IFS= read -r device; do
                [ -n "$device" ] || continue
                hdiutil detach -quiet "$device" >/dev/null 2>&1 \
                    || hdiutil detach -quiet -force "$device" >/dev/null 2>&1 \
                    || true
            done < "$cleanup_devices"
        fi
        hdiutil detach -quiet "$DMG_MOUNT_POINT" >/dev/null 2>&1 \
            || hdiutil detach -quiet -force "$DMG_MOUNT_POINT" >/dev/null 2>&1 \
            || true
    fi
    rm -rf "$TEMP_ROOT"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

plist_value() {
    plist=$1
    key=$2
    plutil -extract "$key" raw -o - "$plist"
}

assert_code_identifier() {
    item=$1
    expected=$2
    label=$3
    signature="$TEMP_ROOT/code-$RANDOM.txt"
    codesign --verify --strict --verbose=2 "$item" > "$signature" 2>&1 \
        || fail "$label failed code-signature verification"
    codesign --display --verbose=4 "$item" > "$signature" 2>&1 \
        || fail "$label has no readable code signature"
    python3 - "$signature" "$expected" "$label" "$MODE" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
fields = dict(line.split("=", 1) for line in lines if "=" in line)
if fields.get("Identifier") != sys.argv[2]:
    raise SystemExit(f"{sys.argv[3]} has identifier {fields.get('Identifier')!r}, expected {sys.argv[2]!r}")
if sys.argv[4] == "unsigned" and any(
    line.startswith("Authority=Developer ID Application:") for line in lines
):
    raise SystemExit(f"{sys.argv[3]} unexpectedly has a Developer ID signature in unsigned mode")
PY
}

assert_app_structure() {
    app=$1
    label=$2
    python3 - "$app" "$label" <<'PY'
import os
import pathlib
import stat
import sys

app = pathlib.Path(sys.argv[1])
label = sys.argv[2]
profiles = {
    "android-sdk", "android-studio", "apple-development", "claude-code",
    "codex", "github-runner", "go", "homebrew", "ios-simulator",
    "python", "rust", "typescript",
}

def fail(message: str) -> None:
    raise SystemExit(f"{label} {message}")

def exact_directory(path: pathlib.Path, expected: dict[str, str]) -> None:
    if not path.is_dir() or path.is_symlink():
        fail(f"is missing directory {path.relative_to(app)}")
    actual = {}
    for entry in os.scandir(path):
        mode = os.lstat(entry.path).st_mode
        if stat.S_ISDIR(mode):
            kind = "directory"
        elif stat.S_ISREG(mode):
            kind = "file"
        elif stat.S_ISLNK(mode):
            kind = "symlink"
        else:
            kind = "other"
        actual[entry.name] = kind
    if actual != expected:
        fail(f"has unexpected contents in {path.relative_to(app)}: {actual!r}")

if not app.is_dir() or app.is_symlink():
    fail("is missing MacVM.app")
exact_directory(app, {"Contents": "directory"})
exact_directory(app / "Contents", {
    "_CodeSignature": "directory",
    "Helpers": "directory",
    "Info.plist": "file",
    "MacOS": "directory",
    "PkgInfo": "file",
    "Resources": "directory",
})
exact_directory(app / "Contents" / "_CodeSignature", {"CodeResources": "file"})
exact_directory(app / "Contents" / "MacOS", {"MacVM": "file"})
exact_directory(app / "Contents" / "Helpers", {"macvm": "file"})
exact_directory(
    app / "Contents" / "Resources",
    {"Assets.car": "file", "macvm_MacVMHostKit.bundle": "directory"},
)
resource_bundle = app / "Contents" / "Resources" / "macvm_MacVMHostKit.bundle"
exact_directory(resource_bundle, {"Resources": "directory"})
resource_root = resource_bundle / "Resources"
exact_directory(resource_root, {
    "AppIcon.icns": "file",
    "Bootstrap": "directory",
    "Clipboard": "directory",
    "Docker": "directory",
    "Provisioning": "directory",
})
exact_directory(resource_root / "Bootstrap", {"bootstrap-tools.sh": "file"})
exact_directory(resource_root / "Clipboard", {"macvm-clipboard-guest": "file"})
exact_directory(resource_root / "Docker", {"macvm-docker-guest": "file"})
exact_directory(resource_root / "Provisioning", {"Profiles": "directory"})
exact_directory(resource_root / "Provisioning" / "Profiles", {name: "directory" for name in profiles})
for profile in profiles:
    exact_directory(
        resource_root / "Provisioning" / "Profiles" / profile,
        {"playbook.yml": "file", "profile.json": "file"},
    )
PY
}

assert_app_layout() {
    app=$1
    label=$2
    info="$app/Contents/Info.plist"
    cli="$app/Contents/Helpers/macvm"
    resource_root="$app/Contents/Resources/macvm_MacVMHostKit.bundle/Resources"
    docker_helper="$resource_root/Docker/macvm-docker-guest"
    clipboard_helper="$resource_root/Clipboard/macvm-clipboard-guest"

    assert_app_structure "$app" "$label"
    [ -f "$info" ] || fail "$label app is missing Contents/Info.plist"
    [ "$(plist_value "$info" CFBundleIdentifier)" = "dev.macvm.macvm" ] \
        || fail "$label app has the wrong bundle identifier"
    [ "$(plist_value "$info" CFBundleExecutable)" = "MacVM" ] \
        || fail "$label app has the wrong executable name"
    [ "$(plist_value "$info" CFBundleShortVersionString)" = "$VERSION" ] \
        || fail "$label app has the wrong release version"

    executable="$app/Contents/MacOS/MacVM"
    for executable in "$executable" "$cli" "$docker_helper" "$clipboard_helper"; do
        [ -f "$executable" ] && [ -x "$executable" ] \
            || fail "$label is missing executable ${executable#"$app/"}"
        lipo "$executable" -verify_arch arm64 >/dev/null \
            || fail "$label executable ${executable#"$app/"} is missing arm64"
    done

    assert_code_identifier "$app" "dev.macvm.macvm" "$label MacVM.app"
    assert_code_identifier "$cli" "dev.macvm.macvm.cli" "$label embedded macvm CLI"
    assert_code_identifier "$docker_helper" "dev.macvm.macvm.docker-guest" "$label Docker guest helper"
    assert_code_identifier "$clipboard_helper" "dev.macvm.clipboard-guest" "$label clipboard guest helper"
}

assert_exact_dmg_root() {
    python3 - "$DMG_MOUNT_POINT" <<'PY'
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
actual = {}
for entry in os.scandir(root):
    mode = os.lstat(entry.path).st_mode
    if stat.S_ISDIR(mode):
        kind = "directory"
    elif stat.S_ISLNK(mode):
        kind = "symlink"
    elif stat.S_ISREG(mode):
        kind = "file"
    else:
        kind = "other"
    actual[entry.name] = kind
expected = {"Applications": "symlink", "MacVM.app": "directory"}
if actual != expected:
    raise SystemExit(f"disk image root must contain exactly MacVM.app and Applications symlink; found {actual!r}")
if os.readlink(root / "Applications") != "/Applications":
    raise SystemExit("disk image Applications symlink has the wrong target")
PY
}

assert_cli_self_check() {
    cli=$1
    cli_home="$TEMP_ROOT/cli-home"
    cli_root="$TEMP_ROOT/cli-root"
    mkdir -p "$cli_home" "$cli_root"
    cli_version=$(HOME="$cli_home" "$cli" --version) \
        || fail "embedded CLI --version self-check failed"
    [ "$cli_version" = "$VERSION" ] \
        || fail "embedded CLI reported version '$cli_version', expected '$VERSION'"
    profiles="$TEMP_ROOT/profiles.txt"
    HOME="$cli_home" "$cli" profiles list --root "$cli_root" --all > "$profiles" \
        || fail "embedded CLI bundled-resource self-check failed"
    python3 - "$profiles" <<'PY'
import pathlib
import sys

expected = {
    "android-sdk", "android-studio", "apple-development", "claude-code",
    "codex", "github-runner", "go", "homebrew", "ios-simulator",
    "python", "rust", "typescript",
}
actual = {
    line.split("\t", 1)[0]
    for line in pathlib.Path(sys.argv[1]).read_text().splitlines()
    if line.strip()
}
if actual != expected:
    raise SystemExit(f"embedded CLI resource self-check returned profiles {sorted(actual)!r}")
PY
}

compare_app_manifests() {
    python3 - "$1" "$2" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys


def manifest(root_name: str) -> dict[str, dict[str, object]]:
    root = pathlib.Path(root_name)
    result = {}
    for directory, names, files in os.walk(root, followlinks=False):
        for name in sorted(names + files):
            path = pathlib.Path(directory, name)
            relative = str(path.relative_to(root))
            metadata = path.lstat()
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISDIR(metadata.st_mode):
                entry = {"type": "directory", "mode": mode}
            elif stat.S_ISREG(metadata.st_mode):
                digest = hashlib.sha256()
                with path.open("rb") as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(chunk)
                entry = {"type": "file", "mode": mode, "sha256": digest.hexdigest()}
            elif stat.S_ISLNK(metadata.st_mode):
                entry = {"type": "symlink", "mode": mode, "target": os.readlink(path)}
            else:
                entry = {"type": "other", "mode": mode}
            result[relative] = entry
    return result

left = manifest(sys.argv[1])
right = manifest(sys.argv[2])
if left != right:
    changed = sorted(set(left) | set(right))
    changed = [path for path in changed if left.get(path) != right.get(path)]
    details = "; ".join(
        f"{path}: dmg={left.get(path)!r}, pkg={right.get(path)!r}"
        for path in changed[:10]
    )
    raise SystemExit("DMG and PKG MacVM.app manifests differ: " + details)
PY
}

assert_package_layout() {
    expanded=$1
    python3 - "$expanded" "$VERSION" <<'PY'
import os
import pathlib
import stat
import sys
import xml.etree.ElementTree as ET

root = pathlib.Path(sys.argv[1])
version = sys.argv[2]

def fail(message: str) -> None:
    raise SystemExit(message)

def exact(path: pathlib.Path, expected: dict[str, str]) -> None:
    if not path.is_dir() or path.is_symlink():
        fail(f"installer package is missing directory {path.relative_to(root)}")
    actual = {}
    for entry in os.scandir(path):
        mode = os.lstat(entry.path).st_mode
        if stat.S_ISDIR(mode): kind = "directory"
        elif stat.S_ISREG(mode): kind = "file"
        elif stat.S_ISLNK(mode): kind = "symlink"
        else: kind = "other"
        actual[entry.name] = kind
    if actual != expected:
        fail(f"installer package has unexpected contents in {path.relative_to(root)}: {actual!r}")

component = root / "MacVM-component.pkg"
exact(root, {"Distribution": "file", "MacVM-component.pkg": "directory"})
exact(component, {"Bom": "file", "PackageInfo": "file", "Payload": "directory"})
payload = component / "Payload"
exact(payload, {"Applications": "directory", "usr": "directory"})
exact(payload / "Applications", {"MacVM.app": "directory"})
exact(payload / "usr", {"local": "directory"})
exact(payload / "usr" / "local", {"bin": "directory"})
exact(payload / "usr" / "local" / "bin", {"macvm": "symlink"})
link = payload / "usr" / "local" / "bin" / "macvm"
if os.readlink(link) != "../../../Applications/MacVM.app/Contents/Helpers/macvm":
    fail("installer package CLI symlink has the wrong target")

package = ET.parse(component / "PackageInfo").getroot()
expected_attributes = {
    "auth": "root",
    "identifier": "dev.macvm.macvm.pkg",
    "install-location": "/",
    "postinstall-action": "none",
    "relocatable": "false",
    "version": version,
}
for key, expected_value in expected_attributes.items():
    if package.attrib.get(key) != expected_value:
        fail(f"installer PackageInfo {key} is {package.attrib.get(key)!r}, expected {expected_value!r}")
bundles = package.findall("bundle")
if len(bundles) != 1:
    fail("installer PackageInfo must declare exactly one app bundle")
bundle = bundles[0]
if bundle.attrib.get("path") != "./Applications/MacVM.app" or bundle.attrib.get("id") != "dev.macvm.macvm":
    fail("installer PackageInfo has the wrong app bundle path or identifier")
if bundle.attrib.get("CFBundleShortVersionString") != version:
    fail("installer PackageInfo app bundle has the wrong version")
if package.find("scripts") is not None:
    fail("installer component must not contain scripts")

distribution = ET.parse(root / "Distribution").getroot()
package_refs = distribution.findall(".//pkg-ref")
if not package_refs or {ref.attrib.get("id") for ref in package_refs} != {"dev.macvm.macvm.pkg"}:
    fail("installer Distribution must reference only dev.macvm.macvm.pkg")
locators = [ref.text.strip() for ref in package_refs if ref.text and ref.text.strip()]
if locators != ["#MacVM-component.pkg"]:
    fail(f"installer Distribution has unexpected component locators: {locators!r}")
options = distribution.find("options")
if options is None or options.attrib.get("require-scripts") != "false":
    fail("installer Distribution must disable scripts")
if "arm64" not in options.attrib.get("hostArchitectures", "").split(","):
    fail("installer Distribution does not allow arm64 hosts")
for bundle_node in distribution.findall(".//bundle"):
    if bundle_node.attrib.get("id") != "dev.macvm.macvm":
        fail("installer Distribution contains an unexpected bundle identifier")
PY
}

SIGNED_TEAM=
assert_signed_code() {
    item=$1
    expected_identifier=$2
    entitlement_policy=$3
    label=$4
    signature="$TEMP_ROOT/signed-code-$RANDOM.txt"
    entitlements="$TEMP_ROOT/entitlements-$RANDOM.plist"
    codesign --verify --strict --verbose=2 "$item" > "$signature" 2>&1 \
        || fail "$label failed code-signature verification"
    codesign --display --verbose=4 "$item" > "$signature" 2>&1 \
        || fail "$label has no readable code signature"
    team=$(python3 - "$signature" "$expected_identifier" "$label" "${SIGNED_TEAM:-}" <<'PY'
import pathlib
import re
import sys

lines = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
fields = dict(line.split("=", 1) for line in lines if "=" in line)
identifier, label, expected_team = sys.argv[2:]
if fields.get("Identifier") != identifier:
    raise SystemExit(f"{label} has identifier {fields.get('Identifier')!r}, expected {identifier!r}")
team = fields.get("TeamIdentifier", "")
if not team or team == "not set":
    raise SystemExit(f"{label} has no signing team")
authorities = [line.split("=", 1)[1] for line in lines if line.startswith("Authority=")]
if not authorities or not authorities[0].startswith("Developer ID Application: "):
    raise SystemExit(f"{label} is not signed by a Developer ID Application identity")
match = re.search(r" \(([A-Z0-9]+)\)$", authorities[0])
if not match or match.group(1) != team:
    raise SystemExit(f"{label} signing authority and TeamIdentifier disagree")
if expected_team and team != expected_team:
    raise SystemExit(f"{label} signing team {team!r} differs from {expected_team!r}")
code_directory = next((line for line in lines if line.startswith("CodeDirectory ")), "")
if "runtime" not in code_directory:
    raise SystemExit(f"{label} does not enable hardened runtime")
print(team)
PY
    ) || fail "$label has invalid Developer ID signing metadata"
    if [ -z "$SIGNED_TEAM" ]; then SIGNED_TEAM=$team; fi

    codesign --display --entitlements :- "$item" > "$entitlements" 2>/dev/null \
        || fail "$label entitlements could not be read"
    python3 - "$entitlements" "$entitlement_policy" "$label" <<'PY'
import pathlib
import plistlib
import sys

path = pathlib.Path(sys.argv[1])
policy = sys.argv[2]
label = sys.argv[3]
data = path.read_bytes().strip()
if data:
    try:
        value = plistlib.loads(data)
    except Exception as error:
        raise SystemExit(f"{label} has unreadable entitlements: {error}")
else:
    value = {}
expected = {"com.apple.security.virtualization": True} if policy == "host" else {}
if value != expected:
    raise SystemExit(f"{label} entitlements are {value!r}, expected {expected!r}")
PY
}

assert_signed_dmg() {
    signature="$TEMP_ROOT/signed-dmg.txt"
    codesign --verify --strict --verbose=2 "$DMG_PATH" > "$signature" 2>&1 \
        || fail "disk image failed code-signature verification"
    codesign --display --verbose=4 "$DMG_PATH" > "$signature" 2>&1 \
        || fail "disk image has no readable code signature"
    python3 - "$signature" "$SIGNED_TEAM" <<'PY'
import pathlib
import re
import sys

lines = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
fields = dict(line.split("=", 1) for line in lines if "=" in line)
if fields.get("Identifier") != "dev.macvm.macvm.dmg":
    raise SystemExit("disk image has the wrong signing identifier")
if fields.get("TeamIdentifier") != sys.argv[2]:
    raise SystemExit("disk image signing team differs from the app signing team")
authorities = [line.split("=", 1)[1] for line in lines if line.startswith("Authority=")]
if not authorities or not authorities[0].startswith("Developer ID Application: "):
    raise SystemExit("disk image is not signed by a Developer ID Application identity")
match = re.search(r" \(([A-Z0-9]+)\)$", authorities[0])
if not match or match.group(1) != sys.argv[2]:
    raise SystemExit("disk image signing authority and team disagree")
PY
}

hdiutil verify "$DMG_PATH" >/dev/null || fail "hdiutil verify rejected the disk image"
preexisting_devices="$TEMP_ROOT/preexisting-devices.txt"
record_image_devices "$preexisting_devices" || fail "could not inspect attached disk images"
[ ! -s "$preexisting_devices" ] || fail "disk image is already attached; detach it before verification"

attach_plist="$TEMP_ROOT/dmg-attach.plist"
DMG_ATTACH_STARTED=1
hdiutil attach -readonly -nobrowse -noverify -mountpoint "$DMG_MOUNT_POINT" -plist "$DMG_PATH" > "$attach_plist"
python3 - "$attach_plist" "$DMG_MOUNT_POINT" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    value = plistlib.load(source)
expected = os.path.realpath(sys.argv[2])
mounts = [
    os.path.realpath(entity["mount-point"])
    for entity in value.get("system-entities", [])
    if entity.get("mount-point")
]
if mounts != [expected]:
    raise SystemExit(f"disk image attach returned unexpected mount points: {mounts!r}")
PY
[ -d "$DMG_MOUNT_POINT" ] || fail "disk image mount point is unavailable"
assert_exact_dmg_root
DMG_APP="$DMG_MOUNT_POINT/MacVM.app"
assert_app_layout "$DMG_APP" "disk image"
assert_cli_self_check "$DMG_APP/Contents/Helpers/macvm"

EXPANDED_PKG="$TEMP_ROOT/expanded-pkg"
pkgutil --expand-full "$PKG_PATH" "$EXPANDED_PKG"
assert_package_layout "$EXPANDED_PKG"
PKG_APP="$EXPANDED_PKG/MacVM-component.pkg/Payload/Applications/MacVM.app"
assert_app_layout "$PKG_APP" "installer package"
compare_app_manifests "$DMG_APP" "$PKG_APP"

if [ "$MODE" = signed ]; then
    codesign --verify --deep --strict --verbose=2 "$DMG_APP" >/dev/null 2>&1 \
        || fail "disk image MacVM.app failed deep code-signature verification"
    codesign --verify --deep --strict --verbose=2 "$PKG_APP" >/dev/null 2>&1 \
        || fail "installer MacVM.app failed deep code-signature verification"
    resource_root="$DMG_APP/Contents/Resources/macvm_MacVMHostKit.bundle/Resources"
    assert_signed_code "$DMG_APP" "dev.macvm.macvm" host "MacVM.app"
    assert_signed_code "$DMG_APP/Contents/Helpers/macvm" "dev.macvm.macvm.cli" host "embedded macvm CLI"
    assert_signed_code "$resource_root/Docker/macvm-docker-guest" "dev.macvm.macvm.docker-guest" guest "Docker guest helper"
    assert_signed_code "$resource_root/Clipboard/macvm-clipboard-guest" "dev.macvm.clipboard-guest" guest "clipboard guest helper"
    assert_signed_dmg

    package_signature="$TEMP_ROOT/package-signature.txt"
    pkgutil --check-signature "$PKG_PATH" > "$package_signature" 2>&1 \
        || fail "installer package signature is invalid"
    python3 - "$package_signature" "$SIGNED_TEAM" <<'PY'
import pathlib
import re
import sys

lines = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
identities = [line.strip() for line in lines if "Developer ID Installer:" in line]
if not identities:
    raise SystemExit("installer package is not signed by a Developer ID Installer identity")
match = re.search(r"Developer ID Installer: .* \(([A-Z0-9]+)\)", identities[0])
if not match or match.group(1) != sys.argv[2]:
    raise SystemExit("installer package signing team differs from the app signing team")
PY

    xcrun stapler validate "$DMG_PATH" >/dev/null \
        || fail "disk image has no valid stapled notarization ticket"
    xcrun stapler validate "$PKG_PATH" >/dev/null \
        || fail "installer package has no valid stapled notarization ticket"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" >/dev/null \
        || fail "Gatekeeper rejected the notarized disk image"
    spctl --assess --type install --verbose=4 "$PKG_PATH" >/dev/null \
        || fail "Gatekeeper rejected the notarized installer package"
else
    if codesign --display --verbose=4 "$DMG_PATH" > "$TEMP_ROOT/unsigned-dmg-signature.txt" 2>&1 \
        && grep -q '^Authority=Developer ID Application:' "$TEMP_ROOT/unsigned-dmg-signature.txt"; then
        fail "unsigned mode received a Developer ID-signed disk image"
    fi
    pkgutil --check-signature "$PKG_PATH" > "$TEMP_ROOT/unsigned-package-signature.txt" 2>&1 || true
    if grep -q 'Developer ID Installer:' "$TEMP_ROOT/unsigned-package-signature.txt"; then
        fail "unsigned mode received a Developer ID-signed installer package"
    fi
fi

printf 'Verified %s release artifacts:\n  %s\n  %s\n' "$MODE" "$DMG_PATH" "$PKG_PATH"
