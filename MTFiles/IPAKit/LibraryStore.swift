import SwiftUI
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var projects: [IPAProject] = []
    @Published var currentProjectID: UUID?
    @Published var busyMessage: String?
    @Published var lastError: String?
    /// Bumped whenever files change so icon thumbnails reload.
    @Published var revision: Int = 0
    @Published var updateExtensionBundleIDs = true

    private let fm = FileManager.default

    var projectsRoot: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Projects", isDirectory: true)
    }

    var exportsRoot: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports", isDirectory: true)
    }

    private var indexURL: URL { projectsRoot.appendingPathComponent("index.json") }

    init() {
        try? fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([IPAProject].self, from: data) {
            projects = list.filter { fm.fileExists(atPath: appURL(for: $0).path) }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(projects) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: Paths

    func project(_ id: UUID?) -> IPAProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    var currentProject: IPAProject? {
        project(currentProjectID) ?? projects.max { $0.modifiedAt < $1.modifiedAt }
    }

    func projectDir(for p: IPAProject) -> URL { projectsRoot.appendingPathComponent(p.id.uuidString, isDirectory: true) }
    func appURL(for p: IPAProject) -> URL { projectDir(for: p).appendingPathComponent("Payload").appendingPathComponent(p.appFolderName) }
    func infoPlistURL(for p: IPAProject) -> URL { appURL(for: p).appendingPathComponent("Info.plist") }

    func info(for p: IPAProject) -> [String: Any] {
        (try? PlistIO.read(infoPlistURL(for: p)).dict) ?? [:]
    }

    func icon(for p: IPAProject) -> UIImage? {
        IconService.currentIcon(appURL: appURL(for: p), info: info(for: p))
    }

    // MARK: Import

    @discardableResult
    func importIPA(from url: URL, suggestedName: String? = nil) async throws -> IPAProject {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let name = suggestedName ?? url.lastPathComponent
        let temp = fm.temporaryDirectory.appendingPathComponent("import-\(id.uuidString).ipa")
        try? fm.removeItem(at: temp)
        try fm.copyItem(at: url, to: temp)
        let dir = projectsRoot.appendingPathComponent(id.uuidString, isDirectory: true)

        busyMessage = "Unpacking \(name)…"
        defer { busyMessage = nil }
        let project = try await Task.detached(priority: .userInitiated) { () throws -> IPAProject in
            defer { try? FileManager.default.removeItem(at: temp) }
            return try IPAImporter.extract(ipa: temp, into: dir, id: id, originalName: name)
        }.value
        projects.insert(project, at: 0)
        currentProjectID = project.id
        save()
        revision += 1
        return project
    }

    func delete(_ p: IPAProject) {
        try? fm.removeItem(at: projectDir(for: p))
        projects.removeAll { $0.id == p.id }
        if currentProjectID == p.id { currentProjectID = nil }
        save()
    }

    /// Re-read metadata after any file change.
    func refresh(_ id: UUID, edited: Bool = true) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        var p = projects[idx]
        try? IPAImporter.populate(&p, appURL: appURL(for: p))
        if edited {
            p.modifiedAt = Date()
            p.edited = true
        }
        projects[idx] = p
        save()
        revision += 1
    }

    // MARK: Editing

    func apply(_ action: EditAction, to id: UUID) throws {
        guard let p = project(id) else { throw StudioError.message("Open an IPA first (import one from Files, a URL or GitHub).") }
        let url = infoPlistURL(for: p)
        let read = try PlistIO.read(url)
        var info = read.dict
        let format = read.format
        switch action {
        case .rename(let name):
            info["CFBundleDisplayName"] = name
            if (info["CFBundleName"] as? String) != nil { info["CFBundleName"] = name }
        case .setBundleID(let newID):
            let old = info["CFBundleIdentifier"] as? String ?? ""
            info["CFBundleIdentifier"] = newID
            if updateExtensionBundleIDs, !old.isEmpty, old != newID {
                updateNestedBundleIDs(appURL: appURL(for: p), old: old, new: newID)
            }
        case .setVersion(let v):
            info["CFBundleShortVersionString"] = v
        case .setBuild(let v):
            info["CFBundleVersion"] = v
        case .setMinOS(let v):
            info["MinimumOSVersion"] = v
        case .tintIcon(let colorName):
            guard let color = IconService.color(named: colorName) else {
                throw StudioError.message("Unknown color “\(colorName)”. Try red, blue, green, purple or a #hex code.")
            }
            guard let current = IconService.currentIcon(appURL: appURL(for: p), info: info) else {
                throw StudioError.message("This app has no PNG icon to tint. Use Replace Icon instead.")
            }
            try IconService.installIcon(IconService.tinted(current, color: color), appURL: appURL(for: p), info: &info)
        case .enableFileSharing:
            info["UIFileSharingEnabled"] = true
            info["LSSupportsOpeningDocumentsInPlace"] = true
        case .removeSupportedDevices:
            info.removeValue(forKey: "UISupportedDevices")
        }
        try PlistIO.write(info, to: url, format: format)
        refresh(id)
    }

    func replaceIcon(_ image: UIImage, for id: UUID) throws {
        guard let p = project(id) else { return }
        let url = infoPlistURL(for: p)
        let read = try PlistIO.read(url)
        var info = read.dict
        let format = read.format
        try IconService.installIcon(image, appURL: appURL(for: p), info: &info)
        try PlistIO.write(info, to: url, format: format)
        refresh(id)
    }

    /// Updates app extensions / watch apps whose bundle IDs start with the old main ID.
    private func updateNestedBundleIDs(appURL: URL, old: String, new: String) {
        let dirs = ["PlugIns", "Extensions", "Watch", "AppClips"]
        for d in dirs {
            let folder = appURL.appendingPathComponent(d)
            guard let items = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for item in items {
                let plistURL = folder.appendingPathComponent(item).appendingPathComponent("Info.plist")
                guard let read = try? PlistIO.read(plistURL),
                      let bid = read.dict["CFBundleIdentifier"] as? String, bid.hasPrefix(old) else { continue }
                var info = read.dict
                let format = read.format
                info["CFBundleIdentifier"] = new + String(bid.dropFirst(old.count))
                if var ext = info["NSExtension"] as? [String: Any],
                   var attrs = ext["NSExtensionAttributes"] as? [String: Any],
                   let wk = attrs["WKAppBundleIdentifier"] as? String, wk.hasPrefix(old) {
                    attrs["WKAppBundleIdentifier"] = new + String(wk.dropFirst(old.count))
                    ext["NSExtensionAttributes"] = attrs
                    info["NSExtension"] = ext
                }
                if let companion = info["WKCompanionAppBundleIdentifier"] as? String, companion == old {
                    info["WKCompanionAppBundleIdentifier"] = new
                }
                try? PlistIO.write(info, to: plistURL, format: format)
            }
        }
    }

    // MARK: Export

    func export(_ id: UUID) async throws -> URL {
        guard let p = project(id) else { throw StudioError.message("Project not found") }
        let safeName = p.displayName.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let fileName = "\(safeName.isEmpty ? "App" : safeName)-\(p.version.isEmpty ? "1.0" : p.version)-edited.ipa"
        let out = exportsRoot.appendingPathComponent(fileName)
        let dir = projectDir(for: p)
        busyMessage = "Packing \(fileName)…"
        defer { busyMessage = nil }
        try await Task.detached(priority: .userInitiated) {
            try Repacker.repack(projectDir: dir, outputURL: out)
        }.value
        if let idx = projects.firstIndex(where: { $0.id == id }) {
            projects[idx].lastExportPath = out.path
            save()
        }
        return out
    }

    func exportedFiles() -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: exportsRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension.lowercased() == "ipa" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    func contextDescription() -> String {
        guard let p = currentProject else { return "No IPA is open yet." }
        return "Open IPA: name=\(p.displayName), bundleID=\(p.bundleID), version=\(p.versionLabel), minOS=\(p.minOS), encrypted=\(p.encrypted.map { $0 ? "yes" : "no" } ?? "unknown")."
    }
}
