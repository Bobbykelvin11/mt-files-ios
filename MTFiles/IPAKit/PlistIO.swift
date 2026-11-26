import Foundation

enum PlistIO {
    static func read(_ url: URL) throws -> (dict: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.binary
        let obj = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format)
        guard let dict = obj as? [String: Any] else {
            throw StudioError.message("\(url.lastPathComponent) is not a dictionary plist")
        }
        return (dict, format)
    }

    static func write(_ dict: [String: Any], to url: URL, format: PropertyListSerialization.PropertyListFormat) throws {
        let fmt: PropertyListSerialization.PropertyListFormat = (format == .openStep) ? .xml : format
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: fmt, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// Any plist object -> XML text (for viewing / editing).
    static func xmlString(from data: Data) -> (String, PropertyListSerialization.PropertyListFormat)? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0),
              let str = String(data: xml, encoding: .utf8) else { return nil }
        return (str, format)
    }

    static func isBool(_ value: Any) -> Bool {
        let cf = value as CFTypeRef
        return CFGetTypeID(cf) == CFBooleanGetTypeID()
    }
}

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

extension FileManager {
    func directorySize(_ url: URL) -> Int64 {
        guard let en = enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in en {
            if let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
