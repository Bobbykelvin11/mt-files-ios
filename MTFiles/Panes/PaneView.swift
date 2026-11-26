import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct NamePrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let initial: String
    let confirm: String
    let action: (String) -> Void
}

struct URLList: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct MultiExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}

enum ArchiveKinds {
    static let extractable: Set<String> = ["zip", "ipa", "apk", "aab", "jar", "epub", "xapk", "apks", "docx", "xlsx", "pptx", "cbz"]
}

struct PaneView: View {
    @ObservedObject var pane: PaneModel
    let index: Int
    let sideBySide: Bool
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var places: LocationStore

    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var info: FileEntry?
    @State private var confirmDelete: URLList?
    @State private var share: URLList?
    @State private var exportItems: URLList?
    @State private var deepSearch: DeepSearchRequest?

    private var isActive: Bool { app.active == index }
    private var root: Place? { places.root(for: pane.dir) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let e = pane.error {
                Text(e).font(.caption).foregroundStyle(.red).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            list
            if pane.selecting { selectionBar }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: sideBySide ? 12 : 0))
        .overlay {
            if sideBySide {
                RoundedRectangle(cornerRadius: 12).stroke(isActive ? Theme.accent : Color.white.opacity(0.08), lineWidth: isActive ? 1.5 : 1)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { if app.active != index { app.active = index } })
        .onAppear { pane.reload() }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { p in
            TextField("Name", text: $promptText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(p.confirm) { p.action(promptText) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(p.message)
        }
        .confirmationDialog("Delete \(confirmDelete?.urls.count ?? 0) item(s)?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible, presenting: confirmDelete) { list in
            Button("Delete", role: .destructive) {
                let urls = list.urls
                pane.selection.removeAll()
                pane.selecting = false
                app.run("Deleting…") {
                    try FileOps.delete(urls)
                    return "Deleted \(urls.count) item(s)"
                }
            }
        } message: { list in
            Text(list.urls.map(\.lastPathComponent).prefix(6).joined(separator: ", ") + (list.urls.count > 6 ? "…" : "") + "\nThis can't be undone.")
        }
        .sheet(item: $info) { e in
            NavigationStack { FileInfoView(entry: e) }
                .environmentObject(places)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $share) { l in ShareSheet(items: l.urls) }
        .sheet(item: $exportItems) { l in MultiExportPicker(urls: l.urls) }
        .sheet(item: $deepSearch) { req in
            NavigationStack {
                DeepSearchView(root: req.root, initial: req.query) { url in
                    deepSearch = nil
                    pane.go(url.deletingLastPathComponent())
                    pane.selection = [url]
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                locationMenu
                Spacer(minLength: 4)
                Button { pane.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!pane.canGoBack)
                Button { pane.up(root: root?.url) } label: { Image(systemName: "arrow.up") }
                    .disabled(root.map { $0.url.standardizedFileURL.path == pane.dir.standardizedFileURL.path } ?? false)
                sortMenu
                moreMenu
            }
            .font(.system(size: 16, weight: .semibold))
            breadcrumbs
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).font(.caption)
                TextField("Filter (name or *.json)", text: $pane.filter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)
                if !pane.filter.isEmpty {
                    Button { pane.filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                Button {
                    deepSearch = DeepSearchRequest(root: pane.dir, query: pane.filter)
                } label: {
                    Label("Search", systemImage: "magnifyingglass").font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.row, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(isActive && !sideBySide ? Theme.panel : Theme.panel)
    }

    private var locationMenu: some View {
        Menu {
            Section("Locations") {
                ForEach(places.builtIn) { p in
                    Button { pane.go(p.url) } label: { Label(p.name, systemImage: p.symbol) }
                }
            }
            if !places.external.isEmpty {
                Section("Folders from Files") {
                    ForEach(places.external) { p in
                        Button { pane.go(p.url) } label: { Label(p.name, systemImage: p.symbol) }
                    }
                }
            }
            if !places.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(places.favorites) { p in
                        Button {
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: p.url.path, isDirectory: &isDir), isDir.boolValue {
                                pane.go(p.url)
                            } else {
                                pane.go(p.url.deletingLastPathComponent())
                                app.open = OpenRequest(url: p.url)
                            }
                        } label: { Label(p.name, systemImage: p.symbol) }
                    }
                }
            }
            Section {
                Button { app.openFolder(places: places, pane: pane) } label: { Label("Add folder from Files…", systemImage: "folder.badge.plus") }
                if let r = root, r.removable {
                    Button(role: .destructive) {
                        places.removeExternal(r)
                        pane.go(LocationStore.documents)
                    } label: { Label("Remove “\(r.name)” from list", systemImage: "minus.circle") }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: root?.symbol ?? "folder")
                Text(root?.name ?? "Folder").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline.bold())
            .foregroundStyle(isActive ? Theme.accent : .primary)
        }
    }

    private var breadcrumbs: some View {
        let comps = crumbs()
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(comps.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                        Button(c.0) { pane.go(c.1) }
                            .font(.caption.monospaced())
                            .foregroundStyle(i == comps.count - 1 ? .primary : .secondary)
                            .id(i)
                    }
                }
            }
            .onAppear { proxy.scrollTo(comps.count - 1, anchor: .trailing) }
            .onChange(of: pane.dir) { _ in proxy.scrollTo(comps.count - 1, anchor: .trailing) }
        }
    }

