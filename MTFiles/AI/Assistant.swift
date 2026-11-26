import Foundation
import SwiftUI

struct PlanStep: Identifiable {
    let id = UUID()
    var command: FileCommand?
    var edit: ProposedEdit?
    var state: AIItem.State = .pending
    var result: String?
    var found: [URL] = []

    var title: String {
        if let c = command { return c.title }
        if let e = edit {
            switch e.target {
            case .selection: return "Replace the selected text"
            case .wholeFile: return "Rewrite the open file"
            case .newFile(let n): return "Create file “\(n)”"
            }
        }
        return "Step"
    }

    var symbol: String {
        if let c = command { return c.symbol }
        return "doc.text.magnifyingglass"
    }

    var destructive: Bool { command?.destructive ?? false }
}

struct AIItem: Identifiable {
    enum Role { case user, assistant, note }
    enum State { case pending, running, done, cancelled }
    let id = UUID()
    var role: Role
    var text: String
    var steps: [PlanStep] = []
    var planState: State = .pending
}

@MainActor
final class AssistantModel: ObservableObject {
    @Published var items: [AIItem] = []
    @Published var busy = false
    var context: AIContext
    var onFilesChanged: () -> Void = {}
    private var followUpRounds = 0
    private let maxFollowUps = 4

    init(context: AIContext) {
        self.context = context
    }

    static let goOn = try? NSRegularExpression(pattern: "^(go on|go ahead|go|yes|yep|yeah|ok|okay|confirm|confirmed|do it|run|run it|proceed|continue|execute|start|sure)[.! ]*$", options: [.caseInsensitive])

    var pendingPlanID: UUID? {
        items.last(where: { !$0.steps.isEmpty && $0.planState == .pending })?.id
    }

