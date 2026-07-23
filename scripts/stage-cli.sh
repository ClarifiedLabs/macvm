#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/dist"
PRODUCT_NAME="macvm"
SCHEME_NAME="MacVM CLI"
PROJECT_PATH="$ROOT_DIR/macvm.xcodeproj"
CONFIGURATION="Release"
DERIVED_DATA_PATH="${XCODE_DERIVED_DATA:-$ROOT_DIR/.build/xcode-derived}"
SOURCE_PACKAGES_PATH="${XCODE_SOURCE_PACKAGES:-$ROOT_DIR/.build/xcode-source-packages}"
PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build

mkdir -p "$OUTPUT_DIR"
cp "$PRODUCTS_DIR/$PRODUCT_NAME" "$OUTPUT_DIR/$PRODUCT_NAME"
rm -rf "$OUTPUT_DIR"/*.bundle(N)
for bundle in "$PRODUCTS_DIR"/*.bundle(N); do
  cp -R "$bundle" "$OUTPUT_DIR/"
done

DOCKER_GUEST_HELPER="$OUTPUT_DIR/macvm_MacVMHostKit.bundle/Resources/Docker/macvm-docker-guest"
CLIPBOARD_GUEST_HELPER="$OUTPUT_DIR/macvm_MacVMHostKit.bundle/Resources/Clipboard/macvm-clipboard-guest"
for helper in "$DOCKER_GUEST_HELPER" "$CLIPBOARD_GUEST_HELPER"; do
  if [[ ! -x "$helper" ]]; then
    echo "Missing bundled guest helper: $helper" >&2
    exit 2
  fi
  lipo "$helper" -verify_arch arm64
  codesign --verify --strict --verbose=2 "$helper"
done

echo "Built ad-hoc Xcode-signed $OUTPUT_DIR/$PRODUCT_NAME with resource bundles"
