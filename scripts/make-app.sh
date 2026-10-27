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
codesign --force --deep --sign - "$APP"
echo "$PWD/$APP"
