import Foundation

enum SafetyGuard {
    static let refusal = "I can't help with that. MT Files never cracks apps, unlocks subscriptions or in-app purchases, bypasses licenses or DRM, or decrypts App Store apps. If you want a paid feature for free, I can help you find an open-source alternative instead (try the IPA tab → “find …”)."

    // Narrow on purpose: only cracking / purchase-unlock / license-bypass / app-decryption requests are blocked.
    private static let patterns: [NSRegularExpression] = [
        "\\bcrack(ed|ing|s)?\\W+(the\\W+|this\\W+|an?\\W+)?(app|apk|ipa|software|game|program|license|serial|premium|pro version|subscription)",
        "\\b(app|apk|ipa|software|game)\\W+crack", "\\bkeygen\\b", "\\bwarez\\b",
        "\\bpirat(ed|e|ing)\\W+(app|apk|ipa|software|game)",
        "(unlock|bypass|remove|skip|disable|hack|patch)\\W+(the\\W+)?(premium|pro|vip|subscription|paywall|in.?app.?purchase|iap|licen[cs]e|activation|trial)\\b",
        "\\b(premium|vip|subscription|paywall|licen[cs]e|iap|in.?app.?purchase)\\W+(unlock|bypass|crack|hack|patch)",
        "\\bmod(ded)? (apk|ipa)\\b",
        "decrypt\\W+(the\\W+|this\\W+|an?\\W+)?(app|ipa|binary|app ?store)", "\\bfairplay\\b", "(remove|strip|bypass)\\W+(the\\W+)?drm", "\\bfake (receipt|purchase)"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func isBlocked(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: r) != nil }
    }
}

/// Offline natural-language → file command parser (works without an AI key).
enum CommandParser {
    enum Result {
        case command(FileCommand)
        case reply(String)
        case unknown
    }

