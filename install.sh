#!/bin/bash
# Installs Focus Lock for the current user:
#   ~/Applications/Focus Lock.app                    the menu-bar app (starts at login, restarts if killed)
#   /Library/Application Support/FocusLock/          the root helper that blocks sites and enforces sessions
#   /Library/LaunchDaemons/com.focuslock.helper.plist
# Asks for your Mac password once (for the helper). Safe to run again to update.
#
# From the source folder it builds first. From the downloaded release (where this file is
# "Install Focus Lock.command" next to a ready-built "Focus Lock.app") it installs those instead.
set -euo pipefail
cd "$(dirname "$0")"
if [ -d "Focus Lock.app" ] && [ -f focuslock-helper ]; then
  SRC="."
  # Downloaded files are quarantined; this app is unsigned, so clear the flag on what we install.
  xattr -dr com.apple.quarantine "Focus Lock.app" focuslock-helper 2>/dev/null || true
else
  ./build.sh
  SRC="build"
fi

USER_DIR="$HOME/Library/Application Support/FocusLock"
APP="$HOME/Applications/Focus Lock.app"
AGENT="$HOME/Library/LaunchAgents/com.focuslock.app.plist"
mkdir -p "$USER_DIR" "$HOME/Applications" "$HOME/Library/LaunchAgents"

# ── the root helper (needs your password, unless the same helper is already installed) ──
HELPER="/Library/Application Support/FocusLock/focuslock-helper"
DAEMON=/Library/LaunchDaemons/com.focuslock.helper.plist
if cmp -s "$SRC/focuslock-helper" "$HELPER" && grep -qF "$USER_DIR" "$DAEMON" 2>/dev/null; then
  echo "The website blocker is already installed and up to date."
else
# macOS doesn't let the password-prompt shell read ~/Documents, so stage the helper in a temp folder first.
STAGE="$(mktemp -d -t focuslock)"
cp "$SRC/focuslock-helper" "$STAGE/"
ROOT_SCRIPT="$STAGE/root-install.sh"
cat > "$ROOT_SCRIPT" <<ROOT
set -e
mkdir -p "/Library/Application Support/FocusLock"
install -o root -g wheel -m 755 "$STAGE/focuslock-helper" "/Library/Application Support/FocusLock/focuslock-helper"
cat > /Library/LaunchDaemons/com.focuslock.helper.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.focuslock.helper</string>
  <key>ProgramArguments</key><array>
    <string>/Library/Application Support/FocusLock/focuslock-helper</string>
    <string>--user-dir</string><string>$USER_DIR</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Library/Logs/FocusLock-helper.log</string>
  <key>StandardErrorPath</key><string>/Library/Logs/FocusLock-helper.log</string>
</dict></plist>
PLIST
chown root:wheel /Library/LaunchDaemons/com.focuslock.helper.plist
chmod 644 /Library/LaunchDaemons/com.focuslock.helper.plist
launchctl bootout system/com.focuslock.helper 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.focuslock.helper.plist
ROOT
echo "Asking for your Mac password to install the helper that blocks websites…"
osascript -e "do shell script \"/bin/bash \" & quoted form of \"$ROOT_SCRIPT\" with prompt \"Focus Lock needs your password once to install its website blocker.\" with administrator privileges"
rm -rf "$STAGE"
fi

# ── the menu-bar app ──
launchctl bootout "gui/$(id -u)/com.focuslock.app" 2>/dev/null || true
pkill -x FocusLock 2>/dev/null || true
rm -rf "$APP"
cp -R "$SRC/Focus Lock.app" "$APP"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.focuslock.app</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/FocusLock</string><string>--background</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"

sleep 2
if pgrep -x FocusLock >/dev/null && launchctl print system/com.focuslock.helper >/dev/null 2>&1; then
  echo "Installed. Look for the lock icon in the menu bar, or open Focus Lock from Spotlight to set your focus hours."
  open "$APP"     # shows the settings window
else
  echo "Something didn't start. Check: launchctl print system/com.focuslock.helper" >&2; exit 1
fi
