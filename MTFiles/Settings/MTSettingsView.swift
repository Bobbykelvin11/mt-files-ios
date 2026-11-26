import SwiftUI
import UIKit

struct MTSettingsView: View {
    @AppStorage("ai_base_url") private var baseURL = "https://api.groq.com/openai/v1"
    @AppStorage("ai_model") private var model = "llama-3.3-70b-versatile"
    @AppStorage("editor_wrap") private var wrap = true
    @AppStorage("editor_lines") private var lineNumbers = true
    @State private var apiKey = Keychain.get("ai_api_key")
    @State private var githubToken = Keychain.get("github_token")
    @State private var testResult: String?
    @State private var testing = false
    @AppStorage("ai_no_key") private var noKey = false
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelsError: String?
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var places: LocationStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            preset("Groq", "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile")
                            preset("OpenRouter", "https://openrouter.ai/api/v1", "meta-llama/llama-3.3-70b-instruct:free")
                            preset("Uncensored", "https://openrouter.ai/api/v1", "cognitivecomputations/dolphin-mistral-24b-venice-edition")
                            preset("OpenAI", "https://api.openai.com/v1", "gpt-4o-mini")
                            preset("LM Studio", "http://192.168.1.2:1234/v1", "local-model", local: true)
                            preset("Ollama", "http://192.168.1.2:11434/v1", "llama3.2", local: true)
                        }
                    }
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button {
                            loadingModels = true
                            modelsError = nil
                            Task {
                                do { models = try await AIClient.listModels() } catch { modelsError = error.localizedDescription }
                                loadingModels = false
                            }
                        } label: { HStack { Text("Browse models"); if loadingModels { ProgressView() } } }
                        .disabled(loadingModels)
                        if !models.isEmpty {
                            Spacer()
                            Picker("", selection: $model) {
                                if !models.contains(model) { Text(model).tag(model) }
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                    if let modelsError { Text(modelsError).font(.caption).foregroundStyle(.red) }
                    Toggle("No key needed (local server)", isOn: $noKey)
                    SecureField("API key (stored in Keychain)", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: apiKey) { Keychain.set($0.trimmingCharacters(in: .whitespacesAndNewlines), for: "ai_api_key") }
                    Button {
                        testing = true
                        testResult = nil
                        Task {
                            do {
                                let r = try await AIClient.complete(system: "Reply briefly.", history: [ChatMessage(role: "user", text: "Say hi in five words.")])
                                testResult = "✅ " + String(r.prefix(120))
                            } catch {
                                testResult = "❌ " + error.localizedDescription
                            }
                            testing = false
                        }
                    } label: {
                        HStack { Text("Test connection"); if testing { Spacer(); ProgressView() } }
                    }
                    .disabled((apiKey.isEmpty && !noKey) || testing)
                    if let testResult { Text(testResult).font(.caption) }
                } header: {
                    Text("AI assistant")
                } footer: {
                    Text("Pick any provider and any model — including uncensored/abliterated ones on OpenRouter, or your own OpenAI-compatible server (LM Studio, Ollama, llama.cpp, vLLM). For a local server, enter its address (e.g. http://192.168.1.20:1234/v1), turn on “No key needed”, then Browse models. Free keys: console.groq.com, openrouter.ai. Without any provider the assistant still runs file commands offline.")
                }

                Section("Editor") {
                    Toggle("Wrap long lines", isOn: $wrap)
                    Toggle("Line numbers", isOn: $lineNumbers)
                }

                Section {
                    ForEach(places.external) { p in
                        Label(p.name, systemImage: p.symbol)
                    }
                    .onDelete { idx in idx.map { places.external[$0] }.forEach(places.removeExternal) }
                    if places.external.isEmpty {
                        Text("None yet. Use the location menu → “Add folder from Files…”.").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Folders from Files") } footer: { Text("Swipe to remove access. Files themselves aren't deleted.") }

                Section {
                    SecureField("GitHub token (optional)", text: $githubToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: githubToken) { Keychain.set($0, for: "github_token") }
                } header: {
                    Text("GitHub IPA search")
                } footer: {
                    Text("Used by IPA → “find …”. GitHub allows about 60 searches an hour without a token.")
                }

                Section("IPA editor") {
                    Toggle("Update extension bundle IDs too", isOn: $store.updateExtensionBundleIDs)
                }

                Section {
                    NavigationLink { MTAboutView() } label: { Label("About MT Files", systemImage: "info.circle") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
        }
    }

    private func preset(_ name: String, _ url: String, _ m: String, local: Bool = false) -> some View {
        Button(name) {
            baseURL = url
            model = m
            noKey = local
            models = []
        }
        .buttonStyle(.bordered)
        .font(.caption)
        .tint(baseURL == url && model == m ? Theme.accent : .gray)
    }
}

struct MTAboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    if let icon = UIImage(named: "AppIcon") {
                        AppIconView(image: icon, size: 88)
                    }
                    Text("MT Files").font(.title2.bold())
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · by Bobby Media Co")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            Section("Features") {
                Label("Two-pane file manager with copy/move between panes", systemImage: "rectangle.split.2x1")
                Label("Folders from iCloud Drive and other apps (kept across launches)", systemImage: "folder.badge.person.crop")
                Label("Zip / unzip, archive browser, IPA editor and unsigned repack", systemImage: "doc.zipper")
                Label("Code editor: syntax colors, line numbers, find/replace, go to line", systemImage: "chevron.left.forwardslash.chevron.right")
                Label("Hex viewer, plist editor, JSON formatter, image & media viewer", systemImage: "number")
                Label("AI assistant with confirm-before-run file commands and diffs", systemImage: "sparkles")
            }
            Section("Rules") {
                Text("MT Files does not crack apps, unlock subscriptions or in-app purchases, bypass licenses or DRM, or decrypt App Store apps. Use it with your own files and open-source apps.")
                    .font(.footnote)
            }
            Section("Open source") {
                Link("Source on GitHub", destination: URL(string: "https://github.com/Bobbykelvin11/mt-files-ios")!)
                Link("ZIPFoundation (MIT)", destination: URL(string: "https://github.com/weichsel/ZIPFoundation")!)
            }
        }
        .navigationTitle("About")
    }
}
