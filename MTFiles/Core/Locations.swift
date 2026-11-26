import Foundation
import SwiftUI

struct Place: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let url: URL
    let removable: Bool
}

private struct StoredBookmark: Codable, Hashable {
    var id: String
    var name: String
    var data: Data
}

/// Root locations (sandbox folders + user-picked folders from Files) and favorites, persisted with bookmarks.
@MainActor
final class LocationStore: ObservableObject {
    @Published private(set) var external: [Place] = []
    @Published private(set) var favorites: [Place] = []

    private var storedExternal: [StoredBookmark] = []
    private var storedFavorites: [StoredBookmark] = []
    private var accessing: [URL] = []
    private let fm = FileManager.default

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    var builtIn: [Place] {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [
            Place(id: "docs", name: "On My iPhone › MT Files", symbol: "iphone", url: LocationStore.documents, removable: false),
            Place(id: "projects", name: "IPA Projects (unpacked)", symbol: "app.badge", url: support.appendingPathComponent("Projects", isDirectory: true), removable: false),
            Place(id: "tmp", name: "Temporary", symbol: "clock.arrow.circlepath", url: fm.temporaryDirectory, removable: false),
            Place(id: "bundle", name: "MT Files app bundle (read-only)", symbol: "shippingbox", url: Bundle.main.bundleURL, removable: false)
        ]
    }

    var allRoots: [Place] { builtIn + external }

    init() {
        try? fm.createDirectory(at: builtIn[1].url, withIntermediateDirectories: true)
        seedDocuments()
        let dec = JSONDecoder()
        if let d = UserDefaults.standard.data(forKey: "mt_external"), let list = try? dec.decode([StoredBookmark].self, from: d) { storedExternal = list }
        if let d = UserDefaults.standard.data(forKey: "mt_favorites"), let list = try? dec.decode([StoredBookmark].self, from: d) { storedFavorites = list }
        resolveAll()
    }

    private func seedDocuments() {
        let docs = LocationStore.documents
        let readme = docs.appendingPathComponent("Welcome to MT Files.md")
        guard !UserDefaults.standard.bool(forKey: "mt_seeded") else { return }
        UserDefaults.standard.set(true, forKey: "mt_seeded")
        try? fm.createDirectory(at: docs.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: docs.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        let text = """
        # Welcome to MT Files

        - Two panes: swipe left/right (or rotate / use iPad) to switch. Select files, then **Copy →** or **Move →** sends them to the other pane.
        - Long-press any file for rename, zip, unzip, info (SHA-256 / MD5), share, favorite and **Ask AI**.
        - Tap **＋ Add folder from Files** in the location menu to work on folders from iCloud Drive or other apps.
        - Open `.ipa` files to edit name, icon, bundle ID and Info.plist, then repack unsigned.
        - The ✨ button opens the AI assistant. Without a key it still understands commands like
          `zip this folder`, `find all .json files`, `rename all jpgs to photo_#`.

        MT Files never unlocks subscriptions or in-app purchases, bypasses licenses, or decrypts apps.
        """
        try? Data(text.utf8).write(to: readme)
        let sample = """
        import Foundation

        // Sample file: try the editor's find/replace, go to line, and Ask AI → Explain.
        struct Greeter {
            let name: String
            func greet(times: Int = 1) -> [String] {
                (1...times).map { "Hello, \\(name) #\\($0)" }
            }
        }

        print(Greeter(name: "MT Files").greet(times: 3))
        """
        try? Data(sample.utf8).write(to: docs.appendingPathComponent("Projects/Sample.swift"))
    }

    private func resolve(_ b: StoredBookmark, startAccess: Bool) -> (URL, Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: b.data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if startAccess, url.startAccessingSecurityScopedResource() { accessing.append(url) }
        let refreshed = stale ? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) : nil
        return (url, refreshed)
    }

    private func resolveAll() {
        for u in accessing { u.stopAccessingSecurityScopedResource() }
        accessing.removeAll()
        var ext: [Place] = []
        for (i, b) in storedExternal.enumerated() {
            guard let r = resolve(b, startAccess: true) else { continue }
            let url = r.0, refreshed = r.1
            if let refreshed { storedExternal[i].data = refreshed }
            ext.append(Place(id: b.id, name: b.name, symbol: "folder.badge.person.crop", url: url, removable: true))
        }
        external = ext
        var favs: [Place] = []
        for (i, b) in storedFavorites.enumerated() {
            guard let r = resolve(b, startAccess: true) else { continue }
            let url = r.0, refreshed = r.1
            if let refreshed { storedFavorites[i].data = refreshed }
            favs.append(Place(id: b.id, name: b.name, symbol: "star.fill", url: url, removable: true))
        }
        favorites = favs
        persist()
    }

    private func persist() {
        let enc = JSONEncoder()
        if let d = try? enc.encode(storedExternal) { UserDefaults.standard.set(d, forKey: "mt_external") }
        if let d = try? enc.encode(storedFavorites) { UserDefaults.standard.set(d, forKey: "mt_favorites") }
    }

    /// Adds a folder picked with the Files folder picker; keeps access across launches.
    @discardableResult
    func addExternalFolder(_ url: URL) throws -> Place {
        let ok = url.startAccessingSecurityScopedResource()
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        if ok { accessing.append(url) }
        let b = StoredBookmark(id: UUID().uuidString, name: url.lastPathComponent, data: data)
        storedExternal.append(b)
        persist()
        let place = Place(id: b.id, name: b.name, symbol: "folder.badge.person.crop", url: url, removable: true)
        external.append(place)
        return place
    }

    func removeExternal(_ p: Place) {
        storedExternal.removeAll { $0.id == p.id }
        external.removeAll { $0.id == p.id }
        persist()
    }

    func isFavorite(_ url: URL) -> Bool {
        favorites.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    func toggleFavorite(_ url: URL) {
        if let f = favorites.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            storedFavorites.removeAll { $0.id == f.id }
            favorites.removeAll { $0.id == f.id }
        } else if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            let b = StoredBookmark(id: UUID().uuidString, name: url.lastPathComponent, data: data)
            storedFavorites.append(b)
            favorites.append(Place(id: b.id, name: b.name, symbol: "star.fill", url: url, removable: true))
        }
        persist()
    }

    /// Remembers a file opened in place (security-scoped) as a favorite so it reopens later.
    func addOpenedFile(_ url: URL) {
        guard !isFavorite(url) else { return }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let b = StoredBookmark(id: UUID().uuidString, name: url.lastPathComponent, data: data)
        storedFavorites.append(b)
        favorites.append(Place(id: b.id, name: b.name, symbol: "star.fill", url: url, removable: true))
        persist()
    }

    /// The root that contains `url` (longest match), used for breadcrumbs and the Up button.
    func root(for url: URL) -> Place? {
        let candidates = allRoots.filter { FileOps.isInside(url, $0.url) }
        return candidates.max { $0.url.path.count < $1.url.path.count }
    }
}
