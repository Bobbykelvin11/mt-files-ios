import UIKit

enum IconService {
    static let iconPrefix = "IPAStudioIcon"

    /// Finds the largest PNG icon inside the .app referenced by Info.plist (or common names).
    static func currentIconURL(appURL: URL, info: [String: Any]) -> URL? {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                if let files = primary["CFBundleIconFiles"] as? [String] { names += files }
                if let n = primary["CFBundleIconName"] as? String { names.append(n) }
            }
        }
        if let files = info["CFBundleIconFiles"] as? [String] { names += files }
        if let f = info["CFBundleIconFile"] as? String { names.append(f) }
        names += ["AppIcon", "Icon", "icon"]

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: appURL.path)) ?? []
        let pngs = contents.filter { $0.lowercased().hasSuffix(".png") }
        var best: (URL, CGFloat)?
        var seen = Set<String>()
        for name in names {
            let base = (name as NSString).deletingPathExtension
            guard !base.isEmpty, !seen.contains(base) else { continue }
            seen.insert(base)
            for file in pngs where file.hasPrefix(base) {
                let url = appURL.appendingPathComponent(file)
                guard let img = UIImage(contentsOfFile: url.path) else { continue }
                let px = img.size.width * img.scale
                if best == nil || px > best!.1 { best = (url, px) }
            }
            if best != nil { break }
        }
        return best?.0
    }

    static func currentIcon(appURL: URL, info: [String: Any]) -> UIImage? {
        guard let url = currentIconURL(appURL: appURL, info: info) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Draws `image` aspect-filled into an opaque square of `side` pixels.
    static func square(_ image: UIImage, side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let w = image.size.width, h = image.size.height
            guard w > 0, h > 0 else { return }
            let scale = max(side / w, side / h)
            let dw = w * scale, dh = h * scale
            image.draw(in: CGRect(x: (side - dw) / 2, y: (side - dh) / 2, width: dw, height: dh))
        }
    }

    static func tinted(_ image: UIImage, color: UIColor) -> UIImage {
        let base = square(image, side: 1024)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            base.draw(in: rect)
            color.setFill()
            UIRectFillUsingBlendMode(rect, .color)
            color.withAlphaComponent(0.35).setFill()
            UIRectFillUsingBlendMode(rect, .multiply)
        }
    }

    /// Writes all required icon PNG sizes into the .app and points Info.plist at them
    /// (CFBundleIconName is removed so iOS uses these files instead of Assets.car).
    static func installIcon(_ image: UIImage, appURL: URL, info: inout [String: Any]) throws {
        let base = square(image, side: 1024)
        let specs: [(String, CGFloat)] = [
            ("\(iconPrefix)60x60@2x.png", 120),
            ("\(iconPrefix)60x60@3x.png", 180),
            ("\(iconPrefix)76x76~ipad.png", 76),
            ("\(iconPrefix)76x76@2x~ipad.png", 152),
            ("\(iconPrefix)83.5x83.5@2x~ipad.png", 167),
            ("\(iconPrefix)1024x1024.png", 1024)
        ]
        for (name, px) in specs {
            guard let data = square(base, side: px).pngData() else {
                throw StudioError.message("Could not encode icon")
            }
            try data.write(to: appURL.appendingPathComponent(name), options: .atomic)
        }

        var icons = info["CFBundleIcons"] as? [String: Any] ?? [:]
        var primary = icons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
        primary["CFBundleIconFiles"] = ["\(iconPrefix)60x60"]
        primary.removeValue(forKey: "CFBundleIconName")
        icons["CFBundlePrimaryIcon"] = primary
        info["CFBundleIcons"] = icons

        var ipadIcons = info["CFBundleIcons~ipad"] as? [String: Any] ?? [:]
        var ipadPrimary = ipadIcons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
        ipadPrimary["CFBundleIconFiles"] = ["\(iconPrefix)60x60", "\(iconPrefix)76x76", "\(iconPrefix)83.5x83.5"]
        ipadPrimary.removeValue(forKey: "CFBundleIconName")
        ipadIcons["CFBundlePrimaryIcon"] = ipadPrimary
        info["CFBundleIcons~ipad"] = ipadIcons

        info.removeValue(forKey: "CFBundleIconFile")
        info.removeValue(forKey: "CFBundleIconFiles")
    }

    static let colorNames: [String] = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray", "black", "white", "gold"]

    static func color(named name: String) -> UIColor? {
        switch name.lowercased() {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "gold": return UIColor(red: 0.85, green: 0.65, blue: 0.13, alpha: 1)
        case "green": return .systemGreen
        case "mint": return .systemMint
        case "teal": return .systemTeal
        case "cyan": return .systemCyan
        case "blue": return .systemBlue
        case "indigo": return .systemIndigo
        case "purple", "violet": return .systemPurple
        case "pink": return .systemPink
        case "brown": return .systemBrown
        case "gray", "grey": return .systemGray
        case "black": return .black
        case "white": return .white
        default:
            // hex like #3366ff
            var hex = name.trimmingCharacters(in: .whitespaces)
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
            return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }
}
