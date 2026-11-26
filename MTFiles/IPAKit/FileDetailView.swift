import SwiftUI
import UniformTypeIdentifiers

struct FileDetailView: View {
    let url: URL
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var originalText = ""
    @State private var plistFormat: PropertyListSerialization.PropertyListFormat?
    @State private var image: UIImage?
    @State private var hexPreview = ""
    @State private var editable = false
    @State private var size: Int64 = 0
    @State private var pick: PickRequest?
    @State private var confirmDelete = false
    @State private var share: IdentifiableURL?
    @State private var message: String?

    var body: some View {
        Group {
            if let image {
                ScrollView {
                    VStack(spacing: 12) {
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .frame(maxWidth: 320, maxHeight: 320)
                            .background(Color(.secondarySystemBackground))
                        Text("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale)) px · \(formatBytes(size))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                }
            } else if editable {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Binary file · \(formatBytes(size))").font(.headline)
                        Text("First bytes:").font(.caption).foregroundStyle(.secondary)
                        Text(hexPreview).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if editable && text != originalText {
                    Button("Save", action: save)
                }
                Menu {
                    Button { pickReplacement() } label: { Label("Replace with file…", systemImage: "arrow.triangle.2.circlepath") }
                    Button { share = IdentifiableURL(url: url) } label: { Label("Share / Export", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear(perform: load)
        .sheet(item: $share) { item in ShareSheet(items: [item.url]) }
        .documentPicker($pick)
        .confirmationDialog("Delete this file?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? FileManager.default.removeItem(at: url)
                onChange()
                dismiss()
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func pickReplacement() {
        pick = PickRequest(mode: .importCopy, multiple: false) { urls in
            guard let src = urls.first else { return }
            do {
                try FilePicking.coordinatedCopy(src, to: url)
                load()
                onChange()
                message = "Replaced with \(src.lastPathComponent)"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func load() {
        image = nil
        editable = false
        plistFormat = nil
        size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let data = try? Data(contentsOf: url) else { return }
        let kind = FileKind.of(url)

        if kind == .image, let img = UIImage(data: data) {
            image = img
            return
        }
        // Plists (and binary .strings) -> editable XML
        if kind == .plist || url.pathExtension.lowercased() == "strings" || data.starts(with: Array("bplist".utf8)) {
            if let converted = PlistIO.xmlString(from: data) {
                text = converted.0
                originalText = converted.0
                plistFormat = converted.1
                editable = true
                return
            }
        }
        if data.count <= 2_000_000, let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
            if kind == .text || !str.contains("\u{0}") {
                text = str
                originalText = str
                editable = true
                return
            }
        }
        hexPreview = data.prefix(512).enumerated().map { i, b in
            String(format: "%02x", b) + ((i + 1) % 16 == 0 ? "\n" : " ")
        }.joined()
    }

    private func save() {
        do {
            if let fmt = plistFormat {
                guard let xml = text.data(using: .utf8) else { throw StudioError.message("Invalid text") }
                let obj = try PropertyListSerialization.propertyList(from: xml, options: [], format: nil)
                let out = try PropertyListSerialization.data(fromPropertyList: obj, format: fmt == .openStep ? .xml : fmt, options: 0)
                try out.write(to: url, options: .atomic)
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            originalText = text
            onChange()
            message = "Saved"
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
