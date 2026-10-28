#!/bin/sh
# Builds "Photo Backup Checker.app" into ./build
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP="build/Photo Backup Checker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PhotoBackupChecker "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: Resources/AppIcon.svg -> AppIcon.icns (macOS built-ins only)
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
qlmanage -t -s 1024 -o build Resources/AppIcon.svg >/dev/null 2>&1
for s in 16 32 128 256 512; do
  sips -z $s $s build/AppIcon.svg.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/AppIcon.svg.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" build/AppIcon.svg.png

codesign --force --deep --sign - "$APP"
echo "$PWD/$APP"
