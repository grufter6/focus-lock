// Search free photos (Openverse: Creative Commons, no account or key) and add them to the wallpapers.
// Added photos are cropped to the screen, dimmed if they're bright, saved as my-<title>.jpg in the
// wallpaper folder, and credited in MY-CREDITS.txt next to them.
import AppKit
import SwiftUI

struct PhotoHit: Identifiable, Decodable, Equatable {
    let id: String
    let title: String?
    let creator: String?
    let license: String?
    let license_version: String?
    let foreign_landing_url: String?
    let url: String
    let thumbnail: String?
    let width: Int?
    let height: Int?

    var hd: Bool { (width ?? 0) >= 2400 }
    var licenseName: String {
        switch (license ?? "").lowercased() {
        case "cc0": return "CC0 (public domain)"
        case "pdm": return "Public domain"
        default: return "CC \((license ?? "").uppercased()) \(license_version ?? "")".trimmingCharacters(in: .whitespaces)
        }
    }
    /// Openverse sometimes returns URL-encoded names ("Anders%20Jild%E9n").
    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        if let d = s.removingPercentEncoding { return d }
        // Not valid UTF-8 once decoded (e.g. %E9 for é): decode the bytes as Latin-1 instead.
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "%", let j = s.index(i, offsetBy: 3, limitedBy: s.endIndex), let b = UInt8(s[s.index(after: i)..<j], radix: 16) {
                bytes.append(b); i = j
            } else {
                bytes += Array(String(s[i]).utf8); i = s.index(after: i)
            }
        }
        return String(bytes: bytes, encoding: .isoLatin1) ?? s
    }
    var displayTitle: String { PhotoHit.clean(title) ?? "Untitled" }
    var displayCreator: String { PhotoHit.clean(creator) ?? "unknown" }
}

private struct SearchPage: Decodable { let results: [PhotoHit]; let page_count: Int? }

final class WallpaperSearch: ObservableObject {
    @Published var query = ""
    @Published var wideOnly = true
    @Published private(set) var hits: [PhotoHit] = []
    @Published private(set) var searching = false
    @Published private(set) var message: String?
    @Published private(set) var canLoadMore = false
    @Published private(set) var adding: Set<String> = []
    @Published private(set) var added: Set<String> = []
    @Published private(set) var failed: Set<String> = []
    private var page = 1
    private var lastQuery = ""

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": "FocusLock/1.0 (Mac wallpaper app)"]
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    func search(more: Bool = false) {
        let q = more ? lastQuery : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !searching else { return }
        lastQuery = q
        page = more ? page + 1 : 1
        if !more { hits = []; message = nil }
        searching = true
        Task { @MainActor in
            // Two searches at once: everything, and high-resolution only (rare, and often slower).
            // Show whichever answers first; HD photos go to the top when they arrive.
            var pages = 0, errors: [Error] = []
            await withTaskGroup(of: (Bool, Result<SearchPage, Error>).self) { group in
                group.addTask { (true, await Result(catching: { try await self.fetch(q, size: "large") })) }
                group.addTask { (false, await Result(catching: { try await self.fetch(q, size: nil) })) }
                for await (isHD, result) in group {
                    switch result {
                    case .success(let p):
                        pages = max(pages, p.page_count ?? 1)
                        var seen = Set(hits.map(\.id))
                        let new = p.results.filter { x in
                            guard !seen.contains(x.id), x.url.hasPrefix("https://"), (x.width ?? 0) == 0 || (x.width ?? 0) >= 1000 else { return false }
                            seen.insert(x.id); return true
                        }
                        if isHD && !more { hits.insert(contentsOf: new, at: 0) } else { hits += new }
                    case .failure(let e):
                        if !isHD { errors.append(e) }      // the HD search failing on its own doesn't matter
                    }
                }
            }
            searching = false
            canLoadMore = page < pages
            if hits.isEmpty {
                if let e = errors.first {
                    message = (e as? URLError)?.code == .notConnectedToInternet ? "You're offline." : "Search didn't work: \(e.localizedDescription)"
                } else {
                    message = "No photos found. Try other words, like \"night city\" or \"foggy forest\"."
                }
            }
        }
    }

