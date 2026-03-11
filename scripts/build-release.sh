#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/dist"
PRODUCT_NAME="macvm"
PROJECT_PATH="$ROOT_DIR/macvm.xcodeproj"
CONFIGURATION="Release"
DERIVED_DATA_PATH="${XCODE_DERIVED_DATA:-$ROOT_DIR/.build/xcode-derived}"
SOURCE_PACKAGES_PATH="${XCODE_SOURCE_PACKAGES:-$ROOT_DIR/.build/xcode-source-packages}"
PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$PRODUCT_NAME" \
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

echo "Built ad-hoc Xcode-signed $OUTPUT_DIR/$PRODUCT_NAME with resource bundles"
