#!/bin/bash
# Builds build/Focus Lock.app (the menu-bar app) and build/focuslock-helper (the root helper).
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build
APP="build/Focus Lock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/FocusLock" src/app/*.swift
swiftc -O -o build/focuslock-helper src/FocusLockHelper.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Focus Lock</string>
  <key>CFBundleDisplayName</key><string>Focus Lock</string>
  <key>CFBundleIdentifier</key><string>com.focuslock.app</string>
  <key>CFBundleExecutable</key><string>FocusLock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
codesign --force --sign - build/focuslock-helper >/dev/null 2>&1
echo "Built $APP and build/focuslock-helper"
