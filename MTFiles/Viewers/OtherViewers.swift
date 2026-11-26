import QuickLook
import SwiftUI
import UIKit

// MARK: Hex viewer

struct HexView: View {
    let url: URL
    @State private var data: Data?
    @State private var error: String?
    @State private var jump = ""
    @State private var target: Int?
    private let bytesPerRow = 16
    private let maxRows = 2_000_000

    var body: some View {
        Group {
            if let data {
                let rows = min((data.count + bytesPerRow - 1) / bytesPerRow, maxRows)
                VStack(spacing: 0) {
                    HStack {
                        Text("\(formatBytes(Int64(data.count))) · \(data.count) bytes").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        TextField("Go to offset (0x1F0 or 496)", text: $jump)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .frame(maxWidth: 210)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { goToOffset() }
                    }
                    .padding(8)
                    .background(Theme.panel)
                    ScrollViewReader { proxy in
                        List(0..<rows, id: \.self) { r in
                            Text(line(data, row: r))
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 4))
                                .listRowBackground(r == target ? Theme.accent.opacity(0.25) : (r % 2 == 0 ? Theme.bg : Theme.panel))
                                .listRowSeparator(.hidden)
                                .id(r)
                        }
                        .listStyle(.plain)
                        .environment(\.defaultMinListRowHeight, 16)
                        .onChange(of: target) { t in if let t { proxy.scrollTo(t, anchor: .center) } }
                    }
                    if data.count > maxRows * bytesPerRow {
                        Text("Showing the first \(formatBytes(Int64(maxRows * bytesPerRow))).").font(.caption2).padding(4)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.red).padding()
            } else {
                ProgressView()
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { self.error = error.localizedDescription }
        }
    }

    private func goToOffset() {
        let t = jump.trimmingCharacters(in: .whitespaces).lowercased()
        let v: Int? = t.hasPrefix("0x") ? Int(t.dropFirst(2), radix: 16) : Int(t)
        if let v { target = v / bytesPerRow }
    }

    private func line(_ d: Data, row: Int) -> String {
        let start = row * bytesPerRow
        let end = min(start + bytesPerRow, d.count)
        var hex = ""
        var ascii = ""
        hex.reserveCapacity(52)
        for i in start..<start + bytesPerRow {
            if i < end {
                let b = d[d.startIndex + i]
                hex += String(format: "%02X ", b)
                ascii.append((b >= 32 && b < 127) ? Character(UnicodeScalar(b)) : ".")
            } else {
                hex += "   "
            }
            if i - start == 7 { hex += " " }
        }
        return String(format: "%08X  ", start) + hex + " " + ascii
    }
}

// MARK: Image viewer

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 10
        sv.delegate = context.coordinator
        sv.backgroundColor = .black
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.frame = sv.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sv.addSubview(iv)
        context.coordinator.imageView = iv
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(tap)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            sv.setZoomScale(sv.zoomScale > 1 ? 1 : 3, animated: true)
        }
    }
}

struct ImageViewer: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale)) px")
                            .font(.caption).padding(6).background(.ultraThinMaterial, in: Capsule()).padding()
                    }
            } else {
                QuickLookView(url: url)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { image = UIImage(contentsOfFile: url.path) }
    }
}

// MARK: Quick Look (audio, video, PDF, Office, 3D…)

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

// MARK: Archive browser

struct ArchiveBrowser: View {
    let url: URL
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [FileOps.ArchiveItem] = []
    @State private var error: String?
    @State private var filter = ""
    @State private var loading = true

    var body: some View {
        List {
            Section {
                Button { extract(to: url.deletingLastPathComponent()) } label: { Label("Extract here", systemImage: "arrow.down.doc") }
                Button { extract(to: app.otherPane.dir) } label: { Label("Extract to other pane (\(app.otherPane.dir.lastPathComponent))", systemImage: "arrow.right.doc.on.clipboard") }
                if url.pathExtension.lowercased() == "ipa" {
                    Button { openIPA() } label: { Label("Edit in IPA editor", systemImage: "app.badge") }
                }
            } footer: {
                if !items.isEmpty {
                    let total = items.reduce(Int64(0)) { $0 + $1.size }
                    Text("\(items.count) entries\(items.count >= 5000 ? "+" : "") · \(formatBytes(total)) uncompressed")
                }
            }
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            Section {
                ForEach(items.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }.prefix(3000)) { i in
                    HStack {
                        Image(systemName: i.isDirectory ? "folder" : "doc").foregroundStyle(i.isDirectory ? Theme.accent : .secondary)
                        Text(i.path).font(.caption.monospaced()).lineLimit(2)
                        Spacer()
                        if !i.isDirectory { Text(formatBytes(i.size)).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter entries")
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let u = url
            let r = await Task.detached { () -> Result<[FileOps.ArchiveItem], Error> in
                do { return .success(try FileOps.archiveContents(u)) } catch { return .failure(error) }
            }.value
            loading = false
            switch r {
            case .success(let list): items = list
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    private func extract(to dir: URL) {
        let u = url
        app.run("Extracting \(u.lastPathComponent)…") {
            let d = try FileOps.unzip(u, into: dir)
            return "Extracted to \(d.lastPathComponent)"
        }
    }

    private func openIPA() {
        app.open = OpenRequest(url: url, mode: .auto)
    }
}

// MARK: Plist viewer

struct PlistScreen: View {
    let url: URL
    @EnvironmentObject var app: AppModel
    @State private var mode = 0
    @State private var xml: String?
    @State private var format: PropertyListSerialization.PropertyListFormat = .xml
    @State private var isDict = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                Text("Keys").tag(0)
                Text("XML source").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(8)
            .background(Theme.panel)
            if let error {
                Text(error).foregroundStyle(.red).padding()
                Spacer()
            } else if let xml {
                if mode == 0 && isDict {
                    PlistEditorView(plistURL: url) { app.reloadAll() }
                } else if mode == 0 {
                    Text("Root isn't a dictionary — use XML source.").foregroundStyle(.secondary).padding()
                    Spacer()
                } else {
                    EditorScreen(url: url, plistFormat: format, initialOverride: xml, showClose: false)
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { error = "Couldn't read file"; return }
        guard let r = PlistIO.xmlString(from: data) else { error = "Not a valid property list"; return }
        xml = r.0
        format = r.1
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        isDict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: &fmt)) is [String: Any]
    }
}
