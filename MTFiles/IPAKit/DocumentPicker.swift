import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum PickMode {
    /// The system copies the picked items into the app (works for anything, incl. iCloud placeholders).
    case importCopy
    /// Access the original items in place (security-scoped).
    case openInPlace
    /// Pick a folder (security-scoped, in place).
    case folder
}

struct PickRequest: Identifiable {
    let id = UUID()
    let mode: PickMode
    var types: [UTType]? = nil
    var multiple: Bool = true
    let handler: ([URL]) -> Void
}

enum FilePicking {
    /// Every kind of file. Files are validated after picking, so nothing is greyed out.
    static var allFileTypes: [UTType] {
        var t: [UTType] = [.item, .content, .data, .archive, .zip, .package, .image, .text, .sourceCode, .audiovisualContent, .pdf, .propertyList, .json]
        t.append(UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .zip))
        for e in ["ipa", "apk", "plist", "zip", "deb", "dylib", "mobileprovision", "car", "nib", "strings"] {
            if let u = UTType(filenameExtension: e) { t.append(u) }
        }
        var seen = Set<String>()
        return t.filter { seen.insert($0.identifier).inserted }
    }

    static func types(for request: PickRequest) -> [UTType] {
        switch request.mode {
        case .folder: return [.folder, .directory]
        case .openInPlace: return (request.types ?? allFileTypes) + [.folder, .directory]
        case .importCopy: return request.types ?? allFileTypes
        }
    }

    /// Copies a picked (possibly security-scoped, possibly iCloud) item using NSFileCoordinator.
    static func coordinatedCopy(_ src: URL, to dest: URL) throws {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        var coordError: NSError?
        var innerError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: src, options: [.withoutChanges], error: &coordError) { readURL in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: readURL, to: dest)
            } catch {
                innerError = error
            }
        }
        if let e = coordError ?? innerError {
            throw StudioError.message("Couldn't read “\(src.lastPathComponent)”: \(e.localizedDescription)")
        }
    }

    /// True if the file starts with the ZIP signature (an .ipa is a zip).
    static func isZip(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = h.readData(ofLength: 4)
        return d.count == 4 && d[d.startIndex] == 0x50 && d[d.startIndex + 1] == 0x4B && (d[d.startIndex + 2] == 0x03 || d[d.startIndex + 2] == 0x05)
    }

    static func looksLikeIPA(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "ipa" || ext == "tipa" { return true }
        return isZip(url)
    }

    /// Finds .ipa files inside a picked folder (security-scoped access is started by the caller).
    static func ipaFiles(in folder: URL, limit: Int = 50) -> [URL] {
        guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where ["ipa", "tipa"].contains(u.pathExtension.lowercased()) {
            out.append(u)
            if out.count >= limit { break }
        }
        return out
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    let request: PickRequest
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: FilePicking.types(for: request), asCopy: request.mode == .importCopy)
        vc.allowsMultipleSelection = request.mode != .folder && request.multiple
        vc.shouldShowFileExtensions = true
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ p: DocumentPicker) { parent = p }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let handler = parent.request.handler
            let done = parent.onDone
            done()
            // Let the sheet finish dismissing before the handler presents anything.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { handler(urls) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onDone()
        }
    }
}

extension View {
    /// Presents a UIKit document picker (reliable even when several pickers exist in one screen hierarchy).
    func documentPicker(_ request: Binding<PickRequest?>) -> some View {
        sheet(item: request) { req in
            DocumentPicker(request: req) { request.wrappedValue = nil }
                .ignoresSafeArea()
        }
    }
}
