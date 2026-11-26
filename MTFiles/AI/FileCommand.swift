import Foundation

/// Everything the assistant knows about where the user is.
struct AIContext: Identifiable {
    let id = UUID()
    var directory: URL?
    var selected: [URL] = []
    var otherDirectory: URL?
    var listing: [String] = []
    var file: URL?
    var fileText: String?
    var selection: String?
    var language: String?
    /// Applies edited text to the open editor: (text, replaceSelectionOnly)
    var applyText: ((String, Bool) -> Void)?

    init(directory: URL?) { self.directory = directory }

    var hasEditor: Bool { applyText != nil }

    /// Short description sent to the AI.
    func describe(maxFileChars: Int = 12_000) -> String {
        var parts: [String] = []
        if let d = directory { parts.append("Current folder: \(d.lastPathComponent) (path: \(d.path))") }
        if let o = otherDirectory { parts.append("Other pane folder: \(o.lastPathComponent)") }
        if !listing.isEmpty { parts.append("Folder contents (\(listing.count) shown): " + listing.joined(separator: ", ")) }
        if !selected.isEmpty { parts.append("Selected items: " + selected.map(\.lastPathComponent).joined(separator: ", ")) }
        if let f = file {
            parts.append("Open file: \(f.lastPathComponent)\(language.map { " (\($0))" } ?? "")")
            if let t = fileText {
                let clipped = t.count > maxFileChars ? String(t.prefix(maxFileChars)) + "\n…[truncated, \(t.count) chars total]" : t
                parts.append("File content:\n<<<FILE\n\(clipped)\nFILE>>>")
            }
        }
        if let s = selection, !s.isEmpty {
            let clipped = s.count > 6000 ? String(s.prefix(6000)) + "…" : s
            parts.append("Selected text in editor:\n<<<SEL\n\(clipped)\nSEL>>>")
        }
        return parts.joined(separator: "\n")
    }
}

/// A file operation proposed by the AI or the offline parser. Runs only after the user taps Run.
enum FileCommand: Equatable {
    case zip(items: [URL], name: String?, in: URL)
    case unzip(URL, into: URL)
    case find(pattern: String, content: String?, root: URL)
    case batchRename(items: [URL], template: String)
    case rename(URL, to: String)
    case newFolder(String, in: URL)
    case newFile(String, content: String, in: URL)
    case delete([URL])
    case copy([URL], to: URL)
    case move([URL], to: URL)
    case hash(URL)

    var title: String {
        switch self {
        case .zip(let items, let name, _): return "Zip \(Self.names(items))" + (name.map { " → \($0)" } ?? "")
        case .unzip(let u, let d): return "Extract \(u.lastPathComponent) into \(d.lastPathComponent)"
        case .find(let p, let c, let r): return "Find “\(p)”\(c.map { " containing “\($0)”" } ?? "") in \(r.lastPathComponent) and subfolders"
        case .batchRename(let items, let t): return "Rename \(items.count) item(s) to “\(t)” (# = number)"
        case .rename(let u, let n): return "Rename \(u.lastPathComponent) → \(n)"
        case .newFolder(let n, let d): return "Create folder “\(n)” in \(d.lastPathComponent)"
        case .newFile(let n, let c, let d): return "Create file “\(n)” in \(d.lastPathComponent) (\(c.count) chars)"
        case .delete(let items): return "Delete \(Self.names(items))"
        case .copy(let items, let d): return "Copy \(Self.names(items)) to \(d.lastPathComponent)"
        case .move(let items, let d): return "Move \(Self.names(items)) to \(d.lastPathComponent)"
        case .hash(let u): return "Compute SHA-256 / MD5 of \(u.lastPathComponent)"
        }
    }

    var symbol: String {
        switch self {
        case .zip: return "doc.zipper"
        case .unzip: return "arrow.down.doc"
        case .find: return "magnifyingglass"
        case .batchRename, .rename: return "character.cursor.ibeam"
        case .newFolder: return "folder.badge.plus"
        case .newFile: return "doc.badge.plus"
        case .delete: return "trash"
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        case .hash: return "number.square"
        }
    }

