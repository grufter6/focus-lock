#!/bin/zsh
# Installs the website blocker (needs your Mac password once): a root helper that edits /etc/hosts
# during focus sessions so blocked sites don't load in any browser.   Run:  sudo ./install-site-blocking.sh
set -e
cd "${0:A:h}"
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./install-site-blocking.sh"; exit 1; }
USER_HOME=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')
STATE="$USER_HOME/Library/Application Support/FocusLock/state.json"
mkdir -p /Library/PrivilegedHelperTools "/Library/Application Support/FocusLock"
sed "s#__STATE__#$STATE#" src/focuslock-hostsd > /Library/PrivilegedHelperTools/focuslock-hostsd
chown root:wheel /Library/PrivilegedHelperTools/focuslock-hostsd; chmod 755 /Library/PrivilegedHelperTools/focuslock-hostsd
cat > /Library/LaunchDaemons/com.focuslock.hostsd.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.focuslock.hostsd</string>
  <key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/focuslock-hostsd</string></array>
  <key>StartInterval</key><integer>10</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
chown root:wheel /Library/LaunchDaemons/com.focuslock.hostsd.plist
launchctl bootout system/com.focuslock.hostsd 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.focuslock.hostsd.plist
echo "Website blocking installed."
