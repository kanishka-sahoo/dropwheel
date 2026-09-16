#!/bin/zsh
# Builds Dropwheel.app into ./build using SwiftPM (no Xcode required).
#
#   ./scripts/build_app.sh [release|debug]
#
# Set APP_VERSION / BUILD_NUMBER to stamp Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
ENTITLEMENTS="Resources/Dropwheel.entitlements"

swift build -c "$CONFIG" 2>&1 | grep -vE '^\s*$' | tail -20
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Dropwheel"
APP="build/Dropwheel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dropwheel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${APP_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
[ -f build/AppIcon.icns ] || swift scripts/make_icon.swift build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc codesign so the entitlements (Apple Events for the Finder shortcut) apply.
codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP"
echo "Built $APP"