    var destructive: Bool {
        if case .delete = self { return true }
        return false
    }

    var detail: String? {
        switch self {
        case .batchRename(let items, let t):
            let preview = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(4).enumerated().map { pair -> String in
                let i = pair.offset, u = pair.element
                let hashes = max(t.filter { $0 == "#" }.count, 1)
                let num = hashes > 1 ? String(format: "%0\(hashes)d", i + 1) : "\(i + 1)"
                var base = t.contains("#") ? t.replacingOccurrences(of: String(repeating: "#", count: hashes), with: num) : t + "_\(num)"
                if !u.pathExtension.isEmpty && !base.lowercased().hasSuffix("." + u.pathExtension.lowercased()) { base += "." + u.pathExtension }
                return "\(u.lastPathComponent) → \(base)"
            }
            return preview.joined(separator: "\n") + (items.count > 4 ? "\n…" : "")
        case .delete(let items), .copy(let items, _), .move(let items, _), .zip(let items, _, _):
            return items.count > 3 ? items.map(\.lastPathComponent).prefix(8).joined(separator: ", ") + (items.count > 8 ? "…" : "") : nil
        default: return nil
        }
    }

    static func names(_ items: [URL]) -> String {
        if items.count == 1 { return "“\(items[0].lastPathComponent)”" }
        return "\(items.count) items"
    }

    struct Outcome {
        var message: String
        var found: [URL] = []
    }

    func execute() throws -> Outcome {
        switch self {
        case .zip(let items, let name, let dir):
            let z = try FileOps.zip(items, name: name, in: dir)
            return Outcome(message: "Created \(z.lastPathComponent)", found: [z])
        case .unzip(let u, let d):
            let out = try FileOps.unzip(u, into: d)
            return Outcome(message: "Extracted to \(out.lastPathComponent)", found: [out])
        case .find(let p, let c, let r):
            let res = FileOps.search(r, pattern: p, contentQuery: c)
            return Outcome(message: res.isEmpty ? "No matches." : "Found \(res.count)\(res.count >= 500 ? "+" : "") item(s).", found: res)
        case .batchRename(let items, let t):
            let r = try FileOps.batchRename(items, template: t)
            return Outcome(message: "Renamed \(r.count) item(s).", found: r)
        case .rename(let u, let n):
            let r = try FileOps.rename(u, to: n)
            return Outcome(message: "Renamed to \(r.lastPathComponent).", found: [r])
        case .newFolder(let n, let d):
            let r = try FileOps.newFolder(n, in: d)
            return Outcome(message: "Created folder \(r.lastPathComponent).", found: [r])
        case .newFile(let n, let c, let d):
            let r = try FileOps.newFile(n, content: c, in: d)
            return Outcome(message: "Created \(r.lastPathComponent).", found: [r])
        case .delete(let items):
            try FileOps.delete(items)
            return Outcome(message: "Deleted \(items.count) item(s).")
        case .copy(let items, let d):
            let r = try FileOps.copy(items, to: d)
            return Outcome(message: "Copied \(r.count) item(s) to \(d.lastPathComponent).", found: r)
        case .move(let items, let d):
            let r = try FileOps.move(items, to: d)
            return Outcome(message: "Moved \(r.count) item(s) to \(d.lastPathComponent).", found: r)
        case .hash(let u):
            let h = try FileOps.hashes(u)
            return Outcome(message: "\(u.lastPathComponent)\nSHA-256: \(h.sha256)\nSHA-1: \(h.sha1)\nMD5: \(h.md5)")
        }
    }
}

/// A text edit proposed by the AI; shown as a diff and applied only after confirmation.
struct ProposedEdit: Equatable {
    enum Target: Equatable { case selection, wholeFile, newFile(String) }
    let target: Target
    let original: String
    let updated: String
}
