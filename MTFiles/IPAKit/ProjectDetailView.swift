import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    @EnvironmentObject var store: LibraryStore
    let projectID: UUID

    @State private var name = ""
    @State private var bundleID = ""
    @State private var version = ""
    @State private var build = ""
    @State private var minOS = ""
    @State private var loaded = false
    @State private var hasSupportedDevices = false
    @State private var fileSharingOn = false
    @State private var bundleSize: Int64?

    @State private var photoItem: PhotosPickerItem?
    @State private var pick: PickRequest?
    @State private var exportedURL: URL?
    @State private var share: IdentifiableURL?
    @State private var saveToFiles: IdentifiableURL?
    @State private var toast: String?

    private var project: IPAProject? { store.project(projectID) }

    var body: some View {
        Group {
            if let p = project {
                form(p)
            } else {
                Text("This project was deleted.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(project?.displayName ?? "App")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.currentProjectID = projectID
            if !loaded { loadFields() }
        }
        .onChange(of: store.revision) { _ in loadFields() }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    replaceIcon(img)
                } else {
                    store.lastError = "Couldn't load that photo."
                }
                photoItem = nil
            }
        }
        .documentPicker($pick)
        .sheet(item: $share) { item in ShareSheet(items: [item.url]) }
        .sheet(item: $saveToFiles) { item in ExportToFilesPicker(url: item.url) }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout.bold())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func form(_ p: IPAProject) -> some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ProjectIcon(project: p, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.displayName).font(.title3.bold())
                        Text(p.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        EncryptionBadge(encrypted: p.encrypted)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("Version", value: p.versionLabel)
                LabeledContent("Minimum iOS", value: p.minOS.isEmpty ? "—" : p.minOS)
                LabeledContent("Original file", value: p.originalFileName)
                LabeledContent("IPA size", value: formatBytes(p.originalSize))
                LabeledContent("Unpacked size", value: bundleSize.map(formatBytes) ?? "…")
            }

            if p.encrypted == true {
                Section {
                    Label {
                        Text("This app is encrypted (it came from the App Store). Encrypted apps can't be meaningfully modified, and after re-signing they won't launch. MT Files doesn't decrypt apps. Use apps you own as unencrypted builds, or open-source apps.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            Section {
                TextField("Display name", text: $name)
                TextField("Bundle ID", text: $bundleID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    TextField("Version", text: $version).keyboardType(.decimalPad)
                    Divider()
                    TextField("Build", text: $build).keyboardType(.numbersAndPunctuation)
                }
                TextField("Minimum iOS (e.g. 15.0)", text: $minOS).keyboardType(.decimalPad)
                Button {
                    saveInfo(p)
                } label: {
                    Label("Save changes", systemImage: "checkmark.circle.fill")
                }
                .disabled(!hasChanges(p))
            } header: {
                Text("App info")
            } footer: {
                Text("Changing the bundle ID lets you install a copy next to the original. Extensions are updated too (see Settings).")
            }

            Section("Icon") {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Replace icon from Photos", systemImage: "photo")
                }
                Button {
                    pick = PickRequest(mode: .importCopy, multiple: false) { urls in
                        guard let url = urls.first else { return }
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                            replaceIcon(img)
                        } else {
                            store.lastError = "“\(url.lastPathComponent)” isn't an image MT Files can read (use PNG, JPEG or HEIC)."
                        }
                    }
                } label: {
                    Label("Replace icon from Files", systemImage: "folder")
                }
                Menu {
                    ForEach(IconService.colorNames, id: \.self) { c in
                        Button(c.capitalized) { run(.tintIcon(c)) }
                    }
                } label: {
                    Label("Tint current icon", systemImage: "paintpalette")
                }
            }

            Section("Options") {
                Button { run(.enableFileSharing) } label: {
                    Label(fileSharingOn ? "File sharing is on" : "Enable file sharing (Files app)", systemImage: fileSharingOn ? "checkmark.circle" : "folder.badge.plus")
                }
                .disabled(fileSharingOn)
                Button { run(.removeSupportedDevices) } label: {
                    Label(hasSupportedDevices ? "Remove UISupportedDevices" : "No device restrictions", systemImage: "ipad.and.iphone")
                }
                .disabled(!hasSupportedDevices)
            }

            Section("Advanced") {
                NavigationLink {
                    PlistEditorView(plistURL: store.infoPlistURL(for: p), onSave: { store.refresh(p.id) })
                } label: {
                    Label("Info.plist keys", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    FileBrowserView(directory: store.appURL(for: p), title: p.appFolderName, onChange: { store.refresh(p.id) })
                } label: {
                    Label("Browse app files", systemImage: "folder")
                }
            }

            Section {
                Button {
                    Task {
                        do {
                            let url = try await store.export(p.id)
                            exportedURL = url
                            share = IdentifiableURL(url: url)
                        } catch {
                            store.lastError = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Build new IPA", systemImage: "shippingbox.fill").font(.headline)
                }
                if let url = exportedURL ?? p.lastExportPath.map({ URL(fileURLWithPath: $0) }),
                   FileManager.default.fileExists(atPath: url.path) {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    Button { share = IdentifiableURL(url: url) } label: { Label("Share IPA", systemImage: "square.and.arrow.up") }
                    Button { saveToFiles = IdentifiableURL(url: url) } label: { Label("Save to Files", systemImage: "folder") }
                }
            } header: {
                Text("Export")
            } footer: {
                Text("The new IPA is unsigned (old _CodeSignature folders are removed). Sign and install it with Sideloadly or SideStore.")
            }
        }
    }

    private func hasChanges(_ p: IPAProject) -> Bool {
        name != p.displayName || bundleID != p.bundleID || version != p.version || build != p.build || minOS != p.minOS
    }

    private func loadFields() {
        guard let p = project else { return }
        name = p.displayName
        bundleID = p.bundleID
        version = p.version
        build = p.build
        minOS = p.minOS
        let info = store.info(for: p)
        hasSupportedDevices = info["UISupportedDevices"] != nil
        fileSharingOn = (info["UIFileSharingEnabled"] as? Bool) == true
        loaded = true
        let dir = store.appURL(for: p)
        Task.detached(priority: .utility) {
            let size = FileManager.default.directorySize(dir)
            await MainActor.run { bundleSize = size }
        }
    }

    private func saveInfo(_ p: IPAProject) {
        var actions: [EditAction] = []
        let t = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if t(name) != p.displayName, !t(name).isEmpty { actions.append(.rename(t(name))) }
        if t(bundleID) != p.bundleID, !t(bundleID).isEmpty { actions.append(.setBundleID(t(bundleID))) }
        if t(version) != p.version, !t(version).isEmpty { actions.append(.setVersion(t(version))) }
        if t(build) != p.build, !t(build).isEmpty { actions.append(.setBuild(t(build))) }
        if t(minOS) != p.minOS, !t(minOS).isEmpty { actions.append(.setMinOS(t(minOS))) }
        do {
            for a in actions { try store.apply(a, to: p.id) }
            showToast("Saved")
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func run(_ action: EditAction) {
        do {
            try store.apply(action, to: projectID)
            showToast("Done")
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func replaceIcon(_ image: UIImage) {
        do {
            try store.replaceIcon(image, for: projectID)
            showToast("Icon replaced")
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { toast = nil }
        }
    }
}
