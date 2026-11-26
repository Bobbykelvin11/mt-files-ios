import SwiftUI
import UIKit

struct FileInfoView: View {
    let entry: FileEntry
    @Environment(\.dismiss) private var dismiss
    @State private var sha256 = ""
    @State private var md5 = ""
    @State private var sha1 = ""
    @State private var hashing = false
    @State private var stats: (size: Int64, files: Int, folders: Int)?
    @State private var copied: String?

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: entry.symbol).font(.title2).foregroundStyle(entry.tint)
                        .frame(width: 48, height: 48)
                        .background(entry.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    Text(entry.name).font(.headline).textSelection(.enabled)
                }
            }
            Section("Details") {
                LabeledContent("Kind", value: entry.isDirectory ? "Folder" : (entry.ext.isEmpty ? "File" : entry.ext.uppercased() + " file"))
                if entry.isDirectory {
                    if let s = stats {
                        LabeledContent("Size", value: formatBytes(s.size))
                        LabeledContent("Contains", value: "\(s.files) files, \(s.folders) folders")
                    } else {
                        LabeledContent("Size") { ProgressView() }
                    }
                } else {
                    LabeledContent("Size", value: "\(formatBytes(entry.size)) (\(entry.size) bytes)")
                }
                if let c = entry.created { LabeledContent("Created", value: Self.df.string(from: c)) }
                if let m = entry.modified { LabeledContent("Modified", value: Self.df.string(from: m)) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Path").font(.caption).foregroundStyle(.secondary)
                    Text(entry.url.path).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if !entry.isDirectory {
                Section {
                    if hashing {
                        HStack { ProgressView(); Text("Computing checksums…").font(.footnote) }
                    } else if sha256.isEmpty {
                        Button { computeHashes() } label: { Label("Compute SHA-256 / SHA-1 / MD5", systemImage: "number.square") }
                    } else {
                        hashRow("SHA-256", sha256)
                        hashRow("SHA-1", sha1)
                        hashRow("MD5", md5)
                    }
                } header: { Text("Checksums") } footer: {
                    if let copied { Text("Copied \(copied)") }
                }
            }
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            if entry.isDirectory {
                let u = entry.url
                let s = await Task.detached { FileOps.directoryStats(u) }.value
                stats = s
            } else if entry.size < 50_000_000 {
                computeHashes()
            }
        }
    }

    private func hashRow(_ label: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = label
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption.bold()).foregroundStyle(.secondary)
                Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary).multilineTextAlignment(.leading)
            }
        }
    }

    private func computeHashes() {
        hashing = true
        let u = entry.url
        Task {
            let r = await Task.detached { try? FileOps.hashes(u) }.value
            hashing = false
            if let r { sha256 = r.sha256; md5 = r.md5; sha1 = r.sha1 } else { sha256 = "Couldn't read file" }
        }
    }
}

struct DeepSearchRequest: Identifiable {
    let id = UUID()
    let root: URL
    let query: String
}

struct DeepSearchView: View {
    let root: URL
    let initial: String
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var content = ""
    @State private var results: [URL] = []
    @State private var searching = false
    @State private var searched = false

    var body: some View {
        List {
            Section {
                TextField("Name or pattern, e.g. *.json", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(run)
                TextField("Containing text (optional)", text: $content)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(run)
                Button { run() } label: { HStack { Label("Search subfolders", systemImage: "magnifyingglass"); if searching { Spacer(); ProgressView() } } }
                    .disabled(searching)
            } footer: {
                Text("Searching inside \(root.lastPathComponent) and all its subfolders.")
            }
            if searched {
                Section("\(results.count) result(s)\(results.count >= 500 ? " (first 500)" : "")") {
                    ForEach(results, id: \.self) { u in
                        Button { onPick(u) } label: {
                            let e = FileEntry(url: u)
                            HStack {
                                Image(systemName: e.symbol).foregroundStyle(e.tint)
                                VStack(alignment: .leading) {
                                    Text(u.lastPathComponent).foregroundStyle(.primary).lineLimit(1)
                                    Text(relative(u)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onAppear { if query.isEmpty { query = initial } }
    }

    private func relative(_ u: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = u.deletingLastPathComponent().standardizedFileURL.path
        return p.hasPrefix(r) ? "." + p.dropFirst(r.count) : p
    }

    private func run() {
        searching = true
        let q = query, c = content, r = root
        Task {
            let found = await Task.detached { FileOps.search(r, pattern: q, contentQuery: c.isEmpty ? nil : c) }.value
            results = found
            searching = false
            searched = true
        }
    }
}

struct DualPaneView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 700 {
                HStack(spacing: 6) {
                    PaneView(pane: app.left, index: 0, sideBySide: true)
                    PaneView(pane: app.right, index: 1, sideBySide: true)
                }
                .padding(6)
            } else {
                VStack(spacing: 0) {
                    switcher
                    TabView(selection: $app.active) {
                        PaneView(pane: app.left, index: 0, sideBySide: false).tag(0)
                        PaneView(pane: app.right, index: 1, sideBySide: false).tag(1)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
        }
        .background(Theme.bg)
    }

    private var switcher: some View {
        HStack(spacing: 6) {
            SwitcherButton(pane: app.left, index: 0)
            SwitcherButton(pane: app.right, index: 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.bg)
    }
}

private struct SwitcherButton: View {
    @ObservedObject var pane: PaneModel
    let index: Int
    @EnvironmentObject var app: AppModel

    var body: some View {
        Button {
            withAnimation { app.active = index }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: index == 0 ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled")
                Text(pane.dir.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if !pane.selection.isEmpty { Text("\(pane.selection.count)").font(.caption2.bold()).padding(.horizontal, 5).background(Theme.accent, in: Capsule()).foregroundStyle(.black) }
            }
            .font(.caption.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(app.active == index ? Theme.accent.opacity(0.22) : Theme.row, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(app.active == index ? Theme.accent : .secondary)
        }
        .buttonStyle(.plain)
    }
}
