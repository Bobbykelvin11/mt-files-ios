import Foundation
import ZIPFoundation

enum IPAImporter {
    /// Unzips `ipa` into `projectDir` and returns a populated project.
    static func extract(ipa: URL, into projectDir: URL, id: UUID, originalName: String) throws -> IPAProject {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber)?.int64Value ?? 0
        try? fm.removeItem(at: projectDir)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        do {
            try fm.unzipItem(at: ipa, to: projectDir)
        } catch {
            try? fm.removeItem(at: projectDir)
            throw StudioError.message("Could not unzip this file. Is it a valid .ipa? (\(error.localizedDescription))")
        }
        try? fm.removeItem(at: projectDir.appendingPathComponent("__MACOSX"))

        // Normalise "payload" -> "Payload"
        let entries = (try? fm.contentsOfDirectory(atPath: projectDir.path)) ?? []
        guard let payloadName = entries.first(where: { $0.lowercased() == "payload" }) else {
            try? fm.removeItem(at: projectDir)
            throw StudioError.message("No Payload folder found. This doesn't look like an iOS app archive.")
        }
        if payloadName != "Payload" {
            try fm.moveItem(at: projectDir.appendingPathComponent(payloadName), to: projectDir.appendingPathComponent("Payload"))
        }
        let payload = projectDir.appendingPathComponent("Payload")
        let apps = ((try? fm.contentsOfDirectory(atPath: payload.path)) ?? []).filter { $0.hasSuffix(".app") }
        guard let appName = apps.first else {
            try? fm.removeItem(at: projectDir)
            throw StudioError.message("No .app bundle inside Payload.")
        }

        var project = IPAProject(
            id: id, displayName: appName, bundleID: "", version: "", build: "", minOS: "",
            originalFileName: originalName, originalSize: size, encrypted: nil,
            appFolderName: appName, importedAt: Date(), modifiedAt: Date(), lastExportPath: nil
        )
        try populate(&project, appURL: payload.appendingPathComponent(appName))
        return project
    }

    /// Re-reads Info.plist + Mach-O into the project fields.
    static func populate(_ project: inout IPAProject, appURL: URL) throws {
        let (info, _) = try PlistIO.read(appURL.appendingPathComponent("Info.plist"))
        project.displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? project.appFolderName
        project.bundleID = info["CFBundleIdentifier"] as? String ?? ""
        project.version = info["CFBundleShortVersionString"] as? String ?? ""
        project.build = info["CFBundleVersion"] as? String ?? ""
        project.minOS = info["MinimumOSVersion"] as? String ?? ""
        if let exe = info["CFBundleExecutable"] as? String {
            project.encrypted = MachOInspector.isEncrypted(executableURL: appURL.appendingPathComponent(exe))
        }
    }
}

enum Repacker {
    /// Copies Payload to a staging area, strips code signatures, and zips it into `outputURL`.
    static func repack(projectDir: URL, outputURL: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("repack-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("Payload")
        try fm.copyItem(at: projectDir.appendingPathComponent("Payload"), to: payload)

        var toRemove: [URL] = []
        if let en = fm.enumerator(at: payload, includingPropertiesForKeys: nil) {
            for case let url as URL in en {
                let name = url.lastPathComponent
                if name == "_CodeSignature" || name == "embedded.mobileprovision" || name == ".DS_Store" {
                    toRemove.append(url)
                }
            }
        }
        for url in toRemove { try? fm.removeItem(at: url) }

        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputURL.path) { try fm.removeItem(at: outputURL) }
        try fm.zipItem(at: payload, to: outputURL, shouldKeepParent: true, compressionMethod: .deflate)
    }
}
