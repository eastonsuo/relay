#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="Relay"
VERSION="0.1.0"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SOURCE_FILE="$ROOT_DIR/Sources/Relay/main.swift"

rm -rf "$BUILD_DIR" "$APP_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR" "$MACOS_DIR" "$RESOURCES_DIR"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
mkdir -p "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"

build_arch() {
    local arch="$1"
    local output="$BUILD_DIR/$APP_NAME-$arch"

    swiftc \
        -parse-as-library \
        -O \
        -sdk "$SDK_PATH" \
        -module-cache-path "$MODULE_CACHE_DIR" \
        -target "$arch-apple-macos13.0" \
        -framework SwiftUI \
        -framework AppKit \
        "$SOURCE_FILE" \
        -o "$output"
}

build_arch arm64
build_arch x86_64

lipo -create \
    "$BUILD_DIR/$APP_NAME-arm64" \
    "$BUILD_DIR/$APP_NAME-x86_64" \
    -output "$MACOS_DIR/$APP_NAME"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$MACOS_DIR/$APP_NAME"

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Built $APP_DIR (v$VERSION)"
