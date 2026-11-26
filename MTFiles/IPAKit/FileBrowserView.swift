import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let isDirectory: Bool
    let size: Int64
}

struct FileBrowserView: View {
    let directory: URL
    let title: String
    var onChange: () -> Void = {}

    @State private var items: [FileItem] = []
    @State private var pick: PickRequest?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var confirmDelete: FileItem?
    @State private var error: String?

    var body: some View {
        List {
            if items.isEmpty {
                Text("Empty folder").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                NavigationLink {
                    if item.isDirectory {
                        FileBrowserView(directory: item.url, title: item.url.lastPathComponent, onChange: onChange)
                    } else {
                        FileDetailView(url: item.url, onChange: {
                            reload()
                            onChange()
                        })
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: symbol(for: item))
                            .foregroundStyle(item.isDirectory ? Color.blue : Color.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.lastPathComponent).font(.subheadline).lineLimit(1)
                            if !item.isDirectory {
                                Text(formatBytes(item.size)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { confirmDelete = item } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { addFiles() } label: { Label("Add files…", systemImage: "doc.badge.plus") }
                    Button { addFolder() } label: { Label("Add a folder…", systemImage: "folder.badge.plus") }
                    Button { showNewFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear(perform: reload)
        .documentPicker($pick)
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let n = newFolderName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty {
                    try? FileManager.default.createDirectory(at: directory.appendingPathComponent(n), withIntermediateDirectories: true)
                    reload()
                    onChange()
                }
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .confirmationDialog("Delete \(confirmDelete?.url.lastPathComponent ?? "")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = confirmDelete {
                    do { try FileManager.default.removeItem(at: item.url) } catch { self.error = error.localizedDescription }
                    reload()
                    onChange()
                }
                confirmDelete = nil
            }
        } message: {
            Text("Deleting the wrong file can stop the app from launching.")
        }
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func copyIn(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            do {
                try FilePicking.coordinatedCopy(url, to: directory.appendingPathComponent(url.lastPathComponent))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        reload()
        onChange()
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }

    private func addFiles() {
        pick = PickRequest(mode: .importCopy) { urls in copyIn(urls) }
    }

    private func addFolder() {
        pick = PickRequest(mode: .folder) { urls in copyIn(urls) }
    }

    private func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        items = urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return FileItem(url: url, isDirectory: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0))
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.url.lastPathComponent.localizedCaseInsensitiveCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }

    private func symbol(for item: FileItem) -> String {
        if item.isDirectory {
            switch item.url.pathExtension.lowercased() {
            case "framework": return "shippingbox"
            case "appex": return "puzzlepiece.extension"
            case "bundle": return "archivebox"
            case "lproj": return "globe"
            default: return "folder.fill"
            }
        }
        switch FileKind.of(item.url) {
        case .image: return "photo"
        case .plist: return "list.bullet.rectangle"
        case .text: return "doc.text"
        case .binary: return "doc"
        }
    }
}

enum FileKind {
    case image, plist, text, binary

    static let textExtensions: Set<String> = ["txt", "json", "xml", "html", "htm", "js", "css", "md", "strings", "stringsdict", "csv", "yml", "yaml", "svg", "entitlements", "xcconfig", "log", "ini", "conf", "lua", "py", "sh"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff"]

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "plist" { return .plist }
        if textExtensions.contains(ext) { return .text }
        return .binary
    }
}
