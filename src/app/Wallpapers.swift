// Ambient focus wallpapers: rotates the photos in ~/Library/Application Support/FocusLock/Wallpapers
// on every screen. Shared by the menu (main.swift) and the Wallpapers section of the settings window.
import AppKit
import ImageIO

enum WallpaperKind: String, CaseIterable, Identifiable {
    case all = "All", nature = "Night sky & nature", city = "Cities", mine = "Your photos"
    var id: String { rawValue }

    static func of(_ u: URL) -> WallpaperKind {
        let n = u.lastPathComponent.lowercased()
        if n.hasPrefix("my-") { return .mine }
        if n.contains("-city-") || n.contains("-nyc-") { return .city }
        return .nature
    }
}

/// How often the wallpaper changes, in minutes, with the label shown in Settings.
let wallpaperIntervals: [(minutes: Int, label: String)] =
    [(15, "Every 15 minutes"), (30, "Every 30 minutes"), (60, "Every hour"), (120, "Every 2 hours"), (240, "Every 4 hours"), (1440, "Once a day")]

final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()

    @Published private(set) var all: [URL] = []
    @Published private(set) var current: URL?
    @Published private(set) var nextChange: Date?
    private var timer: Timer?
    private var history: [URL] = []           // shown so far, for Previous
    private var thumbs: [URL: NSImage] = [:]

    var folder: URL { dir.appendingPathComponent("Wallpapers") }
    private var originalURL: URL { dir.appendingPathComponent("original-wallpapers.json") }
    private var settings: Settings { loadSettings() }
    var isOn: Bool { settings.ambientWallpapers ?? true }

    /// The photos in the rotation (unticked ones left out; if you untick everything, all of them).
    var enabled: [URL] {
        let off = Set(settings.wallpaperOff ?? [])
        let e = all.filter { !off.contains($0.lastPathComponent) }
        return e.isEmpty ? all : e
    }

    func refresh() {
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic"]
        all = ((try? FileManager.default.contentsOfDirectory(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let showing = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }?.resolvingSymlinksInPath().path
        current = all.first { $0.resolvingSymlinksInPath().path == showing }
    }

    // MARK: on / off

    func start() {
        // Remember each screen's own wallpaper once, so turning rotation off puts it back.
        if !FileManager.default.fileExists(atPath: originalURL.path) {
            var orig: [String: String] = [:]
            for sc in NSScreen.screens {
                if let u = NSWorkspace.shared.desktopImageURL(for: sc), !u.path.hasPrefix(folder.path) { orig[sc.localizedName] = u.path }
            }
            try? JSONEncoder().encode(orig).write(to: originalURL)
        }
        refresh()
        // Keep the photo that's showing if it's one of ours (relaunching shouldn't change it).
        if let c = current, enabled.contains(c) { history = [c]; schedule() } else { next() }
    }

    func stop() {
        timer?.invalidate(); timer = nil; nextChange = nil
        if let data = try? Data(contentsOf: originalURL), let orig = try? JSONDecoder().decode([String: String].self, from: data) {
            for sc in NSScreen.screens {
                if let p = orig[sc.localizedName] ?? orig.values.first {
                    try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: p), for: sc, options: [:])
                }
            }
            try? FileManager.default.removeItem(at: originalURL)
        }
        current = nil
    }

    /// Call after any wallpaper setting changes.
    func apply() {
        refresh()
        guard isOn else { stop(); return }
        if timer == nil { start(); return }
        if let c = current, !enabled.contains(c) { next() } else { schedule() }
    }

    // MARK: changing the picture

    func show(_ u: URL) {
        for sc in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(u, for: sc,
                options: [.imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue), .allowClipping: true])
        }
        current = u
        if history.last != u { history.append(u); if history.count > 50 { history.removeFirst() } }
        schedule()                                          // a manual pick gets a full interval
    }

    func next() {
        refresh()
        let e = enabled
        guard !e.isEmpty else { return }
        if settings.wallpaperShuffle ?? true {
            // random, but not one of the last few shown
            let recent = Set(history.suffix(min(e.count - 1, max(0, e.count / 2))))
            let pool = e.filter { $0 != current && !recent.contains($0) }
            show((pool.isEmpty ? e.filter { $0 != current } : pool).randomElement() ?? e[0])
        } else {
            let i = current.flatMap { e.firstIndex(of: $0) } ?? -1
            show(e[(i + 1) % e.count])
        }
    }

    func previous() {
        refresh()
        if history.count >= 2 {
            history.removeLast()
            let u = history.removeLast()
            if all.contains(u) { show(u); return }
        }
        let e = enabled
        guard !e.isEmpty else { return }
        let i = current.flatMap { e.firstIndex(of: $0) } ?? 0
        show(e[(i - 1 + e.count) % e.count])
    }

    private func schedule() {
        timer?.invalidate()
        guard isOn else { timer = nil; nextChange = nil; return }
        let secs = Double(max(1, settings.wallpaperMinutes ?? 60)) * 60
        nextChange = Date().addingTimeInterval(secs)
        timer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in self?.next() }
    }

    // MARK: your own photos

    /// Copies the picked images into the wallpaper folder as my-<name>; returns how many were added.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var n = 0
        for u in urls {
            var dest = folder.appendingPathComponent("my-" + u.lastPathComponent)
            var k = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = folder.appendingPathComponent("my-\(u.deletingPathExtension().lastPathComponent)-\(k).\(u.pathExtension)"); k += 1
            }
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { n += 1 }
        }
        refresh()
        return n
    }

    /// Moves one of your own photos to the Trash (the included photos can only be left out).
    func trash(_ u: URL) {
        guard WallpaperKind.of(u) == .mine else { return }
        let wasShowing = u == current
        try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
        history.removeAll { $0 == u }
        refresh()
        if wasShowing && isOn { next() }
    }

    func thumbnail(_ u: URL) -> NSImage? {
        if let t = thumbs[u] { return t }
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 320,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs[u] = img
        return img
    }

    /// "Night sky over a lake" style name from a file name like "03-Pedra-Azul-Milky-Way.jpg".
    static func title(_ u: URL) -> String {
        var s = u.deletingPathExtension().lastPathComponent
        for p in ["my-", "city-", "nyc-"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if let r = s.range(of: #"^\d+-(city-|nyc-)?"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }
}
