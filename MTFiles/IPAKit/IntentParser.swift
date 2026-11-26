import Foundation

enum AskIntent: Equatable {
    case edit(EditAction)
    case find(String)
    case web(String)
    case chat(String)
    case blocked(String)
}

/// Offline, rule-based natural-language parser for the Ask bar.
enum IntentParser {
    static let blockedMessage = "MT Files doesn't unlock subscriptions or in-app purchases, bypass licenses, or decrypt App Store apps. Try “find” to look for a free open-source alternative instead."

    private static let blockedPatterns = [
        "crack", "unlock premium", "unlock pro", "unlock subscription", "unlock in-app", "free premium",
        "bypass", "remove subscription", "remove paywall", "paywall", "in-app purchase", "in app purchase",
        "iap", "decrypt", "dump", "license key", "keygen", "piracy", "pirate", "premium for free", "get premium",
        "unlock all features", "hack the app", "mod premium"
    ]

    static func parse(_ raw: String) -> AskIntent {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard !text.isEmpty else { return .chat(text) }

        for p in blockedPatterns where containsWord(lower, p) {
            return .blocked(blockedMessage)
        }

        // Edits on the currently opened IPA
        if let v = capture(text, #"^(?:please\s+)?(?:change|set|update)\s+(?:the\s+)?bundle\s*(?:id|identifier)\s+(?:to\s+)?([A-Za-z0-9.\-]+)\s*$"#)
            ?? capture(text, #"^bundle\s*(?:id|identifier)\s*[:=]?\s*([A-Za-z0-9.\-]+)\s*$"#) {
            return .edit(.setBundleID(v))
        }
        if let v = capture(text, #"^(?:please\s+)?(?:change|set|update|make)\s+(?:the\s+)?(?:min(?:imum)?\s+)(?:ios|os)?\s*(?:version\s+)?(?:to\s+)?(\d+(?:\.\d+){0,2})\s*$"#)
            ?? capture(text, #"^(?:min(?:imum)?\s+(?:ios|os)|deployment target)\s*(?:to\s+|[:=]\s*)?(\d+(?:\.\d+){0,2})\s*$"#)
            ?? capture(text, #"^(?:make it\s+)?(?:support|run on|work on)\s+ios\s+(\d+(?:\.\d+){0,2})\s*\+?\s*$"#) {
            return .edit(.setMinOS(v))
        }
        if let v = capture(text, #"^(?:please\s+)?(?:change|set|update)\s+(?:the\s+)?build(?:\s+number)?\s+(?:to\s+)?(\S+)\s*$"#) {
            return .edit(.setBuild(v))
        }
        if let v = capture(text, #"^(?:please\s+)?(?:change|set|update|bump)\s+(?:the\s+)?version\s+(?:number\s+)?(?:to\s+)?(\S+)\s*$"#) {
            return .edit(.setVersion(v))
        }
        if let v = capture(text, #"^(?:please\s+)?(?:rename|name)(?:\s+(?:it|the app|this app|app|this))?(?:\s+(?:to|as))?\s+(.+)$"#)
            ?? capture(text, #"^(?:please\s+)?(?:change|set|update)\s+(?:the\s+)?(?:app\s+|display\s+)?name\s+(?:to\s+)?(.+)$"#)
            ?? capture(text, #"^call\s+(?:it|the app)\s+(.+)$"#) {
            let name = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ."))
            if !name.isEmpty { return .edit(.rename(name)) }
        }
        if lower.contains("icon") {
            if let hex = capture(text, #"(#[0-9A-Fa-f]{6})"#) { return .edit(.tintIcon(hex)) }
            for c in IconService.colorNames + ["grey", "violet"] where containsWord(lower, c) {
                return .edit(.tintIcon(c == "grey" ? "gray" : (c == "violet" ? "purple" : c)))
            }
        }
        if lower.contains("file sharing") || lower.contains("files app") || lower.contains("show in files") || lower.contains("documents folder") {
            return .edit(.enableFileSharing)
        }
        if lower.contains("supported devices") || lower.contains("uisupporteddevices") || lower.contains("all devices") || lower.contains("any device") {
            return .edit(.removeSupportedDevices)
        }

        // Web search
        if let v = capture(text, #"^(?:google|web|search the web for|search web for|web search|duckduckgo|ddg)\s*:?\s+(.+)$"#) {
            return .web(v)
        }
        // GitHub IPA search
        if let v = capture(text, #"^(?:find|search(?:\s+for)?|look\s+for|get|download|show me|i want|i need)\s+(.+)$"#) {
            return .find(v)
        }
        if lower.contains("alternative") || lower.contains("open source") || lower.contains("open-source") || lower.hasSuffix(" ipa") || lower.hasSuffix(" app") {
            return .find(text)
        }
        return .chat(text)
    }

    private static func containsWord(_ text: String, _ word: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: "\\b\(escaped)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let v = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
