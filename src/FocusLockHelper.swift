// Focus Lock helper. Runs as root (a LaunchDaemon) and enforces a focus session even if the
// menu-bar app is quit, killed or deleted:
//   - blocks the session's sites in /etc/hosts, which every browser uses
//   - closes blocked apps (and the Minecraft game, which runs as a Java process)
//   - keeps its own end time in a root-owned file that only ever moves later
// The app asks for a session by writing ~/Library/Application Support/FocusLock/state.json.
//
//   focuslock-helper --user-dir "<home>/Library/Application Support/FocusLock" [--once]
//
// For tests: FOCUSLOCK_SYSDIR and FOCUSLOCK_HOSTS point it at scratch files (and skip the DNS flush).
import Foundation

let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
guard let ui = args.firstIndex(of: "--user-dir"), ui + 1 < args.count else {
    FileHandle.standardError.write("usage: focuslock-helper --user-dir DIR [--once]\n".data(using: .utf8)!)
    exit(2)
}
let userDir = URL(fileURLWithPath: args[ui + 1])
let sysDir = URL(fileURLWithPath: env["FOCUSLOCK_SYSDIR"] ?? "/Library/Application Support/FocusLock")
let hostsPath = env["FOCUSLOCK_HOSTS"] ?? "/etc/hosts"
let testing = env["FOCUSLOCK_HOSTS"] != nil
let once = args.contains("--once")

let lockURL = sysDir.appendingPathComponent("lock-until")
let blockedURL = sysDir.appendingPathComponent("blocked.json")
/// A typo in state.json can't lock the Mac for longer than this.
let maxSession: Double = 24 * 3600

struct State: Decodable { var focusUntil: Double; var blockedSites: [String] }
struct UserSettings: Decodable { var blockedApps: [String]; var blockedPaths: [String]? }
/// What this session blocks. Only grows during a session, so editing the user's files can't unblock anything.
struct Blocked: Codable, Equatable { var sites: [String]; var apps: [String]; var paths: [String] }

let defaultPaths = ["/Library/Application Support/minecraft/"]
let BEGIN = "# >>> Focus Lock: added during a focus session, removed when it ends >>>"
let END = "# <<< Focus Lock <<<"

func read<T: Decodable>(_ t: T.Type, _ u: URL) -> T? {
    guard let d = try? Data(contentsOf: u) else { return nil }
    return try? JSONDecoder().decode(t, from: d)
}

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date())) \(s)"); fflush(stdout)
}

/// "https://www.TikTok.com/foryou" -> "tiktok.com"
func domain(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
    s = String(s.split(separator: "/").first ?? "")
    if s.hasPrefix("www.") { s.removeFirst(4) }
    return s.contains(".") && s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) ? s : nil
}

// MARK: - /etc/hosts

func withoutBlock(_ text: String) -> String {
    var out: [Substring] = []
    var inside = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line == BEGIN { inside = true; continue }
        if line == END { inside = false; continue }
        if !inside { out.append(line) }
    }
    return out.joined(separator: "\n")
}

func setHosts(_ sites: [String]) {
    guard let current = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return }
    var base = withoutBlock(current)
    if !sites.isEmpty {
        while base.hasSuffix("\n") { base.removeLast() }
        var lines = [BEGIN]
        for s in sites {
            for host in [s, "www." + s, "m." + s] { lines.append("0.0.0.0 \(host)"); lines.append(":: \(host)") }
        }
        lines.append(END)
        base += "\n" + lines.joined(separator: "\n") + "\n"
    }
    guard base != current else { return }
    do {
        try base.write(toFile: hostsPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hostsPath)
        log(sites.isEmpty ? "unblocked sites" : "blocking \(sites.count) sites")
        flushDNS()
    } catch { log("couldn't write \(hostsPath): \(error)") }
}

func run(_ path: String, _ arguments: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func flushDNS() {
    if testing { return }
    _ = run("/usr/bin/dscacheutil", ["-flushcache"])
    _ = run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
}

// MARK: - apps

var bundleIds: [String: String] = [:]   // .app path -> bundle id

func bundleId(_ app: String) -> String? {
    if let id = bundleIds[app] { return id }
    let plist = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
    guard let d = try? Data(contentsOf: plist),
          let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
          let id = p["CFBundleIdentifier"] as? String else { return nil }
    bundleIds[app] = id
    return id
}

/// Kill every process from a blocked app (matched by the outermost .app's bundle id) or under a blocked path.
func closeBlocked(_ b: Blocked) {
    let apps = Set(b.apps)
    for line in run("/bin/ps", ["-axo", "pid=,comm="]).split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]), pid > 1 else { continue }
        let exe = t[t.index(after: sp)...].trimmingCharacters(in: .whitespaces)
        var hit = b.paths.first { exe.contains($0) }
        if hit == nil, let r = exe.range(of: ".app/") {
            let app = String(exe[..<r.lowerBound]) + ".app"
            if let id = bundleId(app), apps.contains(id) { hit = id }
        }
        if let hit, kill(pid, SIGKILL) == 0 { log("closed \(exe) (\(hit))") }
    }
}

// MARK: - the loop

func readLock() -> Double { Double((try? String(contentsOf: lockURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }

func save(_ b: Blocked) {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(b).write(to: blockedURL, options: .atomic)
}

func step() {
    let now = Date().timeIntervalSince1970
    var lock = readLock()
    let state = read(State.self, userDir.appendingPathComponent("state.json"))
    let requested = state.map { min($0.focusUntil, now + maxSession) } ?? 0
    if requested > max(lock, now) {
        lock = requested
        try? FileManager.default.createDirectory(at: sysDir, withIntermediateDirectories: true)
        try? String(lock).write(to: lockURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockURL.path)
        log("locked until \(Date(timeIntervalSince1970: lock))")
    }

    guard lock > now else {
        if FileManager.default.fileExists(atPath: lockURL.path) {
            try? FileManager.default.removeItem(at: lockURL)
            try? FileManager.default.removeItem(at: blockedURL)
            log("session over")
        }
        setHosts([])
        return
    }

    let settings = read(UserSettings.self, userDir.appendingPathComponent("settings.json"))
    let old = read(Blocked.self, blockedURL) ?? Blocked(sites: [], apps: [], paths: [])
    let sites = Set(old.sites).union((state?.blockedSites ?? []).compactMap(domain))
    let apps = Set(old.apps).union(settings?.blockedApps ?? [])
    let paths = Set(old.paths).union(settings?.blockedPaths ?? defaultPaths)
    let now_ = Blocked(sites: sites.sorted(), apps: apps.sorted(), paths: paths.sorted())
    if now_ != old { save(now_) }
    setHosts(now_.sites)
    closeBlocked(now_)
}

if once { step(); exit(0) }
log("started for \(userDir.path)")
while true {
    autoreleasepool { step() }
    Thread.sleep(forTimeInterval: 3)
}
