// The settings window: focus hours (days + start/end times), blocked apps and blocked websites.
// During a focus session you can add blocks but not remove or loosen them; new rows stay editable
// until you close the window.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPage: String, CaseIterable, Identifiable {
    case focus = "Focus", wallpapers = "Wallpapers"
    var id: String { rawValue }
}

final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage = .focus
    @Published var draft: Settings
    @Published var saved: Settings
    @Published var lockedUntil: Date?
    @Published var newSite = ""
    @Published var siteError: String?
    /// Focus hours added since the window opened. They stay editable during a focus session.
    @Published var fresh: Set<UUID> = []
    var onSave: () -> Void = {}

    init() {
        let s = loadSettings()
        draft = s; saved = s
    }

    func reload(lockedUntil: Date?) {
        let s = loadSettings()
        draft = s; saved = s; fresh = []
        newSite = ""; siteError = nil
        self.lockedUntil = lockedUntil
    }

    var locked: Bool { (lockedUntil ?? .distantPast) > Date() }
    var dirty: Bool { draft != saved }
    func canEdit(_ b: ScheduleBlock) -> Bool { !locked || fresh.contains(b.id) }
    func canRemoveApp(_ id: String) -> Bool { !locked || !saved.blockedApps.contains(id) }
    func canRemoveSite(_ s: String) -> Bool { !locked || !saved.blockedSites.contains(s) }

    func problem(_ b: ScheduleBlock) -> String? {
        if b.days.isEmpty { return "Pick at least one day." }
        if minutesOf(b.start) == minutesOf(b.end) { return "Start and end can't be the same time." }
        return nil
    }
    var hasProblems: Bool { draft.schedule.contains { problem($0) != nil } }

    func addBlock() {
        let b = ScheduleBlock(days: Array(2...6), start: "16:00", end: "18:00")   // weekdays after school
        draft.schedule.append(b)
        fresh.insert(b.id)
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Block"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !draft.blockedApps.contains(id), id != "com.focuslock.app" {
                draft.blockedApps.append(id)
            }
        }
    }

    func addSite() {
        var s = newSite.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        s = String(s.split(separator: "/").first ?? "")
        if s.hasPrefix("www.") { s.removeFirst(4) }
        guard s.contains("."), s.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }) else {
            siteError = "Type a website like youtube.com"
            return
        }
        if !draft.blockedSites.contains(s) { draft.blockedSites.append(s) }
        newSite = ""; siteError = nil
    }

    func save() {
        // Focus hours that include right now start a session the moment they're saved.
        let startsNow = draft.schedule.filter { !saved.schedule.contains($0) }.compactMap { blockEnd($0) }.max()
        if let end = startsNow {
            let f = DateFormatter(); f.timeStyle = .short
            let a = NSAlert()
            a.messageText = "These focus hours include right now"
            a.informativeText = "Saving locks you in until \(f.string(from: end)). Blocked apps will close and blocked sites won't load, and you can't stop it early."
            a.addButton(withTitle: "Save and lock in"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        var out = draft
        let disk = loadSettings()                    // wallpaper settings save themselves as you change them
        out.ambientWallpapers = disk.ambientWallpapers; out.wallpaperMinutes = disk.wallpaperMinutes
        out.wallpaperShuffle = disk.wallpaperShuffle; out.wallpaperOff = disk.wallpaperOff
        saveSettings(out)
        draft = out; saved = out
        onSave()
    }

    /// Wallpaper settings apply and save right away (they don't affect blocking, so the lock rules don't apply).
    func setWallpaper(_ change: (inout Settings) -> Void) {
        var disk = loadSettings(); change(&disk); saveSettings(disk)
        change(&draft); change(&saved)
        WallpaperManager.shared.apply()
        onSave()
    }

    func addWallpapers() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Pick photos to add to your focus wallpapers. Darker, calm photos work best."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        WallpaperManager.shared.add(panel.urls)
        WallpaperManager.shared.apply()
    }
}

// MARK: - views

