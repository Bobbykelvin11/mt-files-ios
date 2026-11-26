import Foundation

/// One imported (and possibly edited) IPA in the library.
struct IPAProject: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var bundleID: String
    var version: String
    var build: String
    var minOS: String
    var originalFileName: String
    var originalSize: Int64
    /// nil = could not determine
    var encrypted: Bool?
    var appFolderName: String
    var importedAt: Date
    var modifiedAt: Date
    var lastExportPath: String?
    var edited: Bool = false

    var versionLabel: String {
        build.isEmpty || build == version ? version : "\(version) (\(build))"
    }
}

/// Editor actions shared by the manual editor, the offline intent parser and the AI assistant.
enum EditAction: Equatable {
    case rename(String)
    case setBundleID(String)
    case setVersion(String)
    case setBuild(String)
    case setMinOS(String)
    case tintIcon(String)
    case enableFileSharing
    case removeSupportedDevices

    var summary: String {
        switch self {
        case .rename(let v): return "Rename the app to “\(v)”"
        case .setBundleID(let v): return "Change bundle ID to \(v)"
        case .setVersion(let v): return "Set version to \(v)"
        case .setBuild(let v): return "Set build number to \(v)"
        case .setMinOS(let v): return "Set minimum iOS to \(v)"
        case .tintIcon(let c): return "Tint the app icon \(c)"
        case .enableFileSharing: return "Enable file sharing (show in Files app)"
        case .removeSupportedDevices: return "Remove UISupportedDevices (allow all devices)"
        }
    }

    var symbol: String {
        switch self {
        case .rename: return "character.cursor.ibeam"
        case .setBundleID: return "barcode"
        case .setVersion, .setBuild: return "number"
        case .setMinOS: return "iphone"
        case .tintIcon: return "paintpalette"
        case .enableFileSharing: return "folder.badge.plus"
        case .removeSupportedDevices: return "ipad.and.iphone"
        }
    }
}
