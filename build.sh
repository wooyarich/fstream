#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_FILE="$SCRIPT_DIR/src/FStreamMain.swift"
RES_DIR="$SCRIPT_DIR/Resources"
APP_BUNDLE="$SCRIPT_DIR/FStream.app"
ARCH_TARGET="${ARCH_TARGET:-arm64-apple-macos13.0}"

echo "==> [1/4] Cleaning previous build..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "==> [2/4] Copying Info.plist, icons, and SkinAssets..."
cp "$RES_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$RES_DIR/PkgInfo" "$APP_BUNDLE/Contents/PkgInfo"
cp -R "$RES_DIR/"*.icns "$APP_BUNDLE/Contents/Resources/"
cp -R "$RES_DIR/"*.png "$APP_BUNDLE/Contents/Resources/"
cp -R "$RES_DIR/Korean.lproj" "$APP_BUNDLE/Contents/Resources/"
cp -R "$RES_DIR/English.lproj" "$APP_BUNDLE/Contents/Resources/"
cp -R "$RES_DIR/SkinAssets" "$APP_BUNDLE/Contents/Resources/"

echo "==> [3/4] Compiling FStream (target: $ARCH_TARGET)..."
swiftc -O -target "$ARCH_TARGET" \
    -framework Cocoa \
    -framework Network \
    -framework AudioToolbox \
    -framework AVFoundation \
    "$SRC_FILE" \
    -o "$APP_BUNDLE/Contents/MacOS/FStream"

echo "==> [4/4] Stripping quarantine attributes and signing bundle..."
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Build complete: $APP_BUNDLE"
file "$APP_BUNDLE/Contents/MacOS/FStream"
