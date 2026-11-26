import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(red: 0.133, green: 0.765, blue: 0.651)
    static let bg = Color(red: 0.067, green: 0.078, blue: 0.098)
    static let panel = Color(red: 0.098, green: 0.114, blue: 0.141)
    static let row = Color(red: 0.122, green: 0.141, blue: 0.173)
    static let muted = Color(white: 0.6)

    static let uiBG = UIColor(red: 0.067, green: 0.078, blue: 0.098, alpha: 1)
    static let uiGutter = UIColor(red: 0.090, green: 0.102, blue: 0.125, alpha: 1)
}

extension FileEntry {
    var symbol: String {
        if isDirectory { return "folder.fill" }
        switch ext {
        case "ipa": return "app.badge"
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz": return "doc.zipper"
        case "apk", "aab": return "shippingbox.fill"
        case "plist": return "list.bullet.rectangle"
        case "json": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "tif": return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv", "webm": return "film"
        case "mp3", "m4a", "wav", "aac", "flac", "caf", "aiff", "ogg": return "waveform"
        case "pdf": return "doc.richtext"
        case "md", "txt", "rtf", "log": return "doc.text"
        case "swift", "js", "ts", "tsx", "jsx", "py", "c", "h", "m", "mm", "cpp", "hpp", "cc", "java", "kt", "go", "rs", "rb", "php", "cs", "dart", "lua", "sh", "html", "htm", "css", "xml", "yml", "yaml", "toml", "sql", "smali":
            return "chevron.left.forwardslash.chevron.right"
        case "dylib", "so", "a", "o", "bin", "dex": return "cpu"
        default: return "doc"
        }
    }

    var tint: Color {
        if isDirectory { return Theme.accent }
        switch ext {
        case "ipa", "apk", "aab": return .orange
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz": return .yellow
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "tif": return .pink
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "mp3", "m4a", "wav", "aac", "flac", "caf", "aiff", "ogg": return .purple
        case "plist", "json", "xml", "yml", "yaml", "toml": return .cyan
        case "pdf": return .red
        default:
            return symbol == "chevron.left.forwardslash.chevron.right" ? .blue : Theme.muted
        }
    }
}
