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
if [[ ! -x "$DOCKER_GUEST_HELPER" ]]; then
  echo "Missing bundled Docker guest helper: $DOCKER_GUEST_HELPER" >&2
  exit 2
fi
codesign --verify --strict --verbose=2 "$DOCKER_GUEST_HELPER"

echo "Built ad-hoc Xcode-signed $OUTPUT_DIR/$PRODUCT_NAME with resource bundles"
