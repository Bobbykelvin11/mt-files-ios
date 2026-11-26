import Foundation

struct FileEntry: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let created: Date?
    let isHidden: Bool

    var ext: String { url.pathExtension.lowercased() }

    static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isHiddenKey, .isPackageKey]

    init(url: URL) {
        let v = try? url.resourceValues(forKeys: Set(FileEntry.keys))
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = v?.isDirectory ?? false
        self.size = Int64(v?.fileSize ?? 0)
        self.modified = v?.contentModificationDate
        self.created = v?.creationDate
        self.isHidden = v?.isHidden ?? url.lastPathComponent.hasPrefix(".")
    }
}

enum SortKey: String, CaseIterable, Identifiable, Codable {
    case name = "Name", modified = "Date", size = "Size", type = "Type"
    var id: String { rawValue }
}

struct PlainError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
