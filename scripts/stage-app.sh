#!/bin/zsh
set -euo pipefail

# Build and stage the Xcode-produced "dist/MacVM.app". The app hosts
# VZVirtualMachine in-process, so the Xcode target signs local builds with the
# same virtualization entitlement as the CLI. Public Developer ID packaging is
# handled by scripts/package-release.sh.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/dist"
APP_SCHEME="MacVM App"
APP_NAME="MacVM"
PROJECT_PATH="$ROOT_DIR/macvm.xcodeproj"
CONFIGURATION="Release"
DERIVED_DATA_PATH="${XCODE_DERIVED_DATA:-$ROOT_DIR/.build/xcode-derived}"
SOURCE_PACKAGES_PATH="${XCODE_SOURCE_PACKAGES:-$ROOT_DIR/.build/xcode-source-packages}"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$APP_SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"

rm -rf "$APP_DIR"
mkdir -p "$OUTPUT_DIR"
ditto "$PRODUCTS_DIR/$APP_NAME.app" "$APP_DIR"

echo "Built $APP_DIR with Xcode signing ($CONFIGURATION)"