struct SettingsView: View {
    @ObservedObject var m: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: $m.page) {
                ForEach(SettingsPage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.top, 14).padding(.bottom, 4)
            if m.page == .wallpapers {
                ScrollView {
                    WallpaperSection(m: m).padding(24)
                }
            } else {
                focusPage
            }
        }
        .frame(width: 620, height: 700)
    }

    var focusPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if m.locked, let until = m.lockedUntil {
                        Label("Locked in until \(until.formatted(date: .omitted, time: .shortened)). You can add blocks now, but not remove them.",
                              systemImage: "lock.fill")
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    }
                    schedule
                    apps
                    sites
                }
                .padding(24)
            }
            Divider()
            HStack {
                Text(m.dirty ? "You have unsaved changes." : "Saved.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Undo changes") { m.reload(lockedUntil: m.lockedUntil) }.disabled(!m.dirty)
                Button("Save") { m.save() }.keyboardShortcut(.defaultAction).disabled(!m.dirty || m.hasProblems)
            }
            .padding(16)
        }
    }

    var schedule: some View {
        Section {
            if m.draft.schedule.isEmpty {
                Text("No focus hours yet. Add some to lock in automatically, like weekdays 4–6 PM for homework.")
                    .foregroundStyle(.secondary)
            }
            ForEach($m.draft.schedule) { $b in
                BlockRow(block: $b, editable: m.canEdit(b), problem: m.problem(b)) {
                    m.draft.schedule.removeAll { $0.id == b.id }
                }
            }
            Button { m.addBlock() } label: { Label("Add focus hours", systemImage: "plus") }
        } header: {
            header("Focus hours", "Focus Lock turns on by itself at these times, every week.")
        }
    }

    var apps: some View {
        Section {
            ForEach(m.draft.blockedApps, id: \.self) { id in
                HStack(spacing: 10) {
                    AppIcon(bundleId: id)
                    Text(appName(id))
                    Spacer()
                    Button { m.draft.blockedApps.removeAll { $0 == id } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(!m.canRemoveApp(id)).opacity(m.canRemoveApp(id) ? 1 : 0.3)
                        .help("Stop blocking this app")
                }
            }
            Button { m.addApp() } label: { Label("Add an app…", systemImage: "plus") }
        } header: {
            header("Blocked apps", "They close as soon as they open during focus time.")
        }
    }

    var sites: some View {
        Section {
            ForEach(m.draft.blockedSites, id: \.self) { s in
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text(s)
                    Spacer()
                    Button { m.draft.blockedSites.removeAll { $0 == s } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(!m.canRemoveSite(s)).opacity(m.canRemoveSite(s) ? 1 : 0.3)
                        .help("Stop blocking this site")
                }
            }
            HStack {
                TextField("Add a website, like youtube.com", text: $m.newSite).onSubmit { m.addSite() }
                Button("Add") { m.addSite() }.disabled(m.newSite.isEmpty)
            }
            if let e = m.siteError { Text(e).font(.callout).foregroundStyle(.red) }
            if !helperInstalled {
                Text("Website blocking needs the helper: run install.sh once (it asks for your Mac password).")
                    .font(.callout).foregroundStyle(.orange)
            }
        } header: {
            header("Blocked websites", "Blocked in every browser. www. and m. versions are included.")
        }
    }

    func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.bold())
            Text(sub).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    func appName(_ id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return "\(id) (not installed)"
    }
}

struct AppIcon: View {
    let bundleId: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: "app.dashed").frame(width: 22, height: 22)
        }
    }
}

