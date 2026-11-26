import SwiftUI

enum ViewerKind {
    case text, plist, image, hex, quicklook, archive, ipa

    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "ico"]
    static let quickLookExt: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp", "mp3", "m4a", "wav", "aac", "flac", "caf", "aiff", "aif", "ogg", "opus", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "rtf", "rtfd", "usdz", "reality", "epub", "csv", "vcf", "ics"]
    static let archiveExt: Set<String> = ["zip", "apk", "aab", "jar", "xapk", "apks", "cbz"]

    static func resolve(_ url: URL, mode: ViewerMode) -> ViewerKind {
        switch mode {
        case .text: return .text
        case .hex: return .hex
        case .quicklook: return .quicklook
        case .archive: return .archive
        case .plistKeys: return .plist
        case .auto: break
        }
        let ext = url.pathExtension.lowercased()
        if ext == "ipa" { return .ipa }
        if ext == "plist" { return .plist }
        if ext == "strings" || ext == "entitlements" {
            return FileOps.isLikelyText(url) ? .text : .plist
        }
        if imageExt.contains(ext) { return .image }
        if ext == "csv" { return .text }
        if quickLookExt.contains(ext) { return .quicklook }
        if archiveExt.contains(ext) { return .archive }
        return FileOps.isLikelyText(url) ? .text : .hex
    }
}

struct ViewerHost: View {
    let request: OpenRequest
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let kind = ViewerKind.resolve(request.url, mode: request.mode)
        NavigationStack {
            content(kind)
                .toolbar {
                    if kind != .text {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { app.open = nil; dismiss() }
                        }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func content(_ kind: ViewerKind) -> some View {
        switch kind {
        case .text: EditorScreen(url: request.url)
        case .plist: PlistScreen(url: request.url)
        case .image: ImageViewer(url: request.url)
        case .hex: HexView(url: request.url)
        case .quicklook: QuickLookView(url: request.url).ignoresSafeArea(edges: .bottom).navigationTitle(request.url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
        case .archive: ArchiveBrowser(url: request.url)
        case .ipa: IPAOpenView(url: request.url)
        }
    }
}

struct IPAOpenView: View {
    let url: URL
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LibraryStore
    @State private var projectID: UUID?
    @State private var showProject = false
    @State private var importing = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "app.badge").font(.title).foregroundStyle(.orange)
                        .frame(width: 54, height: 54)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent).font(.headline)
                        Text(formatBytes(FileEntry(url: url).size)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button { edit() } label: {
                    HStack { Label("Edit in IPA editor", systemImage: "slider.horizontal.3"); if importing { Spacer(); ProgressView() } }
                }
                .disabled(importing)
                NavigationLink { ArchiveBrowser(url: url) } label: { Label("Browse contents", systemImage: "doc.zipper") }
                Button {
                    let u = url, dir = url.deletingLastPathComponent()
                    app.run("Extracting…") { let d = try FileOps.unzip(u, into: dir); return "Extracted to \(d.lastPathComponent)" }
                } label: { Label("Extract here", systemImage: "arrow.down.doc") }
            } footer: {
                Text("The IPA editor changes name, icon, bundle ID, version and Info.plist, lets you replace files inside, and repacks an unsigned IPA to sign with Sideloadly or SideStore. Encrypted App Store apps can't be modified.")
            }
        }
        .navigationTitle("IPA")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showProject) {
            if let id = projectID { ProjectDetailView(projectID: id) }
        }
    }

    private func edit() {
        importing = true
        Task {
            do {
                let p = try await store.importIPA(from: url)
                projectID = p.id
                showProject = true
            } catch {
                app.error = error.localizedDescription
            }
            importing = false
        }
    }
}
