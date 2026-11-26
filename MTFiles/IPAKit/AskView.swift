import SwiftUI

@MainActor
final class AskEngine: ObservableObject {
    @Published var pendingAction: AIAction?
    @Published var results: [GitHubIPAResult] = []
    @Published var searchedTerms: String?
    @Published var searching = false
    @Published var thinking = false
    @Published var notice: String?
    @Published var error: String?
    @Published var applied: String?
    @Published var chat: [ChatMessage] = []
    @Published var webQuery = ""

    func run(_ query: String, store: LibraryStore) async {
        webQuery = query
        let intent = IntentParser.parse(query)
        switch intent {
        case .blocked(let msg):
            notice = msg
        case .edit(let action):
            pendingAction = .edit(action)
        case .find(let terms):
            await search(terms)
        case .web(let terms):
            webQuery = terms
            notice = "Tap “Search the web” below to open DuckDuckGo."
        case .chat(let text):
            if AIConfig.isConfigured {
                await send(text, store: store)
            } else {
                notice = "Searching GitHub for open-source iOS apps. Tip: add a free AI key in Settings to chat about anything."
                await search(text)
            }
        }
    }

    func search(_ terms: String) async {
        searching = true
        error = nil
        searchedTerms = terms
        defer { searching = false }
        do {
            results = try await GitHubSearch.search(terms)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func send(_ text: String, store: LibraryStore) async {
        if case .blocked(let msg) = IntentParser.parse(text) {
            chat.append(ChatMessage(role: "user", text: text))
            chat.append(ChatMessage(role: "assistant", text: msg))
            return
        }
        chat.append(ChatMessage(role: "user", text: text))
        thinking = true
        defer { thinking = false }
        do {
            let reply = try await AIClient.chat(history: chat, context: store.contextDescription())
            let (visible, action) = AIClient.extractAction(from: reply)
            chat.append(ChatMessage(role: "assistant", text: visible.isEmpty ? "Here’s what I can do:" : visible))
            if let action { pendingAction = action }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply(_ action: AIAction, store: LibraryStore) async {
        pendingAction = nil
        switch action {
        case .edit(let edit):
            guard let p = store.currentProject else {
                error = "Open an IPA first (import from Files, a URL, or GitHub), then try again."
                return
            }
            do {
                try store.apply(edit, to: p.id)
                applied = "Done: \(edit.summary) in \(p.displayName). Export it from the app page when you’re ready."
            } catch {
                self.error = error.localizedDescription
            }
        case .find(let terms):
            await search(terms)
        case .web(let q):
            webQuery = q
            notice = "Tap “Search the web” below to open DuckDuckGo."
        }
    }
}

struct AskView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = AskEngine()
    @StateObject private var downloader = Downloader()
    let initialQuery: String

    @State private var followUp = ""
    @State private var safari: IdentifiableURL?
    @State private var downloadingID: String?
    @State private var importedNames: Set<String> = []
    @State private var started = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(initialQuery, systemImage: "text.bubble").font(.callout)
                }

                if let notice = engine.notice {
                    Section { Label(notice, systemImage: "info.circle").font(.callout) }
                }

                if let action = engine.pendingAction {
                    Section("Suggested action") { actionCard(action) }
                }

                if let applied = engine.applied {
                    Section { Label(applied, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }

                if let err = engine.error {
                    Section { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                if !engine.chat.isEmpty || engine.thinking {
                    Section("AI") {
                        ForEach(engine.chat) { m in
                            HStack(alignment: .top) {
                                Image(systemName: m.role == "user" ? "person.circle" : "sparkles")
                                    .foregroundStyle(m.role == "user" ? Color.secondary : Color.purple)
                                Text(m.text).textSelection(.enabled)
                            }
                        }
                        if engine.thinking {
                            HStack { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }
                        }
                    }
                }

                if engine.searching {
                    Section { HStack { ProgressView(); Text("Searching GitHub releases for .ipa files…").foregroundStyle(.secondary) } }
                } else if let terms = engine.searchedTerms {
                    Section {
                        if engine.results.isEmpty {
                            Text("No .ipa releases found for “\(terms)”. Try other words, or search the web.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(engine.results) { r in resultRow(r) }
                    } header: {
                        Text("Open-source IPAs on GitHub")
                    } footer: {
                        Text("Results come from public GitHub releases. Check each project’s license and README.")
                    }
                }

                Section {
                    Button {
                        var comps = URLComponents(string: "https://duckduckgo.com/")!
                        comps.queryItems = [URLQueryItem(name: "q", value: engine.webQuery)]
                        if let url = comps.url { safari = IdentifiableURL(url: url) }
                    } label: {
                        Label("Search the web for “\(engine.webQuery)”", systemImage: "safari")
                    }
                    if engine.searchedTerms == nil && !engine.searching {
                        Button {
                            Task { await engine.search(initialQuery) }
                        } label: {
                            Label("Search GitHub for IPAs", systemImage: "magnifyingglass")
                        }
                    }
                }

                if AIConfig.isConfigured {
                    Section("Ask AI") {
                        HStack {
                            TextField("Ask a follow-up or give a command…", text: $followUp, axis: .vertical)
                                .lineLimit(1...4)
                            Button {
                                let t = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !t.isEmpty else { return }
                                followUp = ""
                                Task { await engine.send(t, store: store) }
                            } label: {
                                Image(systemName: "arrow.up.circle.fill").font(.title2)
                            }
                            .disabled(engine.thinking)
                        }
                        if engine.chat.isEmpty && !engine.thinking {
                            Button("Ask the AI about “\(initialQuery)”") {
                                Task { await engine.send(initialQuery, store: store) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ask AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $safari) { item in
                SafariView(url: item.url).ignoresSafeArea()
            }
            .task {
                guard !started else { return }
                started = true
                await engine.run(initialQuery, store: store)
            }
        }
    }

    @ViewBuilder
    private func actionCard(_ action: AIAction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch action {
            case .edit(let edit):
                Label(edit.summary, systemImage: edit.symbol).font(.headline)
                if let p = store.currentProject {
                    HStack {
                        ProjectIcon(project: p, size: 28)
                        Text("on \(p.displayName)").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No IPA is open yet. Import one first.").font(.caption).foregroundStyle(.orange)
                }
            case .find(let terms):
                Label("Search GitHub for “\(terms)”", systemImage: "magnifyingglass").font(.headline)
            case .web(let q):
                Label("Search the web for “\(q)”", systemImage: "safari").font(.headline)
            }
            HStack {
                Button("Apply") { Task { await engine.apply(action, store: store) } }
                    .buttonStyle(.borderedProminent)
                Button("Cancel", role: .cancel) { engine.pendingAction = nil }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func resultRow(_ r: GitHubIPAResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.repoFullName).font(.headline).lineLimit(1)
                Spacer()
                Label("\(r.stars)", systemImage: "star.fill").font(.caption).foregroundStyle(.yellow)
            }
            if !r.repoDescription.isEmpty {
                Text(r.repoDescription).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Text("\(r.assetName) · \(r.releaseTag) · \(formatBytes(r.assetSize))")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                if downloadingID == r.id {
                    ProgressView(value: downloader.progress).frame(maxWidth: 140)
                    Text(downloader.statusText).font(.caption2).foregroundStyle(.secondary)
                } else if importedNames.contains(r.id) {
                    Label("In Library", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(.green)
                } else {
                    Button {
                        importResult(r)
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(downloadingID != nil)
                }
                Spacer()
                Button {
                    safari = IdentifiableURL(url: r.repoURL)
                } label: {
                    Label("Repo", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func importResult(_ r: GitHubIPAResult) {
        downloadingID = r.id
        Task {
            defer { downloadingID = nil }
            do {
                let (file, _) = try await downloader.download(r.downloadURL)
                try await store.importIPA(from: file, suggestedName: r.assetName)
                try? FileManager.default.removeItem(at: file)
                importedNames.insert(r.id)
                engine.applied = "Imported \(r.assetName). It’s now the open IPA in your Library."
            } catch {
                engine.error = error.localizedDescription
            }
        }
    }
}
