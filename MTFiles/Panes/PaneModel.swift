import Foundation
import SwiftUI

@MainActor
final class PaneModel: ObservableObject, Identifiable {
    let id: Int
    @Published private(set) var dir: URL
    @Published private(set) var entries: [FileEntry] = []
    @Published var selection: Set<URL> = []
    @Published var selecting = false
    @Published var filter = ""
    @Published var error: String?
    @Published var sortKey: SortKey { didSet { saveSort(); resort() } }
    @Published var ascending: Bool { didSet { saveSort(); resort() } }
    @Published var foldersFirst: Bool { didSet { saveSort(); resort() } }
    @Published var showHidden: Bool { didSet { saveSort(); reload() } }

    private var raw: [FileEntry] = []
    private var back: [URL] = []

    init(id: Int, dir: URL) {
        self.id = id
        let d = UserDefaults.standard
        self.dir = dir
        self.sortKey = SortKey(rawValue: d.string(forKey: "pane\(id)_sort") ?? "") ?? .name
        self.ascending = d.object(forKey: "pane\(id)_asc") as? Bool ?? true
        self.foldersFirst = d.object(forKey: "pane\(id)_ff") as? Bool ?? true
        self.showHidden = d.bool(forKey: "pane\(id)_hidden")
        reload()
    }

    private func saveSort() {
        let d = UserDefaults.standard
        d.set(sortKey.rawValue, forKey: "pane\(id)_sort")
        d.set(ascending, forKey: "pane\(id)_asc")
        d.set(foldersFirst, forKey: "pane\(id)_ff")
        d.set(showHidden, forKey: "pane\(id)_hidden")
    }

    var visible: [FileEntry] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return entries }
        let m = FileOps.matcher(f)
        return entries.filter { m($0.name) }
    }

    var selectedURLs: [URL] {
        entries.map(\.url).filter { selection.contains($0) }
    }

    var canGoBack: Bool { !back.isEmpty }

    func reload() {
        do {
            raw = try FileOps.list(dir, showHidden: showHidden)
            error = nil
        } catch {
            raw = []
            self.error = error.localizedDescription
        }
        resort()
        selection = selection.filter { u in raw.contains { $0.url == u } }
    }

    private func resort() {
        entries = FileOps.sort(raw, by: sortKey, ascending: ascending, foldersFirst: foldersFirst)
    }

    func go(_ url: URL, remember: Bool = true) {
        guard url.standardizedFileURL != dir.standardizedFileURL else { reload(); return }
        if remember { back.append(dir); if back.count > 50 { back.removeFirst() } }
        dir = url
        selection.removeAll()
        selecting = false
        filter = ""
        reload()
    }

    func goBack() {
        guard let last = back.popLast() else { return }
        go(last, remember: false)
    }

    func up(root: URL?) {
        if let root, dir.standardizedFileURL.path == root.standardizedFileURL.path { return }
        go(dir.deletingLastPathComponent())
    }

    func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    func selectAll() { selection = Set(visible.map(\.url)) }
}

struct OpenRequest: Identifiable {
    let id = UUID()
    let url: URL
    var mode: ViewerMode = .auto
}

enum ViewerMode: String {
    case auto, text, hex, quicklook, archive, plistKeys
}

@MainActor
final class AppModel: ObservableObject {
    let left: PaneModel
    let right: PaneModel
    @Published var active = 0
    @Published var busy: String?
    @Published var error: String?
    @Published var toast: String?
    @Published var open: OpenRequest?
    @Published var assistantContext: AIContext?
    @Published var tab = 0
    @Published var pick: PickRequest?

    init() {
        let docs = LocationStore.documents
        left = PaneModel(id: 0, dir: docs)
        let rightStart = docs.appendingPathComponent("Projects")
        right = PaneModel(id: 1, dir: FileManager.default.fileExists(atPath: rightStart.path) ? rightStart : docs)
    }

    var activePane: PaneModel { active == 0 ? left : right }
    var otherPane: PaneModel { active == 0 ? right : left }
    func pane(_ i: Int) -> PaneModel { i == 0 ? left : right }
    func other(of i: Int) -> PaneModel { i == 0 ? right : left }

    func reloadAll() {
        left.reload()
        right.reload()
    }

