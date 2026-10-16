#!/bin/bash
# Builds the downloadable release: dist/FocusLock-mac.zip with the ready-built app, the helper and
# double-click "Install Focus Lock.command" / "Uninstall Focus Lock.command".
#   ./package.sh && gh release create vX.Y dist/FocusLock-mac.zip
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
rm -rf dist && mkdir -p "dist/Focus Lock"
OUT="dist/Focus Lock"
cp -R "build/Focus Lock.app" build/focuslock-helper "$OUT/"
cp install.sh "$OUT/Install Focus Lock.command"
cp uninstall.sh "$OUT/Uninstall Focus Lock.command"
chmod +x "$OUT"/*.command
cat > "$OUT/READ ME FIRST.txt" <<'TXT'
Focus Lock for Mac (macOS 13 or newer, Apple Silicon or Intel)

1. Right-click (or Control-click) "Install Focus Lock.command" and choose Open.
   Focus Lock isn't from the App Store, so macOS asks first. If it says it can't be opened, go to
   System Settings > Privacy & Security, scroll down, and click "Open Anyway".
2. Type your Mac password when asked (once). It installs the part that blocks websites.
3. The Focus Lock window opens. Set your focus hours, apps and websites.
4. When a box asks if Focus Lock can control Chrome or Safari, click OK. That lets it close
   tabs on blocked sites.

The lock icon in the menu bar starts a session or shows how long is left.
To remove it, open "Uninstall Focus Lock.command" (not during a focus session).
TXT
(cd dist && ditto -c -k --sequesterRsrc --keepParent "Focus Lock" FocusLock-mac.zip)
rm -rf "dist/Focus Lock"
echo "Made dist/FocusLock-mac.zip ($(du -h dist/FocusLock-mac.zip | cut -f1))"
