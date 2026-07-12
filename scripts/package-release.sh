#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build/release}"
PAYLOAD_ROOT="$BUILD_DIR/payload"
PROJECT_PATH="$ROOT_DIR/macvm.xcodeproj"
DERIVED_DATA_PATH="${XCODE_DERIVED_DATA:-$ROOT_DIR/.build/xcode-derived}"
SOURCE_PACKAGES_PATH="${XCODE_SOURCE_PACKAGES:-$ROOT_DIR/.build/xcode-source-packages}"
CONFIGURATION="Release"

APP_SCHEME="MacVM App"
APP_NAME="MacVM"
CLI_NAME="macvm"
CLI_SCHEME="MacVM CLI"
RESOURCE_BUNDLE_NAME="macvm_MacVMHostKit.bundle"
BASE_BUNDLE_IDENTIFIER="dev.macvm.macvm"
CLI_BUNDLE_IDENTIFIER="$BASE_BUNDLE_IDENTIFIER.cli"
PKG_IDENTIFIER="$BASE_BUNDLE_IDENTIFIER.pkg"
ENTITLEMENTS_PATH="$ROOT_DIR/Support/macvm.entitlements"
COMPONENT_PLIST_PATH="$ROOT_DIR/Support/macvm-component.plist"

export COPYFILE_DISABLE=1

enabled() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

project_marketing_version() {
  awk -F ' = |;' '
    /MARKETING_VERSION = [0-9]+[.][0-9]+[.][0-9]+;/ {
      print $2
      exit
    }
  ' "$PROJECT_PATH/project.pbxproj"
}

resolve_version() {
  if [[ -n "${MACVM_RELEASE_VERSION:-}" ]]; then
    printf '%s\n' "$MACVM_RELEASE_VERSION"
    return
  fi

  if [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
    printf '%s\n' "${GITHUB_REF#refs/tags/v}"
    return
  fi

  project_marketing_version
}

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" ]]; then
    echo "Missing $label: $path" >&2
    exit 2
  fi
}

require_nonempty() {
  local value="$1"
  local label="$2"
  if [[ -z "$value" ]]; then
    echo "Missing required release setting: $label" >&2
    exit 2
  fi
}

VERSION="$(resolve_version)"
BUILD_NUMBER="${MACVM_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
SIGN_RELEASE="${MACVM_SIGN_RELEASE:-0}"
NOTARIZE_RELEASE="${MACVM_NOTARIZE:-0}"

if enabled "$NOTARIZE_RELEASE"; then
  SIGN_RELEASE=1
fi

if [[ ! "$VERSION" =~ '^[0-9]+[.][0-9]+[.][0-9]+$' ]]; then
  echo "Invalid release version '$VERSION' (expected X.Y.Z)" >&2
  exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ '^[0-9]+$' ]]; then
  echo "Invalid build number '$BUILD_NUMBER' (expected integer)" >&2
  exit 2
fi

require_file "$COMPONENT_PLIST_PATH" "package component plist"

build_scheme() {
  local scheme="$1"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$scheme" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    build
}

sign_release_payload() {
  local developer_id_application="${MACVM_DEVELOPER_ID_APPLICATION:-${DEVELOPER_ID_APPLICATION:-}}"
  require_nonempty "$developer_id_application" "MACVM_DEVELOPER_ID_APPLICATION"
  require_file "$ENTITLEMENTS_PATH" "release entitlements"

  codesign --force \
    --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS_PATH" \
    --identifier "$CLI_BUNDLE_IDENTIFIER" \
    --sign "$developer_id_application" \
    "$CLI_PATH"

  codesign --force \
    --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$developer_id_application" \
    "$APP_PATH"

  codesign --verify --strict --verbose=2 "$CLI_PATH"
  codesign --verify --strict --verbose=2 "$APP_PATH"
}

notarytool_args=()