    private func crumbs() -> [(String, URL)] {
        guard let r = root else { return [(pane.dir.lastPathComponent, pane.dir)] }
        var out: [(String, URL)] = [(r.url.lastPathComponent.isEmpty ? "/" : (r.id == "docs" ? "MT Files" : r.url.lastPathComponent), r.url)]
        let rootPath = r.url.standardizedFileURL.resolvingSymlinksInPath().path
        let full = pane.dir.standardizedFileURL.resolvingSymlinksInPath().path
        guard full.count > rootPath.count else { return out }
        let rel = full.dropFirst(rootPath.count).split(separator: "/")
        var u = r.url
        for c in rel {
            u = u.appendingPathComponent(String(c), isDirectory: true)
            out.append((String(c), u))
        }
        return out
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $pane.sortKey) {
                ForEach(SortKey.allCases) { k in Text(k.rawValue).tag(k) }
            }
            Toggle("Ascending", isOn: $pane.ascending)
            Toggle("Folders first", isOn: $pane.foldersFirst)
            Toggle("Show hidden files", isOn: $pane.showHidden)
        } label: { Image(systemName: "arrow.up.arrow.down") }
    }

    private var moreMenu: some View {
        Menu {
            Button { ask(title: "New folder", message: "Folder name", initial: "New Folder", confirm: "Create") { name in
                let dir = pane.dir
                app.run("Creating…") { try FileOps.newFolder(name, in: dir); return nil }
            } } label: { Label("New folder", systemImage: "folder.badge.plus") }
            Button { ask(title: "New file", message: "File name with extension", initial: "untitled.txt", confirm: "Create") { name in
                do {
                    let u = try FileOps.newFile(name, in: pane.dir)
                    pane.reload()
                    app.open = OpenRequest(url: u, mode: .text)
                } catch { app.error = error.localizedDescription }
            } } label: { Label("New file", systemImage: "doc.badge.plus") }
            Button { app.importFiles(into: pane) } label: { Label("Import files (copy)…", systemImage: "square.and.arrow.down") }
            Button { app.openInPlace(places: places, pane: pane) } label: { Label("Open files in place…", systemImage: "doc.viewfinder") }
            Button { app.openFolder(places: places, pane: pane) } label: { Label("Open a folder from Files…", systemImage: "folder.badge.person.crop") }
            Divider()
            Button { pane.selecting.toggle(); if !pane.selecting { pane.selection.removeAll() } } label: {
                Label(pane.selecting ? "Done selecting" : "Select", systemImage: "checkmark.circle")
            }
            Button { pane.go(app.other(of: index).dir) } label: { Label("Go to other pane's folder", systemImage: "arrow.left.arrow.right") }
            Button { places.toggleFavorite(pane.dir) } label: {
                Label(places.isFavorite(pane.dir) ? "Remove folder from favorites" : "Add folder to favorites", systemImage: "star")
            }
            Button { info = FileEntry(url: pane.dir) } label: { Label("Folder info", systemImage: "info.circle") }
            Button { pane.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Divider()
            Button { app.assistantContext = app.context(for: index) } label: { Label("Ask AI about this folder", systemImage: "sparkles") }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    // MARK: List

    private var list: some View {
        let items = pane.visible
        return List {
            if items.isEmpty && pane.error == nil {
                Text(pane.filter.isEmpty ? "Empty folder" : "No matches in this folder. Tap Search to look in subfolders.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Theme.panel)
            }
            ForEach(items) { e in
                FileRow(entry: e, selecting: pane.selecting, selected: pane.selection.contains(e.url), favorite: places.isFavorite(e.url))
                    .contentShape(Rectangle())
                    .onTapGesture { tap(e) }
                    .contextMenu { contextMenu(e) }
                    .listRowBackground(pane.selection.contains(e.url) ? Theme.accent.opacity(0.18) : Theme.panel)
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { pane.reload() }
    }

    private func tap(_ e: FileEntry) {
        app.active = index
        if pane.selecting { pane.toggle(e.url); return }
        if e.isDirectory && !e.url.pathExtension.lowercased().hasSuffix("app") {
            pane.go(e.url)
        } else if e.isDirectory {
            pane.go(e.url)
        } else {
            app.open = OpenRequest(url: e.url)
        }
    }

    @ViewBuilder
    private func contextMenu(_ e: FileEntry) -> some View {
        if !e.isDirectory {
            Button { app.open = OpenRequest(url: e.url) } label: { Label("Open", systemImage: "arrow.up.forward.square") }
            Menu {
                Button("Text editor") { app.open = OpenRequest(url: e.url, mode: .text) }
                Button("Hex viewer") { app.open = OpenRequest(url: e.url, mode: .hex) }
                Button("Quick Look") { app.open = OpenRequest(url: e.url, mode: .quicklook) }
                if ArchiveKinds.extractable.contains(e.ext) { Button("Archive browser") { app.open = OpenRequest(url: e.url, mode: .archive) } }
            } label: { Label("Open as…", systemImage: "doc.viewfinder") }
        }
        Button { ask(title: "Rename", message: e.name, initial: e.name, confirm: "Rename") { name in
            do { _ = try FileOps.rename(e.url, to: name); app.reloadAll() } catch { app.error = error.localizedDescription }
        } } label: { Label("Rename", systemImage: "pencil") }
        Button { transferOne(e.url, move: false) } label: { Label("Copy to other pane", systemImage: "doc.on.doc") }
        Button { transferOne(e.url, move: true) } label: { Label("Move to other pane", systemImage: "arrow.right.doc.on.clipboard") }
        Button {
            let u = e.url, dir = pane.dir
            app.run("Duplicating…") { try FileOps.copy([u], to: dir); return nil }
        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button {
            let u = e.url, dir = pane.dir
            app.run("Zipping…") { let z = try FileOps.zip([u], in: dir); return "Created \(z.lastPathComponent)" }
        } label: { Label("Compress to .zip", systemImage: "doc.zipper") }
        if ArchiveKinds.extractable.contains(e.ext) {
            Button {
                let u = e.url, dir = pane.dir
                app.run("Extracting…") { let d = try FileOps.unzip(u, into: dir); return "Extracted to \(d.lastPathComponent)" }
            } label: { Label("Extract here", systemImage: "arrow.down.doc") }
            Button {
                let u = e.url, dir = app.other(of: index).dir
                app.run("Extracting…") { let d = try FileOps.unzip(u, into: dir); return "Extracted to other pane: \(d.lastPathComponent)" }
            } label: { Label("Extract to other pane", systemImage: "arrow.right.doc.on.clipboard") }
        }
        Divider()
        Button { info = e } label: { Label("Info & checksums", systemImage: "info.circle") }
        Button { places.toggleFavorite(e.url) } label: {
            Label(places.isFavorite(e.url) ? "Remove favorite" : "Add to favorites", systemImage: places.isFavorite(e.url) ? "star.slash" : "star")
        }
        Button { share = URLList(urls: [e.url]) } label: { Label("Share / Open in…", systemImage: "square.and.arrow.up") }
        Button { exportItems = URLList(urls: [e.url]) } label: { Label("Save to Files…", systemImage: "folder") }
        Button { app.assistantContext = app.context(for: index, file: e.url) } label: { Label("Ask AI about this", systemImage: "sparkles") }
        Button { pane.selecting = true; pane.selection.insert(e.url) } label: { Label("Select", systemImage: "checkmark.circle") }
        Divider()
        Button(role: .destructive) { confirmDelete = URLList(urls: [e.url]) } label: { Label("Delete", systemImage: "trash") }
    }

    private func transferOne(_ url: URL, move: Bool) {
        pane.selection = [url]
        app.transfer(from: index, move: move)
    }

    private var selectionBar: some View {
        let count = pane.selection.count
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("\(count) selected").font(.caption.bold()).padding(.trailing, 4)
                bar("All", "checkmark.circle.badge.questionmark") { pane.selectAll() }
                bar("Copy →", "doc.on.doc") { app.transfer(from: index, move: false) }.disabled(count == 0)
                bar("Move →", "arrow.right.doc.on.clipboard") { app.transfer(from: index, move: true) }.disabled(count == 0)
                bar("Zip", "doc.zipper") {
                    let items = pane.selectedURLs, dir = pane.dir
                    ask(title: "Zip \(items.count) item(s)", message: "Archive name", initial: items.count == 1 ? items[0].deletingPathExtension().lastPathComponent + ".zip" : "Archive.zip", confirm: "Zip") { name in
                        pane.selecting = false
                        pane.selection.removeAll()
                        app.run("Zipping…") { let z = try FileOps.zip(items, name: name, in: dir); return "Created \(z.lastPathComponent)" }
                    }
                }.disabled(count == 0)
                bar("Rename", "character.cursor.ibeam") {
                    let items = pane.selectedURLs
                    ask(title: "Batch rename \(items.count)", message: "Use # for the number, e.g. photo_# or img_###", initial: "file_#", confirm: "Rename") { t in
                        pane.selecting = false
                        pane.selection.removeAll()
                        app.run("Renaming…") { let r = try FileOps.batchRename(items, template: t); return "Renamed \(r.count) item(s)" }
                    }
                }.disabled(count == 0)
                bar("Share", "square.and.arrow.up") { share = URLList(urls: pane.selectedURLs) }.disabled(count == 0)
                bar("AI", "sparkles") { app.assistantContext = app.context(for: index) }
                bar("Delete", "trash") { confirmDelete = URLList(urls: pane.selectedURLs) }.disabled(count == 0).tint(.red)
                bar("Done", "xmark") { pane.selecting = false; pane.selection.removeAll() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Theme.row)
    }

    private func bar(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .frame(minWidth: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }

    private func ask(title: String, message: String, initial: String, confirm: String, _ action: @escaping (String) -> Void) {
        promptText = initial
        prompt = NamePrompt(title: title, message: message, initial: initial, confirm: confirm, action: action)
    }

}

struct FileRow: View {
    let entry: FileEntry
    let selecting: Bool
    let selected: Bool
    let favorite: Bool

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .font(.system(size: 18))
            }
            Image(systemName: entry.symbol)
                .font(.system(size: 17))
                .foregroundStyle(entry.tint)
                .frame(width: 34, height: 34)
                .background(entry.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.isDirectory && !selecting {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .opacity(entry.isHidden ? 0.6 : 1)
    }

    private var subtitle: String {
        let date = entry.modified.map { FileRow.df.string(from: $0) } ?? ""
        if entry.isDirectory { return date.isEmpty ? "Folder" : "Folder · \(date)" }
        return [formatBytes(entry.size), date].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
