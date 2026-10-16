// Focus Lock: menu-bar app that blocks distracting apps (and, with the helper installed, websites)
// during focus sessions and scheduled focus hours. A started session cannot be ended early.
import AppKit
import Foundation

// MARK: - Settings and state (JSON files in ~/Library/Application Support/FocusLock, or $FOCUSLOCK_DIR for tests)

struct ScheduleBlock: Codable, Identifiable, Equatable {
    var id = UUID()      // for the settings list only; not saved
    var days: [Int]      // 1 = Sunday ... 7 = Saturday (Calendar weekday numbers)
    var start: String    // "16:00"
    var end: String      // "21:00"; earlier than start means it runs past midnight

    enum CodingKeys: String, CodingKey { case days, start, end }
}

struct Settings: Codable, Equatable {
    var blockedApps: [String]     // bundle identifiers
    var blockedSites: [String]    // domains; www. and m. are added automatically
    var blockedPaths: [String]? = ["/Library/Application Support/minecraft/"]   // processes running from here (the Minecraft game is Java)
    var schedule: [ScheduleBlock]
    var ambientWallpapers: Bool? = true    // rotate the dark focus wallpapers
    var wallpaperMinutes: Int? = 60

    static let defaults = Settings(
        blockedApps: ["com.roblox.RobloxPlayer", "com.roblox.RobloxStudio", "com.mojang.minecraftlauncher",
                      "com.gameloft.asphalt8"],
        blockedSites: ["tiktok.com", "instagram.com", "snapchat.com", "roblox.com", "poki.com", "coolmathgames.com",
                       "minecraft.net", "crazygames.com", "gameloft.com"],
        blockedPaths: ["/Library/Application Support/minecraft/"],
        schedule: [], ambientWallpapers: true, wallpaperMinutes: 60)
}

struct SessionState: Codable {
    var focusUntil: Double        // unix time; the helper reads this to block websites
    var blockedSites: [String]
}

let dir: URL = {
    if let d = ProcessInfo.processInfo.environment["FOCUSLOCK_DIR"] { return URL(fileURLWithPath: d) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FocusLock")
}()
let settingsURL = dir.appendingPathComponent("settings.json")
let stateURL = dir.appendingPathComponent("state.json")
// Written by the root helper; only ever moves later, so editing state.json cannot shorten a session.
let lockURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOCUSLOCK_LOCKFILE"]
                  ?? "/Library/Application Support/FocusLock/lock-until")
/// Installed by install.sh. Without it, apps are still closed but websites aren't blocked.
var helperInstalled: Bool { FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.focuslock.helper.plist") }

func loadSettings() -> Settings {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: settingsURL), let s = try? JSONDecoder().decode(Settings.self, from: data) { return s }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(Settings.defaults).write(to: settingsURL)
    return Settings.defaults
}

func saveSettings(_ s: Settings) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(s).write(to: settingsURL, options: .atomic)
}

func loadState() -> SessionState? {
    guard let data = try? Data(contentsOf: stateURL) else { return nil }
    return try? JSONDecoder().decode(SessionState.self, from: data)
}

func saveState(_ s: SessionState) {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
    try? enc.encode(s).write(to: stateURL, options: .atomic)
}

/// "16:30" -> 990 (minutes after midnight)
func minutesOf(_ hhmm: String) -> Int? {
    let p = hhmm.split(separator: ":").compactMap { Int($0) }
    guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
    return p[0] * 60 + p[1]
}

/// When `b` would end if it is running at `now`. A block whose end is earlier than its start runs past
/// midnight, and belongs to the day it starts on.
func blockEnd(_ b: ScheduleBlock, now: Date = Date()) -> Date? {
    let cal = Calendar.current
    guard let s = minutesOf(b.start), let e = minutesOf(b.end), s != e else { return nil }
    for offset in [0, -1] {                                      // started today, or last night
        guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)),
              b.days.contains(cal.component(.weekday, from: day)),
              let start = cal.date(byAdding: .minute, value: s, to: day),
              let end = cal.date(byAdding: .minute, value: e <= s ? e + 1440 : e, to: day) else { continue }
        if start <= now && now < end { return end }
    }
    return nil
}

/// End of the scheduled focus hours covering `now`, if any.
func scheduledEnd(_ schedule: [ScheduleBlock], now: Date = Date()) -> Date? {
    schedule.compactMap { blockEnd($0, now: now) }.max()
}

// MARK: - App

