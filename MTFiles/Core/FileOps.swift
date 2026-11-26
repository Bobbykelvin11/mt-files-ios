import CryptoKit
import Foundation
import ZIPFoundation

/// File-system operations. All functions are synchronous and safe to call from a background task.
enum FileOps {
    static var fm: FileManager { FileManager.default }

    static func list(_ dir: URL, showHidden: Bool) throws -> [FileEntry] {
        let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: FileEntry.keys, options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map(FileEntry.init(url:))
    }

    static func sort(_ items: [FileEntry], by key: SortKey, ascending: Bool, foldersFirst: Bool) -> [FileEntry] {
        items.sorted { a, b in
            if foldersFirst, a.isDirectory != b.isDirectory { return a.isDirectory }
            let r: Bool
            switch key {
            case .name: r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified: r = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .size: r = a.size < b.size
            case .type:
                r = a.ext == b.ext ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.ext < b.ext
            }
            return ascending ? r : !r
        }
    }

    /// "name.txt" -> "name 2.txt" if taken.
    static func uniqueURL(_ name: String, in dir: URL) -> URL {
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        repeat {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = dir.appendingPathComponent(n)
            i += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    static func validateName(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n == "." || n == ".." || n.contains("/") || n.contains(":") {
            throw PlainError("“\(name)” isn't a valid file name.")
        }
        return n
    }

    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.resolvingSymlinksInPath().path
        let p = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    @discardableResult
    static func copy(_ items: [URL], to dir: URL) throws -> [URL] {
        var out: [URL] = []
        for src in items {
            if isInside(dir, src) { throw PlainError("Can't copy “\(src.lastPathComponent)” into itself.") }
            let dest = uniqueURL(src.lastPathComponent, in: dir)
            try fm.copyItem(at: src, to: dest)
            out.append(dest)
        }
        return out
    }

    @discardableResult
    static func move(_ items: [URL], to dir: URL) throws -> [URL] {
        var out: [URL] = []
        for src in items {
            if src.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL { out.append(src); continue }
            if isInside(dir, src) { throw PlainError("Can't move “\(src.lastPathComponent)” into itself.") }
            let dest = uniqueURL(src.lastPathComponent, in: dir)
            try fm.moveItem(at: src, to: dest)
            out.append(dest)
        }
        return out
    }

    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let n = try validateName(newName)
        if n == url.lastPathComponent { return url }
        let dest = url.deletingLastPathComponent().appendingPathComponent(n)
        if fm.fileExists(atPath: dest.path), dest.path.lowercased() != url.path.lowercased() {
            throw PlainError("“\(n)” already exists.")
        }
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    static func delete(_ items: [URL]) throws {
        for u in items { try fm.removeItem(at: u) }
    }

    @discardableResult
    static func newFolder(_ name: String, in dir: URL) throws -> URL {
        let n = try validateName(name)
        let dest = uniqueURL(n, in: dir)
        try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        return dest
    }

    @discardableResult
    static func newFile(_ name: String, content: String = "", in dir: URL) throws -> URL {
        let n = try validateName(name)
        let dest = uniqueURL(n, in: dir)
        try Data(content.utf8).write(to: dest)
        return dest
    }

    /// Zips one or more items into `dir`. Returns the archive URL.
    @discardableResult
    static func zip(_ items: [URL], name: String? = nil, in dir: URL) throws -> URL {
        guard !items.isEmpty else { throw PlainError("Nothing to zip.") }
        var zipName = name ?? (items.count == 1 ? items[0].deletingPathExtension().lastPathComponent : "Archive")
        if !zipName.lowercased().hasSuffix(".zip") { zipName += ".zip" }
        let out = uniqueURL(try validateName(zipName), in: dir)
        if items.count == 1 {
            try fm.zipItem(at: items[0], to: out, shouldKeepParent: true, compressionMethod: .deflate)
        } else {
            let staging = fm.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            for i in items { try fm.copyItem(at: i, to: uniqueURL(i.lastPathComponent, in: staging)) }
            try fm.zipItem(at: staging, to: out, shouldKeepParent: false, compressionMethod: .deflate)
        }
        return out
    }

    /// Extracts an archive (.zip, .ipa, .apk, …) into a new folder inside `dir`.
    @discardableResult
    static func unzip(_ url: URL, into dir: URL) throws -> URL {
        let dest = uniqueURL(url.deletingPathExtension().lastPathComponent, in: dir)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            try fm.unzipItem(at: url, to: dest)
        } catch {
            try? fm.removeItem(at: dest)
            throw PlainError("Couldn't extract “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: dest.appendingPathComponent("__MACOSX"))
        return dest
    }

    struct ArchiveItem: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let isDirectory: Bool
        let size: Int64
        let compressed: Int64
    }

    static func archiveContents(_ url: URL, limit: Int = 5000) throws -> [ArchiveItem] {
        guard let archive = Archive(url: url, accessMode: .read) else { throw PlainError("Not a readable zip archive.") }
        var out: [ArchiveItem] = []
        for e in archive {
            out.append(ArchiveItem(path: e.path, isDirectory: e.type == .directory, size: Int64(e.uncompressedSize), compressed: Int64(e.compressedSize)))
            if out.count >= limit { break }
        }
        return out
    }

    static func hashes(_ url: URL) throws -> (sha256: String, md5: String, sha1: String) {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var s256 = SHA256()
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            s256.update(data: chunk)
            md5.update(data: chunk)
            sha1.update(data: chunk)
        }
        func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
        return (hex(s256.finalize()), hex(md5.finalize()), hex(sha1.finalize()))
    }

    static func directoryStats(_ url: URL) -> (size: Int64, files: Int, folders: Int) {
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return (0, 0, 0) }
        var size: Int64 = 0, files = 0, folders = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if v?.isDirectory == true { folders += 1 } else { files += 1; size += Int64(v?.fileSize ?? 0) }
        }
        return (size, files, folders)
    }

    /// Glob ("*.json", "img_??.png") or plain substring match, case-insensitive.
    static func matcher(_ pattern: String) -> (String) -> Bool {
        let parts = pattern.split(whereSeparator: { $0 == "|" || $0 == "," }).map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if parts.count > 1 {
            let ms = parts.map { singleMatcher($0) }
            return { name in ms.contains { $0(name) } }
        }
        return singleMatcher(pattern)
    }

    private static func singleMatcher(_ pattern: String) -> (String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        if p.isEmpty || p == "*" { return { _ in true } }
        if p.contains("*") || p.contains("?") {
            let escaped = NSRegularExpression.escapedPattern(for: p)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            let re = try? NSRegularExpression(pattern: "^" + escaped + "$", options: [.caseInsensitive])
            return { name in
                guard let re else { return false }
                return re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
        }
        if p.hasPrefix(".") { return { $0.lowercased().hasSuffix(p) } }
        return { $0.lowercased().contains(p) }
    }

    static func search(_ root: URL, pattern: String, contentQuery: String? = nil, limit: Int = 500) -> [URL] {
        let match = matcher(pattern)
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return [] }
        var out: [URL] = []
        let needle = contentQuery?.lowercased()
        for case let f as URL in en {
            guard match(f.lastPathComponent) else { continue }
            if let needle, !needle.isEmpty {
                let v = try? f.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if v?.isDirectory == true || (v?.fileSize ?? 0) > 5_000_000 { continue }
                guard let d = try? Data(contentsOf: f), let s = String(data: d, encoding: .utf8), s.lowercased().contains(needle) else { continue }
            }
            out.append(f)
            if out.count >= limit { break }
        }
        return out
    }

    /// Renames `items` using `template`, where `#` is the counter ("photo_#" -> photo_1.jpg, "img_###" -> img_001.jpg).
    @discardableResult
    static func batchRename(_ items: [URL], template: String, start: Int = 1) throws -> [URL] {
        var out: [URL] = []
        let hashes = template.filter { $0 == "#" }.count
        var counter = start
        let sorted = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        // Two phases so names can be swapped without collisions.
        var temp: [(URL, String)] = []
        for u in sorted {
            let num = hashes > 1 ? String(format: "%0\(hashes)d", counter) : "\(counter)"
            var base = template
            if let r = base.range(of: String(repeating: "#", count: max(hashes, 1))) , hashes > 0 {
                base.replaceSubrange(r, with: num)
            } else {
                base += "_\(num)"
            }
            let ext = u.pathExtension
            let final = ext.isEmpty || base.lowercased().hasSuffix("." + ext.lowercased()) ? base : base + "." + ext
            _ = try validateName(final)
            let t = u.deletingLastPathComponent().appendingPathComponent(".mtrename-\(UUID().uuidString)")
            try fm.moveItem(at: u, to: t)
            temp.append((t, final))
            counter += 1
        }
        for (t, final) in temp {
            let dest = uniqueURL(final, in: t.deletingLastPathComponent())
            try fm.moveItem(at: t, to: dest)
            out.append(dest)
        }
        return out
    }

    /// Reads a file as text if it looks like text. Returns nil for binaries.
    static func readText(_ url: URL, maxBytes: Int = 20_000_000) -> (text: String, encoding: String.Encoding)? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        if data.isEmpty { return ("", .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return (s, .utf16) }
        if let s = String(data: data, encoding: .utf8) {
            return looksBinary(data) ? nil : (s, .utf8)
        }
        if looksBinary(data) { return nil }
        if let s = String(data: data, encoding: .isoLatin1) { return (s, .isoLatin1) }
        return nil
    }

    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        if sample.isEmpty { return false }
        var nul = 0, ctrl = 0
        for b in sample {
            if b == 0 { nul += 1 }
            else if b < 9 || (b > 13 && b < 32) { ctrl += 1 }
        }
        return nul > 0 || Double(ctrl) / Double(sample.count) > 0.1
    }

    static func isLikelyText(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = h.readData(ofLength: 8192)
        if d.isEmpty { return true }
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) { return true }
        return !looksBinary(d)
    }
}