    static let help = """
    Offline commands I understand (no AI key needed):
    • zip this folder / zip selected as backup.zip
    • unzip archive.zip
    • find all .json files · find *.png · find files containing TODO
    • rename all jpgs to photo_# (### = 001, 002…)
    • rename notes.txt to todo.txt
    • new folder Assets · new file main.swift
    • copy selected to other pane · move selected to other pane
    • delete selected
    • sha256 of file.zip
    • explain this file (offline summary)
    Add a free Groq/OpenRouter key in Settings for full AI chat, code explanations and edits.
    """

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        var out: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) { out.append(String(text[r])) } else { out.append("") }
        }
        return out
    }

    static func entries(_ ctx: AIContext) -> [URL] {
        guard let d = ctx.directory else { return [] }
        return ((try? FileOps.list(d, showHidden: false)) ?? []).map(\.url)
    }

    /// Items named in the text, or the selection.
    static func mentioned(_ text: String, _ ctx: AIContext) -> [URL] {
        let lower = text.lowercased()
        let named = entries(ctx).filter { lower.contains($0.lastPathComponent.lowercased()) }
        if !named.isEmpty {
            // Prefer the longest names (avoid "a" matching everything)
            let maxLen = named.map { $0.lastPathComponent.count }.max() ?? 0
            return named.filter { $0.lastPathComponent.count >= min(3, maxLen) }
        }
        if !ctx.selected.isEmpty { return ctx.selected }
        if let f = ctx.file { return [f] }
        return []
    }

    static func pattern(for phrase: String) -> String? {
        let p = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        if let g = groups("(\\*[\\w.*?-]*|[\\w-]*\\*[\\w.*?-]*)", p), !g[1].isEmpty { return g[1] }
        if let g = groups("\\.([a-z0-9]{1,8})\\b", p) { return "*." + g[1] }
        let words: [(String, String)] = [
            ("image|photo|picture|pic", "*.png|*.jpg|*.jpeg|*.heic|*.gif|*.webp|*.bmp"),
            ("video|movie", "*.mp4|*.mov|*.m4v|*.mkv|*.webm|*.avi"),
            ("audio|song|music", "*.mp3|*.m4a|*.wav|*.aac|*.flac|*.ogg"),
            ("archive", "*.zip|*.ipa|*.apk|*.rar|*.7z|*.tar|*.gz"),
            ("document|doc", "*.pdf|*.doc|*.docx|*.txt|*.md|*.rtf|*.pages"),
            ("jpg|jpeg", "*.jpg|*.jpeg"),
        ]
        for (k, v) in words where groups("\\b(?:\(k))s?\\b", p) != nil { return v }
        if let g = groups("\\b([a-z0-9]{1,8})s? files?\\b", p), !["all", "the", "my", "these", "those", "text", "find", "search", "show", "list", "any", "of", "for", "some", "new"].contains(g[1]) { return "*." + g[1] }
        if p.contains("text file") { return "*.txt|*.md" }
        return nil
    }

    static func parse(_ raw: String, _ ctx: AIContext) -> Result {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = text.lowercased()
        if SafetyGuard.isBlocked(t) { return .reply(SafetyGuard.refusal) }
        guard let dir = ctx.directory else { return .reply("Open a folder first.") }
        if t.isEmpty || t == "help" || t == "?" { return .reply(help) }

        // ZIP
        if groups("^(?:please\\s+)?(?:zip|compress|archive)\\b", t) != nil {
            var name: String? = groups("(?:as|to|named|called|into)\\s+\"?([\\w .()-]+?\\.zip)\"?\\s*$", text)?[1]
            let items: [URL]
            if t.contains("this folder") || t.contains("everything") || t.contains("all files") || t.contains("whole folder") || t.contains("current folder") {
                items = entries(ctx)
                if name == nil { name = dir.lastPathComponent + ".zip" }
            } else {
                let m = mentioned(text.replacingOccurrences(of: name ?? "\u{0}", with: ""), ctx)
                items = m.isEmpty ? entries(ctx) : m
                if m.isEmpty && name == nil { name = dir.lastPathComponent + ".zip" }
            }
            guard !items.isEmpty else { return .reply("This folder is empty — nothing to zip.") }
            return .command(.zip(items: items, name: name, in: dir))
        }

        // UNZIP
        if groups("^(?:please\\s+)?(?:unzip|extract|decompress|unpack)\\b", t) != nil {
            let archives = mentioned(text, ctx).filter { ArchiveKinds.extractable.contains($0.pathExtension.lowercased()) }
            let all = entries(ctx).filter { ArchiveKinds.extractable.contains($0.pathExtension.lowercased()) }
            let pick = archives.first ?? (all.count == 1 ? all[0] : nil)
            guard let a = pick else { return .reply(all.isEmpty ? "No .zip archives in this folder." : "Which one? " + all.map(\.lastPathComponent).joined(separator: ", ")) }
            let dest = (t.contains("other pane") ? ctx.otherDirectory : nil) ?? dir
            return .command(.unzip(a, into: dest))
        }

        // RENAME
        if let g = groups("^(?:please\\s+)?rename\\s+(.+?)\\s+(?:to|as|into)\\s+\"?([^\"]+?)\"?\\s*$", text) {
            let what = g[1], template = g[2].trimmingCharacters(in: .whitespaces)
            let wl = what.lowercased()
            let exact = entries(ctx).first { $0.lastPathComponent.lowercased() == wl.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            if let exact, !template.contains("#") { return .command(.rename(exact, to: template)) }
            var items: [URL] = []
            if ["selected", "selection", "these", "them", "the selected files", "selected files"].contains(wl) || (wl.contains("selected") && !ctx.selected.isEmpty) {
                items = ctx.selected
            } else if let pat = pattern(for: what) {
                let m = FileOps.matcher(pat)
                items = entries(ctx).filter { m($0.lastPathComponent) && !isDir($0) }
            } else if wl.contains("all") || wl.contains("every") {
                items = entries(ctx).filter { !isDir($0) }
            } else if let only = ctx.selected.first, ctx.selected.count == 1 {
                return .command(.rename(only, to: template))
            }
            guard !items.isEmpty else { return .reply("I couldn't find files matching “\(what)” here.") }
            if items.count == 1 && !template.contains("#") { return .command(.rename(items[0], to: template)) }
            return .command(.batchRename(items: items, template: template))
        }

        // NEW FOLDER / FILE
        if let g = groups("^(?:please\\s+)?(?:new|create|make|add|mkdir)\\s+(?:a\\s+)?(?:new\\s+)?(folder|directory|dir|file)(?:\\s+(?:called|named))?\\s*\"?([^\"]*)\"?\\s*$", text) {
            let isFolder = g[1].lowercased() != "file"
            var name = g[2].trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = isFolder ? "New Folder" : "untitled.txt" }
            return .command(isFolder ? .newFolder(name, in: dir) : .newFile(name, content: "", in: dir))
        }
        if let g = groups("^mkdir\\s+(.+)$", text) { return .command(.newFolder(g[1], in: dir)) }
        if let g = groups("^touch\\s+(.+)$", text) { return .command(.newFile(g[1], content: "", in: dir)) }

        // COPY / MOVE
        if let g = groups("^(?:please\\s+)?(copy|move|cp|mv)\\s+(.+?)\\s+(?:to|into)\\s+(.+)$", text) {
            let isMove = ["move", "mv"].contains(g[1].lowercased())
            let what = g[2], dest = g[3].lowercased()
            var items = mentioned(what, ctx)
            if what.lowercased().contains("selected") || what.lowercased() == "these" || what.lowercased() == "them" { items = ctx.selected }
            if let pat = pattern(for: what), items.isEmpty || what.lowercased().contains("all") {
                let m = FileOps.matcher(pat)
                items = entries(ctx).filter { m($0.lastPathComponent) }
            }
            guard !items.isEmpty else { return .reply("Select the files first (Select in the ⋯ menu), or name them.") }
            var target: URL?
            if dest.contains("other") || dest.contains("right") || dest.contains("left") || dest.contains("pane") { target = ctx.otherDirectory }
            if target == nil {
                target = entries(ctx).first { isDir($0) && dest.contains($0.lastPathComponent.lowercased()) }
            }
            guard let to = target else { return .reply("Where to? Say “to other pane” or the name of a folder here.") }
            return .command(isMove ? .move(items, to: to) : .copy(items, to: to))
        }

        // DELETE
        if groups("^(?:please\\s+)?(?:delete|remove|trash|rm)\\b", t) != nil {
            var items = mentioned(text, ctx)
            if let pat = pattern(for: text), t.contains("all") {
                let m = FileOps.matcher(pat)
                items = entries(ctx).filter { m($0.lastPathComponent) }
            }
            guard !items.isEmpty else { return .reply("Select what to delete first, or name the file.") }
            return .command(.delete(items))
        }

        // HASH
        if groups("\\b(sha-?256|sha-?1|md5|checksum|hash)\\b", t) != nil {
            guard let f = mentioned(text, ctx).first(where: { !isDir($0) }) else { return .reply("Which file? Select one or name it.") }
            return .command(.hash(f))
        }

        // FIND
        if groups("^(?:please\\s+)?(?:find|search|list|show|look for|where)\\b", t) != nil {
            var content: String? = groups("contain(?:s|ing)?\\s+\"?([^\"]+?)\"?\\s*$", text)?[1]
            if content == nil { content = groups("with (?:the )?text\\s+\"?([^\"]+?)\"?\\s*$", text)?[1] }
            var pat = pattern(for: content.map { text.replacingOccurrences(of: $0, with: "") } ?? text)
            if pat == nil, let g = groups("(?:named|called)\\s+\"?([^\"]+?)\"?\\s*$", text) { pat = g[1] }
            if pat == nil, content == nil, let g = groups("^(?:find|search|look for)\\s+(?:for\\s+)?\"?([^\"]+?)\"?\\s*$", text) { pat = g[1] }
            return .command(.find(pattern: pat ?? "*", content: content, root: dir))
        }

        // EXPLAIN (offline)
        if groups("\\b(explain|summari[sz]e|what (is|does)|describe)\\b", t) != nil, let f = ctx.file ?? ctx.selected.first {
            return .reply(offlineSummary(f, ctx))
        }
        return .unknown
    }

    static func isDir(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func offlineSummary(_ url: URL, _ ctx: AIContext) -> String {
        let e = FileEntry(url: url)
        if e.isDirectory {
            let s = FileOps.directoryStats(url)
            return "“\(e.name)” is a folder with \(s.files) files and \(s.folders) subfolders (\(formatBytes(s.size)))."
        }
        guard let text = ctx.fileText ?? FileOps.readText(url, maxBytes: 5_000_000)?.text else {
            return "“\(e.name)” is a binary \(e.ext.uppercased()) file, \(formatBytes(e.size)). Open it in the hex viewer to inspect bytes. (Add an AI key in Settings for deeper explanations.)"
        }
        let lang = CodeLanguage.detect(url)
        let lines = text.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        var out = "Offline summary of “\(e.name)” — \(lang.displayName), \(lines.count) lines (\(nonEmpty) non-empty), \(formatBytes(e.size))."
        let declPattern = "^\\s*(?:public |private |internal |fileprivate |open |static |final |export |async |override )*(?:func|def|function|class|struct|enum|protocol|interface|fn|fun|extension|type)\\s+([A-Za-z_][A-Za-z0-9_]*)"
        if let re = try? NSRegularExpression(pattern: declPattern, options: [.anchorsMatchLines]) {
            let ns = text as NSString
            let names = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(25).map { ns.substring(with: $0.range(at: 1)) }
            if !names.isEmpty { out += "\nDeclares: " + names.joined(separator: ", ") + (names.count == 25 ? "…" : "") }
        }
        if lang == .json, let d = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) {
            if let dict = obj as? [String: Any] { out += "\nJSON object with keys: " + dict.keys.sorted().prefix(20).joined(separator: ", ") }
            else if let arr = obj as? [Any] { out += "\nJSON array with \(arr.count) items." }
        }
        let todos = lines.filter { $0.contains("TODO") || $0.contains("FIXME") }.count
        if todos > 0 { out += "\n\(todos) TODO/FIXME note(s)." }
        out += "\n\nAdd a free AI key in Settings for a real explanation and code edits."
        return out
    }
}