    func show(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.toast == message { self.toast = nil }
        }
    }

    /// Runs a file operation off the main thread with a busy overlay, then reloads both panes.
    func run(_ label: String, _ work: @escaping @Sendable () throws -> String?) {
        busy = label
        Task {
            let result: Result<String?, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try work()) } catch { return .failure(error) }
            }.value
            busy = nil
            reloadAll()
            switch result {
            case .success(let msg): if let msg { show(msg) }
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    func transfer(from i: Int, move: Bool) {
        let src = pane(i)
        let dst = other(of: i)
        let items = src.selectedURLs
        guard !items.isEmpty else { return }
        let target = dst.dir
        src.selection.removeAll()
        src.selecting = false
        run(move ? "Moving \(items.count) item(s)…" : "Copying \(items.count) item(s)…") {
            if move { try FileOps.move(items, to: target) } else { try FileOps.copy(items, to: target) }
            return "\(move ? "Moved" : "Copied") \(items.count) item(s) to \(target.lastPathComponent)"
        }
    }

    func context(for i: Int, file: URL? = nil) -> AIContext {
        let p = pane(i)
        var c = AIContext(directory: p.dir)
        c.selected = file.map { [$0] } ?? p.selectedURLs
        c.otherDirectory = other(of: i).dir
        c.listing = p.entries.prefix(80).map { $0.isDirectory ? $0.name + "/" : $0.name }
        return c
    }

    /// Files shared to MT Files ("Open in…") are copied into Documents/Inbox and opened.
    func receive(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let inbox = LocationStore.documents.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        if FileOps.isInside(url, LocationStore.documents) {
            left.go(url.deletingLastPathComponent())
            open = OpenRequest(url: url)
            return
        }
        do {
            let dest = FileOps.uniqueURL(url.lastPathComponent, in: inbox)
            try FilePicking.coordinatedCopy(url, to: dest)
            tab = 0
            active = 0
            left.go(inbox)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), !isDir.boolValue {
                open = OpenRequest(url: dest)
            }
        } catch {
            self.error = "Couldn't receive \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

extension AppModel {
    /// Shows a file in the active pane (closing any open viewer) or opens a folder.
    func reveal(_ url: URL) {
        open = nil
        assistantContext = nil
        tab = 0
        let p = activePane
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            p.go(url)
        } else {
            p.go(url.deletingLastPathComponent())
            p.selecting = true
            p.selection = [url]
        }
    }
}

// MARK: Picking from the Files app

extension AppModel {
    /// Import (copy) any files or packages into the pane's folder.
    func importFiles(into pane: PaneModel) {
        pick = PickRequest(mode: .importCopy) { [weak self] urls in
            self?.copyPicked(urls, into: pane.dir)
        }
    }

    func copyPicked(_ urls: [URL], into dir: URL) {
        guard !urls.isEmpty else { return }
        run("Importing \(urls.count) item(s)…") {
            var failures: [String] = []
            for u in urls {
                do { try FilePicking.coordinatedCopy(u, to: FileOps.uniqueURL(u.lastPathComponent, in: dir)) }
                catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty { throw PlainError(failures.joined(separator: "\n")) }
            return "Imported \(urls.count) item(s) into \(dir.lastPathComponent)"
        }
    }

    /// Open files (or folders) where they are, without copying. Access is remembered via bookmarks.
    func openInPlace(places: LocationStore, pane: PaneModel) {
        pick = PickRequest(mode: .openInPlace) { [weak self] urls in
            guard let self else { return }
            var firstFile: URL?
            for u in urls {
                _ = u.startAccessingSecurityScopedResource() // kept open for this session
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else {
                    self.error = "“\(u.lastPathComponent)” isn't available. If it's in iCloud, download it in the Files app first, or use Import (copy)."
                    continue
                }
                if isDir.boolValue {
                    do { let p = try places.addExternalFolder(u); pane.go(p.url) } catch { self.error = error.localizedDescription }
                } else {
                    places.addOpenedFile(u)
                    if firstFile == nil { firstFile = u }
                }
            }
            if urls.count > 1 { self.show("Opened \(urls.count) items in place — they're in ⭐ Favorites") }
            if let f = firstFile { self.open = OpenRequest(url: f) }
        }
    }

    /// Pick a folder from the Files app and keep access to it.
    func openFolder(places: LocationStore, pane: PaneModel) {
        pick = PickRequest(mode: .folder) { [weak self] urls in
            for u in urls {
                do {
                    let p = try places.addExternalFolder(u)
                    pane.go(p.url)
                    self?.show("Added “\(p.name)” to Locations")
                } catch {
                    self?.error = "Couldn't open that folder: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Downloads a file from a link into the active pane.
    func download(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            error = "That isn't a valid http(s) link."
            return
        }
        let dir = activePane.dir
        busy = "Downloading \(url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent)…"
        Task {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw PlainError("Server returned HTTP \(http.statusCode)")
                }
                var name = resp.suggestedFilename ?? url.lastPathComponent
                if name.isEmpty { name = "download" }
                let dest = FileOps.uniqueURL(name, in: dir)
                try FileManager.default.moveItem(at: tmp, to: dest)
                busy = nil
                reloadAll()
                show("Downloaded \(dest.lastPathComponent)")
                open = OpenRequest(url: dest)
            } catch {
                busy = nil
                self.error = "Download failed: \(error.localizedDescription)"
            }
        }
    }
}
