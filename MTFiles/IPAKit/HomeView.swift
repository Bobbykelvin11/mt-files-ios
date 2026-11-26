import SwiftUI
import UniformTypeIdentifiers

struct AskRequest: Identifiable {
    let id = UUID()
    let query: String
}

struct HomeView: View {
    @EnvironmentObject var store: LibraryStore
    @Binding var selectedTab: Int
    @State private var query = ""
    @State private var ask: AskRequest?
    @State private var showFileImporter = false
    @State private var showURLImport = false
    @State private var path = NavigationPath()
    @FocusState private var askFocused: Bool

    private let examples = [
        "find open source YouTube app",
        "rename to My App",
        "make icon blue",
        "enable file sharing",
        "change bundle id to com.me.app",
        "set minimum iOS to 15.0",
        "find emulator ipa",
        "web: how to sign ipa with SideStore"
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    askCard
                    importButtons
                    if let p = store.currentProject {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Currently open").font(.headline)
                            NavigationLink(value: p) {
                                ProjectRow(project: p)
                                    .padding(12)
                                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if store.projects.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Recent").font(.headline)
                                Spacer()
                                Button("See all") { selectedTab = 1 }.font(.subheadline)
                            }
                            ForEach(store.projects.prefix(5)) { p in
                                NavigationLink(value: p) {
                                    ProjectRow(project: p)
                                        .padding(10)
                                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if store.projects.isEmpty {
                        emptyState
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("IPA Editor")
            .navigationDestination(for: IPAProject.self) { p in
                ProjectDetailView(projectID: p.id)
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.ipa, .zip, .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        do {
                            let p = try await store.importIPA(from: url)
                            path.append(p)
                        } catch {
                            store.lastError = error.localizedDescription
                        }
                    }
                case .failure(let error):
                    store.lastError = error.localizedDescription
                }
            }
            .sheet(isPresented: $showURLImport) {
                URLImportSheet { p in path.append(p) }
            }
            .sheet(item: $ask) { req in
                AskView(initialQuery: req.query)
            }
        }
    }

    private var askCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [.indigo, .pink], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                TextField("Ask AI: find an app, or tell me what to change…", text: $query, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($askFocused)
                    .submitLabel(.go)
                    .onSubmit(submit)
                if !query.isEmpty {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(LinearGradient(colors: [.indigo, .pink], startPoint: .leading, endPoint: .trailing), lineWidth: 1.5))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(examples, id: \.self) { ex in
                        Button(ex) {
                            query = ex
                            submit()
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
            }
            Text(AIConfig.isConfigured ? "AI chat is on. Edits always ask before applying." : "Works offline. Add a free AI key in Settings for chat.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var importButtons: some View {
        HStack(spacing: 12) {
            BigButton(title: "From Files", symbol: "folder.fill", color: .blue) { showFileImporter = true }
            BigButton(title: "From URL", symbol: "link", color: .purple) { showURLImport = true }
            BigButton(title: "Find on GitHub", symbol: "magnifyingglass", color: .pink) {
                query = "find "
                askFocused = true
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No IPAs yet").font(.headline)
            Text("Import an .ipa from Files, a link, or search GitHub for open-source iOS apps. You can also use “Open in MT Files” from the Files app or Safari downloads.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func submit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        askFocused = false
        ask = AskRequest(query: q)
    }
}

struct BigButton: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption.bold()).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct ProjectRow: View {
    let project: IPAProject

    var body: some View {
        HStack(spacing: 12) {
            ProjectIcon(project: project, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project.displayName).font(.headline).lineLimit(1)
                    if project.edited {
                        Text("EDITED").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(project.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    Text("v\(project.versionLabel)").font(.caption2).foregroundStyle(.secondary)
                    EncryptionBadge(encrypted: project.encrypted)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
