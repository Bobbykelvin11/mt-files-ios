import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var exports: [URL] = []
    @State private var share: IdentifiableURL?
    @State private var saveToFiles: IdentifiableURL?
    @State private var confirmDelete: IPAProject?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.projects.isEmpty {
                        Text("Imported IPAs appear here.").foregroundStyle(.secondary)
                    }
                    ForEach(store.projects) { p in
                        NavigationLink(value: p) { ProjectRow(project: p) }
                            .swipeActions {
                                Button(role: .destructive) { confirmDelete = p } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text("Projects (\(store.projects.count))")
                }

                Section {
                    if exports.isEmpty {
                        Text("Repacked IPAs appear here, and in the Files app under On My iPhone › MT Files › Exports.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(exports, id: \.self) { url in
                        HStack {
                            Image(systemName: "doc.zipper").foregroundStyle(.purple)
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent).font(.subheadline).lineLimit(1)
                                Text(fileSize(url)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button { share = IdentifiableURL(url: url) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                Button { saveToFiles = IdentifiableURL(url: url) } label: { Label("Save to Files", systemImage: "folder") }
                                Button {
                                    Task {
                                        do { try await store.importIPA(from: url) } catch { store.lastError = error.localizedDescription }
                                    }
                                } label: { Label("Open as new project", systemImage: "plus.square.on.square") }
                            } label: {
                                Image(systemName: "ellipsis.circle").font(.title3)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                try? FileManager.default.removeItem(at: url)
                                reloadExports()
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("Exported IPAs")
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: IPAProject.self) { p in
                ProjectDetailView(projectID: p.id)
            }
            .onAppear(perform: reloadExports)
            .refreshable { reloadExports() }
            .onChange(of: store.revision) { _ in reloadExports() }
            .sheet(item: $share) { item in ShareSheet(items: [item.url]) }
            .sheet(item: $saveToFiles) { item in ExportToFilesPicker(url: item.url) }
            .confirmationDialog("Delete this project?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let p = confirmDelete { store.delete(p) }
                    confirmDelete = nil
                }
            } message: {
                Text("The unpacked app and your edits will be removed. Exported IPAs are kept.")
            }
        }
    }

    private func reloadExports() { exports = store.exportedFiles() }

    private func fileSize(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return formatBytes(Int64(size))
    }
}
