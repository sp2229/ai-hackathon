#!/usr/bin/env bash
# Builds Unplugged.app (release) with SwiftPM — works with Command Line Tools or Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
APP=build/Unplugged.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Unplugged "$APP/Contents/MacOS/Unplugged"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# copy any SwiftPM resource bundles next to the binary
find .build/arm64-apple-macosx/release -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
codesign --force --deep --sign - "$APP"
echo "✓ Built $APP — run: open $APP"
