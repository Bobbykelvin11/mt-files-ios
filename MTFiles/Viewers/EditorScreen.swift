import SwiftUI
import UIKit

struct EditorScreen: View {
    let url: URL
    /// When set, saving converts the XML text back into this plist format.
    var plistFormat: PropertyListSerialization.PropertyListFormat? = nil
    var initialOverride: String? = nil
    var showClose: Bool = true

    @EnvironmentObject var app: AppModel
    @StateObject private var controller = EditorController()
    @State private var loaded: String?
    @State private var encoding: String.Encoding = .utf8
    @State private var loadError: String?
    @State private var language: CodeLanguage = .plain
    @AppStorage("editor_wrap") private var wrap = true
    @AppStorage("editor_lines") private var lineNumbers = true
    @State private var readOnly = false
    @State private var showFind = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false
    @State private var useRegex = false
    @State private var findStatus = ""
    @State private var gotoShown = false
    @State private var gotoText = ""
    @State private var share: URLList?
    @State private var assistant: AIContext?
    @State private var confirmDiscard = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if showFind { findBar }
            if let loaded {
                CodeEditorView(controller: controller, initialText: loaded, language: language, editable: !readOnly, wrap: wrap, lineNumbers: lineNumbers)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(loadError).multilineTextAlignment(.center).font(.footnote)
                    Button("Open in hex viewer") { app.open = OpenRequest(url: url, mode: .hex) }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            statusBar
        }
        .background(Theme.bg)
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { load() }
        .alert("Go to line", isPresented: $gotoShown) {
            TextField("Line (1–\(controller.lineCount))", text: $gotoText).keyboardType(.numberPad)
            Button("Go") { if let n = Int(gotoText) { controller.goTo(line: n) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $share) { l in ShareSheet(items: l.urls) }
        .sheet(item: $assistant) { ctx in
            AssistantView(context: ctx)
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { openAssistant() } label: { Image(systemName: "sparkles") }
            Button { withAnimation { showFind.toggle() } } label: { Image(systemName: "magnifyingglass") }
            Button { _ = save() } label: { Text("Save").bold() }
                .disabled(!controller.dirty || readOnly)
            Menu {
                Button { controller.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!controller.canUndo)
                Button { controller.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!controller.canRedo)
                Button { gotoText = ""; gotoShown = true } label: { Label("Go to line…", systemImage: "arrow.down.to.line") }
                Divider()
                Toggle(isOn: $wrap) { Label("Wrap lines", systemImage: "text.word.spacing") }
                Toggle(isOn: $lineNumbers) { Label("Line numbers", systemImage: "list.number") }
                Toggle(isOn: $readOnly) { Label("Read-only", systemImage: "lock") }
                Menu("Syntax: \(language.displayName)") {
                    ForEach([CodeLanguage.plain, .swift, .js, .ts, .python, .json, .xml, .html, .css, .c, .objc, .java, .kotlin, .go, .rust, .shell, .yaml, .markdown, .smali, .lua, .php, .ruby, .sql], id: \.rawValue) { l in
                        Button(l.displayName) { language = l }
                    }
                }
                Divider()
                Button { formatJSON(pretty: true) } label: { Label("Pretty-print JSON", systemImage: "curlybraces") }
                Button { formatJSON(pretty: false) } label: { Label("Minify JSON", systemImage: "arrow.down.right.and.arrow.up.left") }
                Button { insertTab() } label: { Label("Insert tab (4 spaces)", systemImage: "arrow.right.to.line") }
                Divider()
                Button { app.open = OpenRequest(url: url, mode: .hex) } label: { Label("Open in hex viewer", systemImage: "number") }
                Button { share = URLList(urls: [url]) } label: { Label("Share / Open in…", systemImage: "square.and.arrow.up") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        ToolbarItem(placement: .cancellationAction) {
            if showClose {
            Button("Close") {
                if controller.dirty { confirmDiscard = true } else { app.open = nil; dismiss() }
            }
            .confirmationDialog("Save changes to \(url.lastPathComponent)?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Save") { if save() { app.open = nil; dismiss() } }
                Button("Discard changes", role: .destructive) { app.open = nil; dismiss() }
            }
            }
        }
    }

    private var findBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { doFind(forward: true) }
                Button { doFind(forward: false) } label: { Image(systemName: "chevron.up") }
                Button { doFind(forward: true) } label: { Image(systemName: "chevron.down") }
                Toggle("Aa", isOn: $caseSensitive).toggleStyle(.button).font(.caption)
                Toggle(".*", isOn: $useRegex).toggleStyle(.button).font(.caption)
            }
            HStack(spacing: 6) {
                TextField("Replace with", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Replace") {
                    controller.replaceCurrent(find: findText, with: replaceText, caseSensitive: caseSensitive, regex: useRegex)
                }
                .disabled(findText.isEmpty || readOnly)
                Button("All") {
                    let n = controller.replaceAllMatches(find: findText, with: replaceText, caseSensitive: caseSensitive, regex: useRegex)
                    findStatus = "Replaced \(n)"
                }
                .disabled(findText.isEmpty || readOnly)
            }
            if !findStatus.isEmpty {
                Text(findStatus).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.footnote)
        .padding(8)
        .background(Theme.panel)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("Ln \(controller.cursorLine), Col \(controller.cursorColumn)")
            Text("\(controller.lineCount) lines")
            Spacer()
            Text(language.displayName)
            Text(encodingName)
            if controller.dirty { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.panel)
    }

    private var encodingName: String {
        if plistFormat != nil { return plistFormat == .binary ? "plist (binary)" : "plist (xml)" }
        switch encoding {
        case .utf16: return "UTF-16"
        case .isoLatin1: return "Latin-1"
        default: return "UTF-8"
        }
    }

    // MARK: Actions

    private func load() {
        guard loaded == nil, loadError == nil else { return }
        language = CodeLanguage.detect(url)
        if url.path.hasPrefix(Bundle.main.bundleURL.path) { readOnly = true }
        if let initialOverride {
            loaded = initialOverride
            controller.initialText = initialOverride
            return
        }
        if let r = FileOps.readText(url) {
            encoding = r.encoding
            loaded = r.text
            controller.initialText = r.text
        } else {
            loadError = "This file doesn't look like text (or is larger than 20 MB)."
        }
    }

    @discardableResult
    private func save() -> Bool {
        let text = controller.text
        do {
            if let fmt = plistFormat {
                guard let data = text.data(using: .utf8) else { throw PlainError("Couldn't encode text") }
                let obj = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: nil)
                let out = try PropertyListSerialization.data(fromPropertyList: obj, format: fmt == .openStep ? .xml : fmt, options: 0)
                try out.write(to: url, options: .atomic)
            } else {
                guard let data = text.data(using: encoding) ?? text.data(using: .utf8) else { throw PlainError("Couldn't encode text") }
                try data.write(to: url, options: .atomic)
            }
            controller.dirty = false
            app.show("Saved \(url.lastPathComponent)")
            app.reloadAll()
            return true
        } catch {
            app.error = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    private func doFind(forward: Bool) {
        let found = controller.find(findText, forward: forward, caseSensitive: caseSensitive, regex: useRegex)
        let n = controller.countMatches(findText, caseSensitive: caseSensitive, regex: useRegex)
        findStatus = found ? "\(n) match(es)" : "No matches"
    }

    private func formatJSON(pretty: Bool) {
        let source = controller.selectedText ?? controller.text
        guard let data = source.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed] : [.withoutEscapingSlashes, .fragmentsAllowed]),
              let s = String(data: out, encoding: .utf8) else {
            app.error = "That isn't valid JSON."
            return
        }
        if controller.selectedText != nil { controller.replaceSelection(s) } else { controller.replaceAll(s) }
        if language == .plain { language = .json }
    }

    private func insertTab() { controller.insert("    ") }

    private func openAssistant() {
        var ctx = AIContext(directory: url.deletingLastPathComponent())
        ctx.file = url
        ctx.fileText = controller.text
        ctx.selection = controller.selectedText
        ctx.language = language.displayName
        let c = controller
        ctx.applyText = { text, selectionOnly in
            if selectionOnly && c.selectedText != nil { c.replaceSelection(text) } else { c.replaceAll(text) }
            c.dirty = true
        }
        assistant = ctx
    }
}
