# Focus Lock

A Mac menu-bar app that locks you into focus time. During focus time:
- **Apps close:** Roblox, Minecraft (including the Java game) and Asphalt 8 by default.
- **Websites don't load:** they're blocked in every browser.

You can't stop focus time early: the menu has no Quit, and the app relaunches if you force-quit it.

## Using it

- **Open Focus Lock** (Spotlight, or `~/Applications`) to set things up:
  - **Focus hours:** days and times it turns on by itself, including overnight
  - **Blocked apps:** add with a file picker
  - **Blocked websites:** type one in, like `youtube.com`
- **Start now:** click the lock icon in the menu bar → 25 min / 50 min / 90 min / 2 hours. Picking one during a session adds time.
- **Lock rules:** while focus is on, you can add blocks but not remove or shorten anything. Saving focus hours that include right now asks before it locks you in.

## How it's built

| Part | Where | Job |
|---|---|---|
| Menu-bar app | `src/app/` → `~/Applications/Focus Lock.app` | Menu, Settings window, closes blocked apps, rotates the wallpapers. Starts at login with `--background`, and relaunches if killed. |
| Root helper | `src/FocusLockHelper.swift` → `/Library/Application Support/FocusLock/` | Runs as root. Keeps the session's end time in a root-owned file that only moves later, blocks sites in `/etc/hosts`, and closes blocked apps even if the menu-bar app is gone. Caps any session at 24 h. Log: `/Library/Logs/FocusLock-helper.log` |
| Settings | `~/Library/Application Support/FocusLock/settings.json` | Written by the Settings window |
| Wallpapers | `wallpapers/` | 26 dark Wikimedia Commons photos (nature, night skies and city skylines), changed every hour. `CREDITS.txt` holds the attribution their licences require, so keep it with them. `src/make_wallpapers.py` draws the older generated set into `wallpapers/generated/`. |

## Scripts

- `./install.sh` builds and installs everything. It asks for your Mac password once, and is safe to rerun after changes.
- `./uninstall.sh` removes everything, but refuses while focus time is on.
- `./build.sh` only builds.

## Limits

- Anyone with your Mac's admin password and Terminal can still remove it.
- `/etc/hosts` can't block every subdomain (only the site, `www.` and `m.`).
- A browser using its own secure DNS may skip `/etc/hosts`. Safari and Chrome's default settings respect it.