    private func fetch(_ q: String, size: String?) async throws -> SearchPage {
        var c = URLComponents(string: "https://api.openverse.org/v1/images/")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "page", value: String(page)), .init(name: "page_size", value: "20"),
                        .init(name: "mature", value: "false"), .init(name: "category", value: "photograph"),
                        .init(name: "license_type", value: "modification")]   // we crop and dim, so skip "no derivatives" licences
        if wideOnly { c.queryItems?.append(.init(name: "aspect_ratio", value: "wide")) }
        if let size { c.queryItems?.append(.init(name: "size", value: size)) }
        let (data, resp) = try await Self.session.data(from: c.url!)
        if let r = resp as? HTTPURLResponse, r.statusCode != 200 {
            throw NSError(domain: "Openverse", code: r.statusCode, userInfo: [NSLocalizedDescriptionKey:
                r.statusCode == 429 ? "too many searches, wait a minute" : "the search service answered \(r.statusCode)"])
        }
        return try JSONDecoder().decode(SearchPage.self, from: data)
    }

    /// Downloads the photo, fits it to the screen, saves it into the wallpaper folder and (optionally) shows it.
    func add(_ hit: PhotoHit, showNow: Bool) {
        guard !adding.contains(hit.id), !added.contains(hit.id) else { return }
        adding.insert(hit.id); failed.remove(hit.id)
        Task { @MainActor in
            defer { adding.remove(hit.id) }
            do {
                var data = try await Self.session.data(from: URL(string: hit.url)!).0
                if NSImage(data: data) == nil, let t = hit.thumbnail, let u = URL(string: t) {   // dead original: fall back to the preview
                    data = try await Self.session.data(from: u).0
                }
                guard let img = NSImage(data: data), let file = try WallpaperSearch.save(img, hit: hit) else { throw URLError(.cannotDecodeContentData) }
                added.insert(hit.id)
                let m = WallpaperManager.shared
                m.refresh()
                if showNow { m.show(file) }
            } catch {
                failed.insert(hit.id)
                NSLog("FocusLock: couldn't add \(hit.url): \(error)")
            }
        }
    }

    static func save(_ img: NSImage, hit: PhotoHit) throws -> URL? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // Fill the main screen at full resolution (centre crop), but never upscale past the photo.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let scale = screen.backingScaleFactor
        var W = Int(screen.frame.width * scale), H = Int(screen.frame.height * scale)
        let fill = max(Double(W) / Double(cg.width), Double(H) / Double(cg.height))
        if fill > 1 { W = Int(Double(W) / fill); H = Int(Double(H) / fill) }
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let s = max(Double(W) / Double(cg.width), Double(H) / Double(cg.height))
        let dw = Double(cg.width) * s, dh = Double(cg.height) * s
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: (Double(W) - dw) / 2, y: (Double(H) - dh) / 2, width: dw, height: dh))
        // Dim bright photos so the desktop stays calm (same target as the included set).
        if let mean = meanBrightness(ctx), mean > 62 {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1 - 62 / mean))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        guard let out = ctx.makeImage(),
              let jpg = NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
        let m = WallpaperManager.shared
        let slug = hit.displayTitle.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.prefix(6).joined(separator: "-")
        let file = m.folder.appendingPathComponent("my-\(slug.isEmpty ? "photo" : slug)-\(hit.id.prefix(6)).jpg")
        try FileManager.default.createDirectory(at: m.folder, withIntermediateDirectories: true)
        try jpg.write(to: file)
        let credit = "\(file.lastPathComponent)\n  \(hit.displayTitle) by \(hit.displayCreator) | \(hit.licenseName) | \(hit.foreign_landing_url ?? hit.url)\n"
        let credits = m.folder.appendingPathComponent("MY-CREDITS.txt")
        if let h = try? FileHandle(forWritingTo: credits) { h.seekToEndOfFile(); h.write(credit.data(using: .utf8)!); try? h.close() }
        else { try? ("Credits for photos you added from search (Openverse). Keep this file with them.\n\n" + credit).write(to: credits, atomically: true, encoding: .utf8) }
        return file
    }

    private static func meanBrightness(_ ctx: CGContext) -> Double? {
        guard let img = ctx.makeImage(),
              let small = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 64,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        small.draw(img, in: CGRect(x: 0, y: 0, width: 64, height: 40))
        guard let p = small.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var sum = 0
        for i in 0..<(64 * 40) { sum += Int(p[i]) }
        return Double(sum) / Double(64 * 40)
    }
}

struct WallpaperSearchView: View {
    @StateObject private var s = WallpaperSearch()
    @State private var showNow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search free photos, like night city, foggy forest, aurora", text: $s.query)
                    .textFieldStyle(.roundedBorder).onSubmit { s.search() }
                Button("Search") { s.search() }.keyboardShortcut(.defaultAction).disabled(s.query.isEmpty || s.searching)
            }
            HStack(spacing: 18) {
                Toggle("Wide photos only", isOn: $s.wideOnly).onChange(of: s.wideOnly) { _ in if !s.hits.isEmpty { s.search() } }
                Toggle("Show it as soon as it's added", isOn: $showNow)
            }
            .font(.callout)
            .onAppear {
                if let q = ProcessInfo.processInfo.environment["FOCUSLOCK_SNAPSHOT_SEARCH"], s.hits.isEmpty { s.query = q; s.search() }
            }
            if s.searching && s.hits.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            if let msg = s.message { Text(msg).foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                ForEach(s.hits) { h in tile(h) }
            }
            if s.canLoadMore && !s.hits.isEmpty {
                Button(s.searching ? "Loading…" : "More results") { s.search(more: true) }
                    .disabled(s.searching).frame(maxWidth: .infinity)
            }
            Text("Photos come from Openverse and are free to use under Creative Commons. HD photos look sharpest. Each one is fitted to your screen, dimmed if it's bright, and credited in MY-CREDITS.txt in the wallpaper folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func tile(_ h: PhotoHit) -> some View {
        let isAdded = s.added.contains(h.id), busy = s.adding.contains(h.id), bad = s.failed.contains(h.id)
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: URL(string: h.thumbnail ?? h.url)) { img in img.resizable().aspectRatio(contentMode: .fill) }
                    placeholder: { Color.gray.opacity(0.15) }
                    .frame(height: 104).frame(maxWidth: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button { s.add(h, showNow: showNow) } label: {
                    Group {
                        if busy { ProgressView().controlSize(.small) }
                        else { Text(isAdded ? "✓ Added" : bad ? "Retry" : "+ Add").font(.caption.bold()) }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(isAdded ? Color.green : bad ? Color.orange : Color.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain).padding(6).disabled(isAdded || busy)
                if h.hd {
                    Text("HD").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.black)
                        .padding(6).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Text(h.displayTitle).font(.caption).lineLimit(1)
            Text("by \(h.displayCreator)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(bad ? "Couldn't download this one. Try again or pick another." : "\(h.displayTitle) by \(h.displayCreator) · \(h.licenseName)")
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