final class FocusLock: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var settings = loadSettings()
    var timer: Timer?
    var wallpaperTimer: Timer?
    var wallpaperIndex = 0

    /// When the current focus ends (manual session, root lock file or schedule), or nil when off.
    var focusUntil: Date? {
        var ends: [Double] = []
        if let s = loadState() { ends.append(s.focusUntil) }
        if let t = try? String(contentsOf: lockURL, encoding: .utf8), let v = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)) {
            ends.append(v)
        }
        if let e = scheduledEnd(settings.schedule) { ends.append(e.timeIntervalSince1970) }
        guard let m = ends.max(), m > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: m)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appLaunched(_:)),
                                                          name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        if let i = CommandLine.arguments.firstIndex(of: "--start"), i + 1 < CommandLine.arguments.count,
           let mins = Double(CommandLine.arguments[i + 1]) {
            start(minutes: mins)
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        if settings.ambientWallpapers ?? true { startWallpapers() }
        // Opened by you (Finder, Spotlight, Launchpad) rather than at login: show the settings window.
        if !CommandLine.arguments.contains("--background") { openSettings() }
    }

    /// Opening the app again while it's running (it has no Dock icon) shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: ambient wallpapers

    var wallpaperDir: URL { dir.appendingPathComponent("Wallpapers") }
    var originalWallpaperURL: URL { dir.appendingPathComponent("original-wallpapers.json") }

    func wallpapers() -> [URL] {
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic"]
        return ((try? FileManager.default.contentsOfDirectory(at: wallpaperDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    }

    func startWallpapers() {
        // remember each screen's own wallpaper once, so turning rotation off puts it back
        if !FileManager.default.fileExists(atPath: originalWallpaperURL.path) {
            var orig: [String: String] = [:]
            for sc in NSScreen.screens {
                if let u = NSWorkspace.shared.desktopImageURL(for: sc), !u.path.hasPrefix(wallpaperDir.path) {
                    orig[sc.localizedName] = u.path
                }
            }
            try? JSONEncoder().encode(orig).write(to: originalWallpaperURL)
        }
        let list = wallpapers()
        if !list.isEmpty { wallpaperIndex = Int.random(in: 0..<list.count) }
        nextWallpaper()
        wallpaperTimer?.invalidate()
        let mins = Double(max(1, settings.wallpaperMinutes ?? 60))
        wallpaperTimer = Timer.scheduledTimer(withTimeInterval: mins * 60, repeats: true) { [weak self] _ in self?.nextWallpaper() }
    }

    func nextWallpaper() {
        let list = wallpapers()
        guard !list.isEmpty else { return }
        wallpaperIndex = (wallpaperIndex + 1) % list.count
        for sc in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(list[wallpaperIndex], for: sc,
                options: [.imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue), .allowClipping: true])
        }
    }

    func stopWallpapers() {
        wallpaperTimer?.invalidate(); wallpaperTimer = nil
        if let data = try? Data(contentsOf: originalWallpaperURL),
           let orig = try? JSONDecoder().decode([String: String].self, from: data) {
            for sc in NSScreen.screens {
                if let p = orig[sc.localizedName] ?? orig.values.first {
                    try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: p), for: sc, options: [:])
                }
            }
            try? FileManager.default.removeItem(at: originalWallpaperURL)
        }
    }

    @objc func toggleWallpapers() {
        var s = loadSettings()
        s.ambientWallpapers = !(s.ambientWallpapers ?? true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(s).write(to: settingsURL)
        settings = s
        if s.ambientWallpapers == true { startWallpapers() } else { stopWallpapers() }
        render(focusUntil)
    }

    @objc func skipWallpaper() { nextWallpaper() }

    func applicationWillTerminate(_ n: Notification) {
        if settings.ambientWallpapers ?? true { stopWallpapers() }   // quitting puts your own wallpaper back
    }

    func start(minutes: Double) {
        let current = focusUntil?.timeIntervalSince1970 ?? 0
        let end = max(current, Date().timeIntervalSince1970 + minutes * 60)   // starting again can only extend
        saveState(SessionState(focusUntil: end, blockedSites: settings.blockedSites))
        tick()
    }

    @objc func appLaunched(_ n: Notification) {
        guard focusUntil != nil, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        block(app)
    }

    func block(_ app: NSRunningApplication) {
        let path = app.executableURL?.path ?? ""
        let byPath = (settings.blockedPaths ?? []).contains { path.contains($0) }
        guard byPath || app.bundleIdentifier.map(settings.blockedApps.contains) == true else { return }
        let id = app.bundleIdentifier ?? path
        if !app.terminate() { app.forceTerminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if !app.isTerminated { app.forceTerminate() } }
        NSLog("FocusLock: closed \(id)")
    }

    func tick() {
        settings = loadSettings()
        let until = focusUntil
        if let until {
            NSWorkspace.shared.runningApplications.forEach(block)
            // keep the helper's copy of the site list and end time current (schedule sessions included)
            if loadState()?.focusUntil ?? 0 < until.timeIntervalSince1970 || loadState()?.blockedSites != settings.blockedSites {
                saveState(SessionState(focusUntil: until.timeIntervalSince1970, blockedSites: settings.blockedSites))
            }
        }
        render(until)
    }

    func render(_ until: Date?) {
        let left = until.map { max(0, Int(ceil($0.timeIntervalSinceNow / 60))) }
        if let b = item.button {
            b.image = NSImage(systemSymbolName: until == nil ? "lock.open" : "lock.fill", accessibilityDescription: "Focus Lock")
            b.title = left.map { " \($0 >= 60 ? "\($0 / 60)h \($0 % 60)m" : "\($0)m")" } ?? ""
        }
        let menu = NSMenu()
        if let until {
            let f = DateFormatter(); f.timeStyle = .short
            menu.addItem(withTitle: "Locked in until \(f.string(from: until))", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Blocking \(settings.blockedApps.count) apps, \(settings.blockedSites.count) sites", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Add time:", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Not focusing", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Start focus (can't be stopped early):", action: nil, keyEquivalent: "")
        }
        for (title, mins) in [("25 minutes", 25.0), ("50 minutes", 50.0), ("90 minutes", 90.0), ("2 hours", 120.0)] {
            let mi = NSMenuItem(title: "   " + title, action: #selector(startFromMenu(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = mins
            menu.addItem(mi)
        }
        if !helperInstalled {
            menu.addItem(.separator())
            menu.addItem(withTitle: "⚠︎ Websites aren't blocked: run install.sh", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        let sched = settings.schedule.isEmpty ? "Focus hours: none set" :
            "Focus hours: " + settings.schedule.map { "\(dayNames($0.days)) \(clock($0.start))–\(clock($0.end))" }.joined(separator: ", ")
        menu.addItem(withTitle: sched, action: nil, keyEquivalent: "")
        let wp = NSMenuItem(title: "Ambient focus wallpapers", action: #selector(toggleWallpapers), keyEquivalent: "")
        wp.target = self; wp.state = (settings.ambientWallpapers ?? true) ? .on : .off
        menu.addItem(wp)
        if settings.ambientWallpapers ?? true {
            let nx = NSMenuItem(title: "   Next wallpaper", action: #selector(skipWallpaper), keyEquivalent: "")
            nx.target = self
            menu.addItem(nx)
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Settings: focus hours, apps and sites…", action: #selector(openSettings), keyEquivalent: ",")
        edit.target = self
        menu.addItem(edit)
        if until == nil {                       // no quitting while locked in
            menu.addItem(.separator())
            let q = NSMenuItem(title: "Quit Focus Lock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(q)
        }
        item.menu = menu
    }

    /// "16:30" -> "4:30 PM" in the Mac's own clock style
    func clock(_ hhmm: String) -> String {
        guard let m = minutesOf(hhmm), let d = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) else { return hhmm }
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: d)
    }

    func dayNames(_ d: [Int]) -> String {
        let s = Set(d)
        if s == Set(2...6) { return "Weekdays" }
        if s == Set(1...7) { return "Every day" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return d.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: "/")
    }

    @objc func startFromMenu(_ sender: NSMenuItem) {
        guard let mins = sender.representedObject as? Double else { return }
        let a = NSAlert()
        a.messageText = focusUntil == nil ? "Lock in for \(sender.title.trimmingCharacters(in: .whitespaces))?" :
                                            "Add \(sender.title.trimmingCharacters(in: .whitespaces))?"
        a.informativeText = "Blocked apps will close and blocked sites won't load. You can't stop it early."
        a.addButton(withTitle: "Lock in"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { start(minutes: mins) }
    }

    let settingsWindow = SettingsWindow()

    @objc func openSettings() {
        settingsWindow.show(lockedUntil: focusUntil) { [weak self] in self?.tick() }
    }
}

let app = NSApplication.shared
let delegate = FocusLock()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
