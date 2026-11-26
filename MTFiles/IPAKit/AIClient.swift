import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String   // "user" | "assistant"
    let text: String
}

/// Action an AI reply asked for, executed only after the user taps Apply.
enum AIAction: Equatable {
    case edit(EditAction)
    case find(String)
    case web(String)
}

enum AIConfig {
    static var baseURL: String { UserDefaults.standard.string(forKey: "ai_base_url") ?? "https://api.groq.com/openai/v1" }
    static var model: String { UserDefaults.standard.string(forKey: "ai_model") ?? "llama-3.3-70b-versatile" }
    static var apiKey: String { Keychain.get("ai_api_key") }
    static var isConfigured: Bool { !apiKey.isEmpty && URL(string: baseURL) != nil }
}

enum AIClient {
    static func systemPrompt(context: String) -> String {
        """
        You are the IPA editor assistant inside MT Files, an iPhone app that edits .ipa files the user owns or that are open source \
        (rename, bundle ID, version, minimum iOS, app icon, file sharing, Info.plist, files) and repacks them unsigned \
        for signing with Sideloadly or SideStore. Answer briefly and helpfully.
        Hard rule: never help unlock subscriptions or in-app purchases, bypass licenses, crack apps, or decrypt App Store apps. \
        Politely refuse and suggest finding a free open-source alternative instead.
        When the user wants the app to DO something, end your reply with exactly one JSON object on its own line, like:
        {"action":"rename","value":"My App"}
        Allowed actions: rename, set_bundle_id, set_version, set_build, set_min_os, tint_icon (value = color name or #hex), \
        enable_file_sharing, remove_supported_devices, find_ipa (value = search terms for open-source iOS apps on GitHub), \
        web_search (value = query). Only include JSON when an action is clearly wanted.
        Current context: \(context)
        """
    }

    static func chat(history: [ChatMessage], context: String) async throws -> String {
        try await complete(system: systemPrompt(context: context), history: history)
    }

    /// Generic OpenAI-compatible chat completion with a custom system prompt.
    static func complete(system: String, history: [ChatMessage], temperature: Double = 0.3) async throws -> String {
        var base = AIConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let endpoint = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: endpoint) else { throw StudioError.message("Invalid AI base URL in Settings") }

        var messages: [[String: String]] = [["role": "system", "content": system]]
        for m in history.suffix(16) { messages.append(["role": m.role, "content": m.text]) }
        let body: [String: Any] = ["model": AIConfig.model, "messages": messages, "temperature": temperature]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(AIConfig.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("https://github.com/Bobbykelvin11/mt-files-ios", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("MT Files", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw StudioError.message("AI error \(http.statusCode): \(msg.prefix(300))")
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw StudioError.message("Unexpected AI response")
        }
        return content
    }

    /// Splits an AI reply into visible text + optional action.
    static func extractAction(from reply: String) -> (text: String, action: AIAction?) {
        guard let re = try? NSRegularExpression(pattern: #"\{[^{}]*"action"[^{}]*\}"#),
              let m = re.firstMatch(in: reply, range: NSRange(reply.startIndex..., in: reply)),
              let r = Range(m.range, in: reply),
              let data = String(reply[r]).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = obj["action"] as? String else {
            return (reply, nil)
        }
        let value: String = {
            if let s = obj["value"] as? String { return s }
            if let n = obj["value"] as? NSNumber { return n.stringValue }
            return ""
        }()
        var text = reply
        text.removeSubrange(r)
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parsed: AIAction?
        switch action {
        case "rename": parsed = value.isEmpty ? nil : .edit(.rename(value))
        case "set_bundle_id": parsed = value.isEmpty ? nil : .edit(.setBundleID(value))
        case "set_version": parsed = value.isEmpty ? nil : .edit(.setVersion(value))
        case "set_build": parsed = value.isEmpty ? nil : .edit(.setBuild(value))
        case "set_min_os": parsed = value.isEmpty ? nil : .edit(.setMinOS(value))
        case "tint_icon": parsed = value.isEmpty ? nil : .edit(.tintIcon(value))
        case "enable_file_sharing": parsed = .edit(.enableFileSharing)
        case "remove_supported_devices": parsed = .edit(.removeSupportedDevices)
        case "find_ipa": parsed = value.isEmpty ? nil : .find(value)
        case "web_search": parsed = value.isEmpty ? nil : .web(value)
        default: parsed = nil
        }
        return (text, parsed)
    }
}