struct BlockRow: View {
    @Binding var block: ScheduleBlock
    let editable: Bool
    let problem: String?
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(zip(1...7, ["S", "M", "T", "W", "T", "F", "S"])), id: \.0) { day, letter in
                    let on = block.days.contains(day)
                    Button {
                        if on { block.days.removeAll { $0 == day } } else { block.days.append(day); block.days.sort() }
                    } label: {
                        Text(letter).font(.callout.bold()).frame(width: 26, height: 26)
                            .background(on ? Color.accentColor : Color.gray.opacity(0.15), in: Circle())
                            .foregroundStyle(on ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(Calendar.current.weekdaySymbols[day - 1])
                }
                Spacer(minLength: 12)
                DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute).labelsHidden()
                Text("to").foregroundStyle(.secondary)
                DatePicker("To", selection: time(\.end), displayedComponents: .hourAndMinute).labelsHidden()
                Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove these focus hours")
            }
            .disabled(!editable)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .opacity(editable ? 1 : 0.75)
    }

    var note: String? {
        var parts: [String] = []
        if let end = blockEnd(block) { parts.append("On right now, until \(end.formatted(date: .omitted, time: .shortened))") }
        if let s = minutesOf(block.start), let e = minutesOf(block.end), e < s { parts.append("Runs past midnight") }
        if !editable { parts.append("Locked until this focus session ends") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A "16:30" string as a Date today, for the time pickers.
    func time(_ key: WritableKeyPath<ScheduleBlock, String>) -> Binding<Date> {
        Binding(
            get: {
                let m = minutesOf(block[keyPath: key]) ?? 0
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                block[keyPath: key] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            })
    }
}

final class SettingsWindow {
    let model = SettingsModel()
    var window: NSWindow?

    func show(lockedUntil: Date?, page: SettingsPage = .focus, onSave: @escaping () -> Void) {
        // Reload from disk unless the window is open with edits in it.
        if window?.isVisible != true { model.reload(lockedUntil: lockedUntil) } else { model.lockedUntil = lockedUntil }
        WallpaperManager.shared.refresh()
        model.page = page
        model.onSave = onSave
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Focus Lock"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(m: model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // For checking the layout without screen-recording permission: FOCUSLOCK_SNAPSHOT=/path/shot.png
        if let path = ProcessInfo.processInfo.environment["FOCUSLOCK_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["FOCUSLOCK_SNAPSHOT_DELAY"] ?? "") ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let v = self?.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

// MARK: - wallpapers

struct WallpaperSection: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject var w = WallpaperManager.shared
    @State private var kind: WallpaperKind = .all
    // FOCUSLOCK_SNAPSHOT_SEARCH="query" opens on search results, for checking the layout
    @State private var finding = ProcessInfo.processInfo.environment["FOCUSLOCK_SNAPSHOT_SEARCH"] != nil

    var on: Bool { m.draft.ambientWallpapers ?? true }
    var off: Set<String> { Set(m.draft.wallpaperOff ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Wallpapers").font(.title3.bold())
                Text("Calm photos that change by themselves. Changes here apply right away.").font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Change my wallpaper to dark focus photos", isOn: Binding(
                get: { on }, set: { v in m.setWallpaper { $0.ambientWallpapers = v } }))
            if on {
                HStack(spacing: 16) {
                    Picker("Change", selection: Binding(
                        get: { m.draft.wallpaperMinutes ?? 60 }, set: { v in m.setWallpaper { $0.wallpaperMinutes = v } })) {
                        ForEach(wallpaperIntervals, id: \.minutes) { Text($0.label).tag($0.minutes) }
                    }
                    .fixedSize()
                    Picker("Order", selection: Binding(
                        get: { m.draft.wallpaperShuffle ?? true }, set: { v in m.setWallpaper { $0.wallpaperShuffle = v } })) {
                        Text("Shuffle").tag(true); Text("In order").tag(false)
                    }
                    .pickerStyle(.segmented).fixedSize()
                }
                HStack {
                    Button { w.previous() } label: { Label("Previous", systemImage: "chevron.left") }
                    Button { w.next() } label: { Label("Next", systemImage: "chevron.right") }
                    Spacer()
                    Button { m.addWallpapers() } label: { Label("Add photos…", systemImage: "plus") }
                    Button { NSWorkspace.shared.open(w.folder) } label: { Image(systemName: "folder") }.help("Show the wallpaper folder in Finder")
                }
                Text(status).font(.callout).foregroundStyle(.secondary)
                Picker("Mode", selection: $finding) {
                    Text("Your wallpapers").tag(false)
                    Text("Search for more photos").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .padding(.top, 6)
                if finding {
                    WallpaperSearchView()
                } else {
                Picker("Show", selection: $kind) {
                    ForEach(WallpaperKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                let shown = w.all.filter { kind == .all || WallpaperKind.of($0) == kind }
                if shown.isEmpty {
                    Text(kind == .mine ? "No photos of your own yet. Search for some, or click Add photos… to use your own files." : "No photos here.")
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                    ForEach(shown, id: \.self) { u in tile(u) }
                }
                Text("Click a photo to show it now. Untick photos to leave them out of the rotation.")
                    .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Your own wallpaper is showing. Turn this on to rotate the focus photos.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var status: String {
        let n = w.all.filter { !off.contains($0.lastPathComponent) }.count
        var parts = ["\(n) of \(w.all.count) photos in the rotation"]
        if let c = w.current { parts.append("showing \(WallpaperManager.title(c))") }
        if let t = w.nextChange { parts.append("next change at \(t.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: " · ")
    }

    func tile(_ u: URL) -> some View {
        let included = !off.contains(u.lastPathComponent)
        let isCurrent = u == w.current
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = w.thumbnail(u) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                    else { Color.gray.opacity(0.2) }
                }
                .frame(height: 80).frame(maxWidth: .infinity).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 3))
                .opacity(included ? 1 : 0.35)
                .contentShape(Rectangle())
                .onTapGesture { w.show(u) }
                Button { toggle(u) } label: {
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(included ? Color.accentColor : .white)
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain).padding(5)
                .help(included ? "Leave out of the rotation" : "Put back in the rotation")
                if isCurrent {
                    Text("Now").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                        .padding(6).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Text(WallpaperManager.title(u)).font(.caption).lineLimit(1).foregroundStyle(included ? .primary : .secondary)
        }
        .contextMenu {
            Button("Show now") { w.show(u) }
            Button(included ? "Leave out of the rotation" : "Put back in the rotation") { toggle(u) }
            if WallpaperKind.of(u) == .mine {
                Button("Move to Trash") { w.trash(u); m.setWallpaper { $0.wallpaperOff?.removeAll { $0 == u.lastPathComponent } } }
            }
        }
    }

    func toggle(_ u: URL) {
        m.setWallpaper { s in
            var o = Set(s.wallpaperOff ?? [])
            if o.contains(u.lastPathComponent) { o.remove(u.lastPathComponent) } else { o.insert(u.lastPathComponent) }
            s.wallpaperOff = o.sorted()
        }
    }
}