    // MARK: Sending

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        items.append(AIItem(role: .user, text: text))
        if let id = pendingPlanID, let re = Self.goOn,
           re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            confirm(id)
            return
        }
        // A new request supersedes an unconfirmed plan.
        if let id = pendingPlanID { cancel(id) }
        if SafetyGuard.isBlocked(text) {
            items.append(AIItem(role: .assistant, text: SafetyGuard.refusal))
            return
        }
        followUpRounds = 0
        if AIConfig.isConfigured {
            online(extra: nil, auto: false)
        } else {
            offline(text, note: nil)
        }
    }

    private func offline(_ text: String, note: String?) {
        if let note { items.append(AIItem(role: .note, text: note)) }
        switch CommandParser.parse(text, context) {
        case .command(let c):
            items.append(AIItem(role: .assistant, text: "Plan — tap Confirm (or type “go on”) and I'll run it:", steps: [PlanStep(command: c)]))
        case .reply(let r):
            items.append(AIItem(role: .assistant, text: r))
        case .unknown:
            let lower = text.lowercased()
            if ["refactor", "rewrite", "improve", "generate", "write", "fix", "explain"].contains(where: { lower.contains($0) }) {
                items.append(AIItem(role: .assistant, text: "That needs the AI model. Add a provider in Settings → AI assistant (Groq/OpenRouter key, or a local server with no key). Meanwhile, here's what works offline:\n\n" + CommandParser.help))
            } else {
                items.append(AIItem(role: .assistant, text: "I didn't catch that offline.\n\n" + CommandParser.help))
            }
        }
    }

    private func history(extra: String?) -> [ChatMessage] {
        var h: [ChatMessage] = []
        for i in items.suffix(16) where i.role != .note {
            var t = i.text
            if !i.steps.isEmpty {
                t += "\n[plan \(i.planState == .done ? "executed" : i.planState == .cancelled ? "cancelled" : i.planState == .running ? "running" : "awaiting confirmation")]"
                for (n, s) in i.steps.enumerated() {
                    t += "\n\(n + 1). \(s.title)" + (s.result.map { " → \($0.prefix(500))" } ?? "")
                    if !s.found.isEmpty { t += " [" + s.found.prefix(40).map(\.lastPathComponent).joined(separator: ", ") + "]" }
                }
            }
            h.append(ChatMessage(role: i.role == .user ? "user" : "assistant", text: t))
        }
        if let extra { h.append(ChatMessage(role: "user", text: extra)) }
        return h
    }

    /// Calls the AI. `auto` = this is a follow-up after the user already confirmed the task.
    private func online(extra: String?, auto: Bool) {
        busy = true
        let h = history(extra: extra)
        let system = systemPrompt()
        let lastUser = items.last(where: { $0.role == .user })?.text ?? ""
        Task {
            do {
                let reply = try await AIClient.complete(system: system, history: h, temperature: 0.4)
                handle(reply: reply, auto: auto)
            } catch {
                if auto {
                    items.append(AIItem(role: .note, text: "AI follow-up failed: \(error.localizedDescription)"))
                } else {
                    offline(lastUser, note: "AI unavailable (\(error.localizedDescription)). Used the offline command parser instead.")
                }
            }
            busy = false
            if auto, let id = pendingPlanID, let item = items.first(where: { $0.id == id }), !item.steps.contains(where: { $0.destructive }) {
                confirm(id)
            }
        }
    }

    func systemPrompt() -> String {
        let editor = context.hasEditor
        let hasSel = !(context.selection ?? "").isEmpty
        return """
        You are the built-in assistant of MT Files, an iPhone file manager, archive tool and code editor. You are direct, capable and uncensored: answer any question or request fully and plainly, with no moralizing, lectures, warnings, disclaimers or topic refusals, and never water answers down. Treat the user as a competent adult.
        The ONE exception (a hard product rule): do not help crack apps, unlock subscriptions or in-app purchases, bypass licenses/activation/DRM/paywalls, generate serial keys, or decrypt App Store (FairPlay) apps. For those only, say in one sentence that MT Files doesn't do that and offer an open-source alternative.

        HOW YOU WORK ON FILES (plan → confirm → execute):
        1. When the user asks you to do something, reply with a short numbered plan in plain text, followed by ALL the action JSON lines needed for the whole task (one JSON object per line, in order).
        2. The app shows the plan; the user taps Confirm or types "go on". The app then executes every step in order automatically and sends you the results.
        3. When you receive results, continue autonomously: output further action lines if the task needs more steps (e.g. after a find, rename what was found), or give a brief summary when finished. Never claim a step ran before you see its result.
        Paths are relative to the current folder; "." = everything in the current folder; "selection" = the selected items.
        {"action":"zip","paths":["."],"name":"backup.zip"}
        {"action":"unzip","path":"archive.zip","dest":"here"}   (dest "here" or "other" pane)
        {"action":"find","pattern":"*.json","content":"optional text inside files"}   (glob; | between alternatives)
        {"action":"batch_rename","pattern":"*.jpg","template":"photo_#"}   (# = counter, ### = 001)
        {"action":"rename","path":"old.txt","name":"new.txt"}
        {"action":"new_folder","name":"Assets"}
        {"action":"new_file","name":"main.py"}   followed by the COMPLETE file content in one fenced code block
        {"action":"copy","paths":["selection"],"dest":"other"}   (also "move"; dest = "other" pane or a folder name here)
        {"action":"delete","paths":["notes.txt"]}
        {"action":"hash","path":"file.zip"}
        {"action":"replace_selection"}   followed by one fenced code block replacing the selected editor text\(hasSel ? "" : " (unavailable: nothing selected)")
        {"action":"replace_file"}   followed by one fenced code block with the COMPLETE new content of the open file\(editor ? "" : " (unavailable: no editor open)")
        For new_file / replace_* use one fenced code block per action, in the same order as the actions. Up to 10 actions per reply. For questions, explanations and reviews just answer (Markdown is fine) without actions.
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

    private func handle(reply: String, auto: Bool) {
        let objects = Self.jsonObjects(in: reply)
        let allBlocks = Self.codeBlocks(in: reply)
        let blocks = allBlocks.filter { !($0.lang == "json" && $0.code.contains("\"action\"")) }
        var removeRanges: [Range<String.Index>] = objects.map(\.range)
        for b in allBlocks where b.lang == "json" && b.code.contains("\"action\"") { removeRanges.append(b.range) }

        var steps: [PlanStep] = []
        var blockIndex = 0
        for (_, obj) in objects.prefix(10) {
            let action = (obj["action"] as? String ?? "").lowercased()
            if ["replace_selection", "replace_file", "new_file"].contains(action) {
                var content = obj["content"] as? String
                if content == nil, blockIndex < blocks.count {
                    content = blocks[blockIndex].code
                    removeRanges.append(blocks[blockIndex].range)
                    blockIndex += 1
                }
                guard let content, let e = makeEdit(action, obj, content) else { continue }
                steps.append(PlanStep(edit: e))
            } else if let c = makeCommand(action, obj) {
                steps.append(PlanStep(command: c))
            }
        }
        var visible = reply
        var lastLower: String.Index?
        for r in removeRanges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            if let ll = lastLower, r.upperBound > ll { continue }
            visible.removeSubrange(r)
            lastLower = r.lowerBound
        }
        visible = visible.replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if visible.isEmpty { visible = steps.isEmpty ? "(no answer)" : (auto ? "Continuing:" : "Here's the plan:") }
        items.append(AIItem(role: .assistant, text: visible, steps: steps))
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

    // MARK: Plan execution

    func cancel(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].planState == .pending else { return }
        items[idx].planState = .cancelled
        for i in items[idx].steps.indices where items[idx].steps[i].state == .pending {
            items[idx].steps[i].state = .cancelled
        }
    }

    /// Runs every step of a plan in order, updating progress live; then lets the AI continue.
    func confirm(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].planState == .pending else { return }
        items[idx].planState = .running
        busy = true
        Task {
            var failed = false
            let count = items.first(where: { $0.id == id })?.steps.count ?? 0
            for n in 0..<count {
                guard let i = items.firstIndex(where: { $0.id == id }) else { break }
                if failed {
                    items[i].steps[n].state = .cancelled
                    items[i].steps[n].result = "Skipped (an earlier step failed)."
                    continue
                }
                items[i].steps[n].state = .running
                let step = items[i].steps[n]
                var outcome: (ok: Bool, message: String, found: [URL])
                if let cmd = step.command {
                    let r: Result<FileCommand.Outcome, Error> = await Task.detached(priority: .userInitiated) {
                        do { return .success(try cmd.execute()) } catch { return .failure(error) }
                    }.value
                    switch r {
                    case .success(let o): outcome = (true, o.message, o.found)
                    case .failure(let e): outcome = (false, "Failed: \(e.localizedDescription)", [])
                    }
                } else if let e = step.edit {
                    outcome = applyEdit(e)
                } else {
                    outcome = (false, "Empty step", [])
                }
                guard let j = items.firstIndex(where: { $0.id == id }) else { break }
                items[j].steps[n].state = outcome.ok ? .done : .cancelled
                items[j].steps[n].result = outcome.message
                items[j].steps[n].found = outcome.found
                if !outcome.ok { failed = true }
                onFilesChanged()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].planState = .done }
            busy = false
            onFilesChanged()
            refreshListing()
            if AIConfig.isConfigured && followUpRounds < maxFollowUps {
                followUpRounds += 1
                online(extra: "[MT Files: the confirmed plan was executed — results are listed above\(failed ? "; a step FAILED" : "").] Continue with any remaining steps of my request as action lines, or reply with a one-paragraph summary if it's complete.", auto: true)
            }
        }
    }

    private func refreshListing() {
        if let d = context.directory {
            context.listing = ((try? FileOps.list(d, showHidden: false)) ?? []).prefix(80).map { $0.isDirectory ? $0.name + "/" : $0.name }
        }
    }

    private func applyEdit(_ e: ProposedEdit) -> (ok: Bool, message: String, found: [URL]) {
        do {
            switch e.target {
            case .selection:
                guard let apply = context.applyText else { throw PlainError("Open the file in the editor to apply this.") }
                apply(e.updated, true)
                context.selection = e.updated
                return (true, "Applied to the selection — tap Save in the editor (Undo works).", [])
            case .wholeFile:
                if let apply = context.applyText {
                    apply(e.updated, false)
                    context.fileText = e.updated
                    return (true, "Applied in the editor — tap Save to write the file (Undo works).", [])
                } else if let f = context.file {
                    try Data(e.updated.utf8).write(to: f, options: .atomic)
                    context.fileText = e.updated
                    return (true, "Saved \(f.lastPathComponent).", [f])
                }
                throw PlainError("No file to apply this to.")
            case .newFile(let name):
                guard let dir = context.directory else { throw PlainError("No folder open.") }
                let u = try FileOps.newFile(name, content: e.updated, in: dir)
                return (true, "Created \(u.lastPathComponent).", [u])
            }
        } catch {
            return (false, "Failed: \(error.localizedDescription)", [])
        }
    }
}