resolve_notarytool_args() {
  if [[ -n "${MACVM_NOTARYTOOL_PROFILE:-}" ]]; then
    notarytool_args=(--keychain-profile "$MACVM_NOTARYTOOL_PROFILE")
    return
  fi

  local key_path="${MACVM_NOTARYTOOL_KEY_PATH:-${APP_STORE_CONNECT_KEY_PATH:-}}"
  local key_id="${MACVM_NOTARYTOOL_KEY_ID:-${APP_STORE_CONNECT_KEY_ID:-}}"
  local issuer_id="${MACVM_NOTARYTOOL_ISSUER_ID:-${APP_STORE_CONNECT_ISSUER_ID:-}}"
  if [[ -n "$key_path" && -n "$key_id" && -n "$issuer_id" ]]; then
    notarytool_args=(--key "$key_path" --key-id "$key_id" --issuer "$issuer_id")
    return
  fi

  local apple_id="${MACVM_NOTARYTOOL_APPLE_ID:-${APPLE_ID:-}}"
  local password="${MACVM_NOTARYTOOL_PASSWORD:-${APPLE_APP_SPECIFIC_PASSWORD:-}}"
  local team_id="${MACVM_NOTARYTOOL_TEAM_ID:-${APPLE_TEAM_ID:-}}"
  if [[ -n "$apple_id" && -n "$password" && -n "$team_id" ]]; then
    notarytool_args=(--apple-id "$apple_id" --password "$password" --team-id "$team_id")
    return
  fi

  echo "Missing notarytool credentials. Set MACVM_NOTARYTOOL_PROFILE, App Store Connect API key variables, or Apple ID variables." >&2
  exit 2
}

notarize_item() {
  local item_path="$1"
  local label="$2"

  echo "Submitting $label for notarization..."
  xcrun notarytool submit "$item_path" --wait "${notarytool_args[@]}"
}

build_installer_package() {
  local component_pkg="$BUILD_DIR/MacVM-component.pkg"
  local unsigned_pkg="$BUILD_DIR/MacVM-$VERSION.unsigned.pkg"
  local installer_identity="${MACVM_DEVELOPER_ID_INSTALLER:-${DEVELOPER_ID_INSTALLER:-}}"

  rm -f "$component_pkg" "$unsigned_pkg" "$PKG_PATH"
  pkgbuild \
    --root "$PAYLOAD_ROOT" \
    --identifier "$PKG_IDENTIFIER" \
    --version "$VERSION" \
    --install-location / \
    --ownership recommended \
    --component-plist "$COMPONENT_PLIST_PATH" \
    "$component_pkg"

  productbuild --package "$component_pkg" "$unsigned_pkg"

  if enabled "$SIGN_RELEASE"; then
    require_nonempty "$installer_identity" "MACVM_DEVELOPER_ID_INSTALLER"
    productsign --sign "$installer_identity" "$unsigned_pkg" "$PKG_PATH"
    rm -f "$unsigned_pkg"
    pkgutil --check-signature "$PKG_PATH"
  else
    mv "$unsigned_pkg" "$PKG_PATH"
  fi
}

notarize_installer_package() {
  resolve_notarytool_args
  notarize_item "$PKG_PATH" "MacVM installer package"
  xcrun stapler staple "$PKG_PATH"
  xcrun stapler validate "$PKG_PATH"
  spctl --assess --type install --verbose=4 "$PKG_PATH"
}

rm -rf "$BUILD_DIR"
mkdir -p "$OUTPUT_DIR" "$PAYLOAD_ROOT/usr/local/bin" "$PAYLOAD_ROOT/Applications"

build_scheme "$CLI_SCHEME"
build_scheme "$APP_SCHEME"

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION"
CLI_PRODUCT="$PRODUCTS_DIR/$CLI_NAME"
APP_PRODUCT="$PRODUCTS_DIR/$APP_NAME.app"
RESOURCE_BUNDLE_PRODUCT="$PRODUCTS_DIR/$RESOURCE_BUNDLE_NAME"

require_file "$CLI_PRODUCT" "CLI product"
require_file "$APP_PRODUCT" "manager app product"
require_file "$RESOURCE_BUNDLE_PRODUCT" "MacVMHostKit resource bundle"

CLI_PATH="$PAYLOAD_ROOT/usr/local/bin/$CLI_NAME"
APP_PATH="$PAYLOAD_ROOT/Applications/$APP_NAME.app"
PKG_PATH="$OUTPUT_DIR/MacVM-$VERSION.pkg"

ditto --norsrc --noextattr "$CLI_PRODUCT" "$CLI_PATH"
ditto --norsrc --noextattr "$RESOURCE_BUNDLE_PRODUCT" "$PAYLOAD_ROOT/usr/local/bin/$RESOURCE_BUNDLE_NAME"
ditto --norsrc --noextattr "$APP_PRODUCT" "$APP_PATH"

if enabled "$SIGN_RELEASE"; then
  sign_release_payload
else
  echo "Skipping Developer ID signing. Set MACVM_SIGN_RELEASE=1 for public release packages."
fi

build_installer_package

if enabled "$NOTARIZE_RELEASE"; then
  notarize_installer_package
fi

echo "Built $PKG_PATH"
