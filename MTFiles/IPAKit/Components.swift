import SafariServices
import SwiftUI
import UIKit

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ExportToFilesPicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}

struct BusyOverlay: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(message).font(.callout).multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(40)
        }
    }
}

struct AppIconView: View {
    let image: UIImage?
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "app.dashed").font(.system(size: size * 0.45)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).stroke(.black.opacity(0.08)))
    }
}

struct ProjectIcon: View {
    @EnvironmentObject var store: LibraryStore
    let project: IPAProject
    var size: CGFloat = 56

    var body: some View {
        // `revision` forces a reload when files change.
        let _ = store.revision
        AppIconView(image: store.icon(for: project), size: size)
    }
}

struct EncryptionBadge: View {
    let encrypted: Bool?
    var body: some View {
        switch encrypted {
        case .some(true):
            Label("Encrypted", systemImage: "lock.fill").font(.caption2.bold()).foregroundStyle(.red)
        case .some(false):
            Label("Not encrypted", systemImage: "lock.open").font(.caption2).foregroundStyle(.green)
        case .none:
            Label("Unknown", systemImage: "questionmark.circle").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Sheet to import an IPA from a direct URL, with progress.
struct URLImportSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloader = Downloader()
    @State private var urlText = ""
    @State private var error: String?
    var onImported: (IPAProject) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/MyApp.ipa", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste from Clipboard") {
                        if let s = UIPasteboard.general.string { urlText = s }
                    }
                } header: {
                    Text("Direct link to an .ipa file")
                } footer: {
                    Text("Use links to apps you own or open-source releases (for example a GitHub release asset).")
                }
                if downloader.isDownloading {
                    Section("Downloading") {
                        ProgressView(value: downloader.progress)
                        Text(downloader.statusText).font(.caption).foregroundStyle(.secondary)
                        Button("Cancel", role: .destructive) { downloader.cancel() }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Import from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { start() }
                        .disabled(downloader.isDownloading || URL(string: urlText.trimmingCharacters(in: .whitespaces))?.scheme == nil)
                }
            }
        }
    }

    private func start() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else { return }
        error = nil
        Task {
            do {
                let (file, name) = try await downloader.download(url)
                let p = try await store.importIPA(from: file, suggestedName: name)
                try? FileManager.default.removeItem(at: file)
                onImported(p)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
