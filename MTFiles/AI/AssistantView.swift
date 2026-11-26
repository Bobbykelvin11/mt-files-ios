import SwiftUI

struct DiffLine: Identifiable {
    let id: Int
    let kind: Character // " ", "+", "-"
    let text: String
}

enum LineDiff {
    static func compute(_ a: String, _ b: String) -> [DiffLine] {
        let old = a.components(separatedBy: "\n")
        let new = b.components(separatedBy: "\n")
        if old.count * new.count > 6_000_000 {
            return [DiffLine(id: 0, kind: " ", text: "(File too large for a line diff: \(old.count) → \(new.count) lines)")]
        }
        let diff = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in diff {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0, n = 0
        while i < old.count || j < new.count {
            if i < old.count && removed.contains(i) {
                out.append(DiffLine(id: n, kind: "-", text: old[i])); i += 1
            } else if j < new.count && inserted.contains(j) {
                out.append(DiffLine(id: n, kind: "+", text: new[j])); j += 1
            } else {
                if i < old.count { out.append(DiffLine(id: n, kind: " ", text: old[i])) }
                i += 1; j += 1
            }
            n += 1
        }
        return collapse(out)
    }

    /// Hides long unchanged runs, keeping 2 lines of context.
    static func collapse(_ lines: [DiffLine]) -> [DiffLine] {
        let changed = lines.indices.filter { lines[$0].kind != " " }
        guard !changed.isEmpty else { return [DiffLine(id: 0, kind: " ", text: "(no changes)")] }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - 2)...min(lines.count - 1, c + 2) { keep.insert(k) } }
        var out: [DiffLine] = []
        var skipped = 0
        for (idx, l) in lines.enumerated() {
            if keep.contains(idx) {
                if skipped > 0 { out.append(DiffLine(id: -idx, kind: "…", text: "⋯ \(skipped) unchanged line(s)")); skipped = 0 }
                out.append(l)
            } else { skipped += 1 }
        }
        if skipped > 0 { out.append(DiffLine(id: -lines.count - 1, kind: "…", text: "⋯ \(skipped) unchanged line(s)")) }
        return out
    }
}

