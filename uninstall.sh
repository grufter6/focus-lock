#!/bin/bash
# Removes Focus Lock. Refuses while a focus session is running.
set -euo pipefail
LOCK="/Library/Application Support/FocusLock/lock-until"
if [ -f "$LOCK" ] && [ "$(cut -d. -f1 "$LOCK")" -gt "$(date +%s)" ]; then
  echo "A focus session is running until $(date -r "$(cut -d. -f1 "$LOCK")" '+%-I:%M %p'). Uninstall after it ends." >&2
  exit 1
fi
launchctl bootout "gui/$(id -u)/com.focuslock.app" 2>/dev/null || true
pkill -x FocusLock 2>/dev/null || true
rm -rf "$HOME/Applications/Focus Lock.app" "$HOME/Library/LaunchAgents/com.focuslock.app.plist"
osascript -e 'do shell script "launchctl bootout system/com.focuslock.helper 2>/dev/null; rm -f /Library/LaunchDaemons/com.focuslock.helper.plist; rm -rf \"/Library/Application Support/FocusLock\"; sed -i \"\" \"/^# >>> Focus Lock/,/^# <<< Focus Lock <<</d\" /etc/hosts" with prompt "Focus Lock needs your password to uninstall." with administrator privileges'
echo "Uninstalled. Your settings are still in ~/Library/Application Support/FocusLock."
