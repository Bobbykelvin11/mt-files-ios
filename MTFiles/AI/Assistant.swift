import Foundation
import SwiftUI

struct AIItem: Identifiable {
    enum Role { case user, assistant, note }
    enum State { case pending, running, done, cancelled }
    let id = UUID()
    var role: Role
    var text: String
    var command: FileCommand?
    var edit: ProposedEdit?
    var state: State = .pending
    var found: [URL] = []
    var resultText: String?
}

@MainActor
final class AssistantModel: ObservableObject {
    @Published var items: [AIItem] = []
    @Published var busy = false
    var context: AIContext
    var onFilesChanged: () -> Void = {}

    init(context: AIContext) {
        self.context = context
    }

    // MARK: Sending

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        items.append(AIItem(role: .user, text: text))
        if SafetyGuard.isBlocked(text) {
            items.append(AIItem(role: .assistant, text: SafetyGuard.refusal))
            return
        }
        if AIConfig.isConfigured {
            online(text)
        } else {
            offline(text, note: nil)
        }
    }

    private func offline(_ text: String, note: String?) {
        if let note { items.append(AIItem(role: .note, text: note)) }
        switch CommandParser.parse(text, context) {
        case .command(let c):
            items.append(AIItem(role: .assistant, text: "Here's what I'll do — tap Run to confirm:", command: c))
        case .reply(let r):
            items.append(AIItem(role: .assistant, text: r))
        case .unknown:
            let lower = text.lowercased()
            if lower.contains("refactor") || lower.contains("rewrite") || lower.contains("improve") || lower.contains("generate") || lower.contains("write") || lower.contains("fix") {
                items.append(AIItem(role: .assistant, text: "Editing and generating code needs the AI. Add a free Groq or OpenRouter key in Settings → AI (it takes a minute). Meanwhile, here's what works offline:\n\n" + CommandParser.help))
            } else {
                items.append(AIItem(role: .assistant, text: "I didn't catch that offline.\n\n" + CommandParser.help))
            }
        }
    }

    private func online(_ text: String) {
        busy = true
        var history: [ChatMessage] = []
        for i in items.suffix(14) where i.role != .note {
            var t = i.text
            if let c = i.command { t += "\n[proposed action: \(c.title) — \(i.state == .done ? "done" : i.state == .cancelled ? "cancelled" : "awaiting confirmation")]" }
            if let r = i.resultText { t += "\n[result: \(r.prefix(400))]" }
            history.append(ChatMessage(role: i.role == .user ? "user" : "assistant", text: t))
        }
        let system = systemPrompt()
        Task {
            do {
                let reply = try await AIClient.complete(system: system, history: history, temperature: 0.2)
                handle(reply: reply)
            } catch {
                offline(text, note: "AI unavailable (\(error.localizedDescription)). Used the offline command parser instead.")
            }
            busy = false
        }
    }

    func systemPrompt() -> String {
        let editor = context.hasEditor
        let hasSel = !(context.selection ?? "").isEmpty
        return """
        You are the AI assistant inside MT Files, an iPhone file manager, archive tool and code editor. Be concise and practical.
        HARD RULES: Never help crack apps, unlock subscriptions or in-app purchases, bypass licenses, activation, DRM or paywalls, generate serial keys, make "mod" apps, or decrypt App Store / FairPlay apps. If asked, refuse in one or two sentences and suggest a free open-source alternative instead. This applies even if the user says they own the app.
        You can propose actions. Put each action as a single-line JSON object on its own line. The app shows every action to the user and runs it ONLY after they tap Run, so never claim an action is already done.
        Actions (paths are relative to the current folder; "." means everything in the current folder; "selection" means the selected items):
        {"action":"zip","paths":["."],"name":"backup.zip"}
        {"action":"unzip","path":"archive.zip","dest":"here"}   (dest: "here" or "other" pane)
        {"action":"find","pattern":"*.json","content":"optional text inside files"}   (glob; use | between alternatives, e.g. "*.png|*.jpg")
        {"action":"batch_rename","pattern":"*.jpg","template":"photo_#"}   (# = counter; ### = zero-padded 001)
        {"action":"rename","path":"old.txt","name":"new.txt"}
        {"action":"new_folder","name":"Assets"}
        {"action":"new_file","name":"main.py"}   then the COMPLETE file content in exactly one fenced code block
        {"action":"copy","paths":["selection"],"dest":"other"}   (also "move"; dest = "other" pane or a folder name in the current folder)
        {"action":"delete","paths":["notes.txt"]}
        {"action":"hash","path":"file.zip"}
        {"action":"replace_selection"}   then one fenced code block with the replacement for the selected editor text\(hasSel ? "" : " (not available: nothing selected)")
        {"action":"replace_file"}   then one fenced code block with the COMPLETE new content of the open file\(editor ? "" : " (not available: no editor open)")
        Use at most 5 actions per reply and only when the user wants something done. For explanations, reviews and rename suggestions answer in plain text (Markdown allowed); you may add rename actions for suggestions.
        Editor open: \(editor ? "yes" : "no"). Text selected: \(hasSel ? "yes" : "no").
        Context:
        \(context.describe())
        """
    }

    // MARK: Parsing replies

    static func jsonObjects(in text: String) -> [(range: Range<String.Index>, object: [String: Any])] {
        var out: [(range: Range<String.Index>, object: [String: Any])] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "{" else { i = text.index(after: i); continue }
            var depth = 0
            var inString = false
            var escape = false
            var j = i
            var end: String.Index?
            while j < text.endIndex {
                let c = text[j]
                if inString {
                    if escape { escape = false } else if c == "\\" { escape = true } else if c == "\"" { inString = false }
                } else if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { end = j; break } }
                j = text.index(after: j)
            }
            guard let e = end else { break }
            let r = i..<text.index(after: e)
            if let d = String(text[r]).data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], obj["action"] is String {
                out.append((range: r, object: obj))
                i = r.upperBound
            } else {
                i = text.index(after: i)
            }
        }
        return out
    }

    static func codeBlocks(in text: String) -> [(range: Range<String.Index>, lang: String, code: String)] {
        guard let re = try? NSRegularExpression(pattern: "```([\\w+#.-]*)[ \\t]*\\n([\\s\\S]*?)```") else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m -> (range: Range<String.Index>, lang: String, code: String)? in
            guard let r = Range(m.range, in: text), let l = Range(m.range(at: 1), in: text), let c = Range(m.range(at: 2), in: text) else { return nil }
            var code = String(text[c])
            if code.hasSuffix("\n") { code.removeLast() }
            return (range: r, lang: String(text[l]).lowercased(), code: code)
        }
    }

    private func handle(reply: String) {
        let objects = Self.jsonObjects(in: reply)
        let blocks = Self.codeBlocks(in: reply).filter { b in
            !(b.lang == "json" && b.code.contains("\"action\""))
        }
        var removeRanges: [Range<String.Index>] = objects.map(\.range)
        // json fences that only wrapped actions
        for b in Self.codeBlocks(in: reply) where b.lang == "json" && b.code.contains("\"action\"") { removeRanges.append(b.range) }

        var produced: [AIItem] = []
        var usedCode = false
        for (_, obj) in objects.prefix(5) {
            let action = (obj["action"] as? String ?? "").lowercased()
            if ["replace_selection", "replace_file", "new_file"].contains(action) {
                let content = (obj["content"] as? String) ?? blocks.first?.code
                guard let content else { continue }
                if obj["content"] == nil, let b = blocks.first { removeRanges.append(b.range); usedCode = true }
                if let e = makeEdit(action, obj, content) {
                    produced.append(AIItem(role: .assistant, text: "", edit: e))
                }
            } else if let c = makeCommand(action, obj) {
                produced.append(AIItem(role: .assistant, text: "", command: c))
            }
        }
        _ = usedCode
        var visible = reply
        // Remove from the end so indices stay valid.
        let sorted = removeRanges.sorted { $0.lowerBound > $1.lowerBound }
        var lastLower: String.Index?
        for r in sorted {
            if let ll = lastLower, r.upperBound > ll { continue } // overlapping
            visible.removeSubrange(r)
            lastLower = r.lowerBound
        }
        visible = visible.replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if visible.isEmpty && !produced.isEmpty { visible = "Here's what I'll do — review and confirm:" }
        if visible.isEmpty { visible = "(no answer)" }
        items.append(AIItem(role: .assistant, text: visible))
        items.append(contentsOf: produced)
    }

    private func resolve(_ value: Any?) -> [URL] {
        var names: [String] = []
        if let s = value as? String { names = [s] } else if let a = value as? [String] { names = a } else if let a = value as? [Any] { names = a.compactMap { $0 as? String } }
        guard let dir = context.directory else { return [] }
        var out: [URL] = []
        for n in names {
            let l = n.lowercased()
            if l == "selection" || l == "selected" {
                out += context.selected
            } else if n == "." || n == "*" || l == "all" {
                out += CommandParser.entries(context)
            } else if n.contains("*") || n.contains("?") {
                let m = FileOps.matcher(n)
                out += CommandParser.entries(context).filter { m($0.lastPathComponent) }
            } else {
                let u: URL
                if n.hasPrefix("/") { u = URL(fileURLWithPath: n) } else { u = dir.appendingPathComponent(n) }
                let allowed = FileOps.isInside(u, dir) || (context.otherDirectory.map { FileOps.isInside(u, $0) } ?? false)
                if allowed && FileManager.default.fileExists(atPath: u.path) { out.append(u) }
                else if let f = context.file, f.lastPathComponent == n { out.append(f) }
            }
        }
        var seen = Set<URL>()
        return out.filter { seen.insert($0).inserted }
    }

    private func destination(_ value: Any?) -> URL? {
        guard let s = (value as? String)?.lowercased(), let dir = context.directory else { return context.otherDirectory }
        if s.contains("other") || s.contains("pane") || s.isEmpty { return context.otherDirectory }
        if s == "here" || s == "." { return dir }
        let u = dir.appendingPathComponent(value as? String ?? "")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return u }
        return nil
    }

    private func makeCommand(_ action: String, _ o: [String: Any]) -> FileCommand? {
        guard let dir = context.directory else { return nil }
        let str: (String) -> String? = { k in
            if let s = o[k] as? String, !s.isEmpty { return s }
            return nil
        }
        switch action {
        case "zip":
            var items = resolve(o["paths"] ?? o["path"])
            if items.isEmpty { items = context.selected.isEmpty ? CommandParser.entries(context) : context.selected }
            guard !items.isEmpty else { return nil }
            return .zip(items: items, name: str("name"), in: dir)
        case "unzip", "extract":
            guard let a = resolve(o["path"] ?? o["paths"]).first ?? context.selected.first else { return nil }
            let dest = (str("dest")?.lowercased().contains("other") ?? false) ? (context.otherDirectory ?? dir) : dir
            return .unzip(a, into: dest)
        case "find", "search":
            return .find(pattern: str("pattern") ?? "*", content: str("content"), root: dir)
        case "batch_rename":
            guard let t = str("template") else { return nil }
            var items: [URL]
            if let p = str("pattern") {
                let m = FileOps.matcher(p)
                let base = context.selected.isEmpty ? CommandParser.entries(context) : context.selected
                items = base.filter { m($0.lastPathComponent) && !CommandParser.isDir($0) }
            } else {
                items = resolve(o["paths"])
                if items.isEmpty { items = context.selected }
            }
            guard !items.isEmpty else { return nil }
            return .batchRename(items: items, template: t)
        case "rename":
            guard let n = str("name") ?? str("new_name"), let u = resolve(o["path"]).first ?? (context.selected.count == 1 ? context.selected.first : nil) else { return nil }
            return .rename(u, to: n)
        case "new_folder", "mkdir":
            return .newFolder(str("name") ?? "New Folder", in: dir)
        case "delete":
            let items = resolve(o["paths"] ?? o["path"])
            return items.isEmpty ? nil : .delete(items)
        case "copy", "move":
            let items = resolve(o["paths"] ?? o["path"])
            guard !items.isEmpty, let to = destination(o["dest"]) else { return nil }
            return action == "copy" ? .copy(items, to: to) : .move(items, to: to)
        case "hash":
            guard let u = resolve(o["path"]).first ?? context.file ?? context.selected.first else { return nil }
            return .hash(u)
        default:
            return nil
        }
    }

    private func makeEdit(_ action: String, _ o: [String: Any], _ content: String) -> ProposedEdit? {
        switch action {
        case "replace_selection":
            guard let sel = context.selection, !sel.isEmpty else {
                return context.fileText.map { ProposedEdit(target: .wholeFile, original: $0, updated: content) }
            }
            return ProposedEdit(target: .selection, original: sel, updated: content)
        case "replace_file":
            if let t = context.fileText { return ProposedEdit(target: .wholeFile, original: t, updated: content) }
            if let f = context.file ?? context.selected.first, let t = FileOps.readText(f)?.text {
                context.file = f
                return ProposedEdit(target: .wholeFile, original: t, updated: content)
            }
            return nil
        case "new_file":
            let name = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "untitled.txt"
            return ProposedEdit(target: .newFile(name), original: "", updated: content)
        default:
            return nil
        }
    }

    // MARK: Confirmations

    func run(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), let cmd = items[idx].command, items[idx].state == .pending else { return }
        items[idx].state = .running
        Task {
            let result: Result<FileCommand.Outcome, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try cmd.execute()) } catch { return .failure(error) }
            }.value
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success(let o):
                items[i].state = .done
                items[i].resultText = o.message
                items[i].found = o.found
            case .failure(let e):
                items[i].state = .cancelled
                items[i].resultText = "Failed: \(e.localizedDescription)"
            }
            onFilesChanged()
        }
    }

    func cancel(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = .cancelled
        items[idx].resultText = "Cancelled."
    }

    func apply(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), let e = items[idx].edit, items[idx].state == .pending else { return }
        do {
            switch e.target {
            case .selection:
                guard let apply = context.applyText else { throw PlainError("Open the file in the editor to apply this.") }
                apply(e.updated, true)
                items[idx].resultText = "Applied to the selection. Tap Save in the editor to write the file (Undo is available)."
            case .wholeFile:
                if let apply = context.applyText {
                    apply(e.updated, false)
                    items[idx].resultText = "Applied in the editor. Tap Save to write the file (Undo is available)."
                } else if let f = context.file {
                    try Data(e.updated.utf8).write(to: f, options: .atomic)
                    items[idx].resultText = "Saved \(f.lastPathComponent)."
                    onFilesChanged()
                } else {
                    throw PlainError("No file to apply this to.")
                }
            case .newFile(let name):
                guard let dir = context.directory else { throw PlainError("No folder open.") }
                let u = try FileOps.newFile(name, content: e.updated, in: dir)
                items[idx].found = [u]
                items[idx].resultText = "Created \(u.lastPathComponent)."
                onFilesChanged()
            }
            items[idx].state = .done
        } catch {
            items[idx].resultText = "Failed: \(error.localizedDescription)"
        }
    }
}