struct DiffView: View {
    let edit: ProposedEdit
    @State private var lines: [DiffLine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let plus = lines.filter { $0.kind == "+" }.count
            let minus = lines.filter { $0.kind == "-" }.count
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text("+\(plus)").foregroundStyle(.green).font(.caption.monospaced())
                Text("−\(minus)").foregroundStyle(.red).font(.caption.monospaced())
            }
            .padding(8)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { l in
                        Text(prefix(l) + l.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(l.kind == "+" ? Color.green : l.kind == "-" ? Color.red : l.kind == "…" ? Color.secondary : Color.primary.opacity(0.8))
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(l.kind == "+" ? Color.green.opacity(0.12) : l.kind == "-" ? Color.red.opacity(0.12) : Color.clear)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { if lines.isEmpty { lines = LineDiff.compute(edit.original, edit.updated) } }
    }

    private func prefix(_ l: DiffLine) -> String {
        switch l.kind {
        case "+": return "+ "
        case "-": return "- "
        case "…": return ""
        default: return "  "
        }
    }

    private var title: String {
        switch edit.target {
        case .selection: return "Replace selection"
        case .wholeFile: return "Replace file content"
        case .newFile(let n): return "New file: \(n)"
        }
    }
}

struct AssistantView: View {
    let context: AIContext
    var isTab = false
    @EnvironmentObject var app: AppModel
    @StateObject private var model: AssistantModel
    @State private var input = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(context: AIContext, isTab: Bool = false) {
        self.context = context
        self.isTab = isTab
        _model = StateObject(wrappedValue: AssistantModel(context: context))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contextBar
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if model.items.isEmpty { intro }
                            ForEach(model.items) { item in
                                bubble(item).id(item.id)
                            }
                            if model.busy {
                                HStack { ProgressView(); Text("Thinking…").font(.footnote).foregroundStyle(.secondary) }.id("busy")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: model.items.count) { _ in
                        if let id = model.items.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }
                suggestions
                inputBar
            }
            .background(Theme.bg)
            .navigationTitle("AI Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isTab {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.items.removeAll() } label: { Image(systemName: "trash") }.disabled(model.items.isEmpty)
                }
            }
            .onAppear {
                let a = app
                model.onFilesChanged = { a.reloadAll() }
                if isTab { model.context = app.context(for: app.active) }
            }
        }
        .tint(Theme.accent)
    }

    private var contextBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.context.file != nil ? "doc.text" : "folder").foregroundStyle(Theme.accent)
            Text(contextLabel).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(AIConfig.isConfigured ? "AI: \(AIConfig.model.split(separator: "/").last.map(String.init) ?? AIConfig.model)" : "Offline mode")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background((AIConfig.isConfigured ? Theme.accent : Color.orange).opacity(0.2), in: Capsule())
                .foregroundStyle(AIConfig.isConfigured ? Theme.accent : .orange)
                .lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var contextLabel: String {
        let c = model.context
        var s = c.file?.lastPathComponent ?? c.directory?.lastPathComponent ?? "No folder"
        if let sel = c.selection, !sel.isEmpty { s += " · \(sel.count) chars selected" }
        else if !c.selected.isEmpty && c.file == nil { s += " · \(c.selected.count) selected" }
        return s
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask about your files, or tell me what to do.", systemImage: "sparkles").font(.headline)
            Text("I propose a plan first; tap Confirm (or type “go on”) and I run every step with live progress. \(AIConfig.isConfigured ? "" : "No AI key yet: I'll use the offline command parser. Add a free key in Settings for explanations and code edits.")")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var suggestionList: [String] {
        let c = model.context
        var s: [String] = []
        if let sel = c.selection, !sel.isEmpty {
            s += ["Explain the selected code", "Refactor the selection to be cleaner", "Add comments to the selection", "Find bugs in the selection"]
        }
        if c.file != nil {
            s += ["Explain this file", "Review this file for bugs", "Suggest a better name for this file"]
            if c.hasEditor { s += ["Add helpful comments to this file", "Convert this file to use 4-space indentation"] }
        }
        s += ["zip this folder", "find all .json files", "rename all jpgs to photo_#", "Summarize what's in this folder", "Generate a README.md for this folder", "new folder Assets"]
        if !c.selected.isEmpty { s.insert("copy selected to other pane", at: 0) }
        return s
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestionList, id: \.self) { s in
                    Button(s) { model.send(s) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .disabled(model.busy)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Theme.panel)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask or command… e.g. “zip this folder”", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 10))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
        }
        .padding(10)
        .background(Theme.panel)
    }

    private func send() {
        let t = input
        input = ""
        model.send(t)
    }

    @ViewBuilder
    private func bubble(_ item: AIItem) -> some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text).font(.callout)
                    .padding(10)
                    .background(Theme.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        case .note:
            Text(item.text).font(.caption).foregroundStyle(.orange)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !item.text.isEmpty {
                    Text(markdown(item.text)).font(.callout).textSelection(.enabled)
                }
                if !item.steps.isEmpty { planCard(item) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func planCard(_ item: AIItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Plan · \(item.steps.count) step\(item.steps.count == 1 ? "" : "s")", systemImage: "list.number").font(.subheadline.bold())
                Spacer()
                if item.planState == .running {
                    let done = item.steps.filter { $0.state == .done || $0.state == .cancelled }.count
                    Text("\(done)/\(item.steps.count)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            if item.planState == .running {
                let done = item.steps.filter { $0.state == .done || $0.state == .cancelled }.count
                ProgressView(value: Double(done), total: Double(max(item.steps.count, 1))).tint(Theme.accent)
            }
            ForEach(Array(item.steps.enumerated()), id: \.element.id) { n, step in
                stepRow(n + 1, step)
            }
            switch item.planState {
            case .pending:
                if item.steps.contains(where: { $0.destructive }) {
                    Label("This plan deletes files.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button { model.confirm(item.id) } label: { Text("Confirm & run all").bold() }
                        .buttonStyle(.borderedProminent)
                        .tint(item.steps.contains(where: { $0.destructive }) ? Color.red : Theme.accent)
                    Button("Cancel") { model.cancel(item.id) }.buttonStyle(.bordered)
                }
                Text("…or type “go on”.").font(.caption2).foregroundStyle(.secondary)
            case .running:
                HStack { ProgressView(); Text("Running the plan…").font(.caption) }
            case .done:
                Label("Plan finished", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
            case .cancelled:
                Label("Cancelled", systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func stepRow(_ n: Int, _ step: PlanStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    switch step.state {
                    case .pending: Image(systemName: "\(min(n, 50)).circle").foregroundStyle(.secondary)
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .cancelled: Image(systemName: step.result?.hasPrefix("Failed") == true ? "exclamationmark.circle.fill" : "minus.circle").foregroundStyle(step.result?.hasPrefix("Failed") == true ? Color.red : Color.secondary)
                    }
                }
                .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Label(step.title, systemImage: step.symbol)
                        .font(.footnote.bold())
                        .foregroundStyle(step.destructive ? Color.red : Color.primary)
                    if let d = step.command?.detail { Text(d).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    if let r = step.result {
                        Text(r).font(.caption).foregroundStyle(step.state == .done ? Color.green : Color.secondary).textSelection(.enabled)
                    }
                }
            }
            if let e = step.edit {
                DisclosureGroup("Show changes") { DiffView(edit: e) }
                    .font(.caption)
            }
            foundList(step.found)
        }
    }

    @ViewBuilder
    private func foundList(_ found: [URL]) -> some View {
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(found.prefix(60), id: \.self) { u in
                    Button { reveal(u) } label: {
                        let e = FileEntry(url: u)
                        HStack(spacing: 6) {
                            Image(systemName: e.symbol).foregroundStyle(e.tint).font(.caption)
                            Text(relative(u)).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
                if found.count > 60 { Text("…and \(found.count - 60) more").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private func relative(_ u: URL) -> String {
        guard let d = model.context.directory?.standardizedFileURL.path else { return u.lastPathComponent }
        let p = u.standardizedFileURL.path
        return p.hasPrefix(d) ? "." + p.dropFirst(d.count) : u.lastPathComponent
    }

    private func reveal(_ u: URL) {
        app.reveal(u)
        if !isTab { dismiss() }
    }
}
