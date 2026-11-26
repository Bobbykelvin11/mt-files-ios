import SwiftUI

enum PlistValueType: String, CaseIterable, Identifiable {
    case string = "String"
    case number = "Number"
    case boolean = "Boolean"
    case json = "Array / Dictionary (JSON)"
    var id: String { rawValue }
}

struct PlistEntry: Identifiable {
    let id = UUID()
    var originalKey: String?
    var key: String
    var type: PlistValueType
    var text: String
    var bool: Bool
    var readOnly: Bool
}

/// Raw key editor for an Info.plist (top-level keys; nested values as JSON).
struct PlistEditorView: View {
    let plistURL: URL
    var onSave: () -> Void = {}

    @State private var dict: [String: Any] = [:]
    @State private var format: PropertyListSerialization.PropertyListFormat = .binary
    @State private var editing: PlistEntry?
    @State private var filter = ""
    @State private var error: String?

    private var keys: [String] {
        let all = dict.keys.sorted()
        guard !filter.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List {
            ForEach(keys, id: \.self) { key in
                Button {
                    editing = entry(for: key)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key).font(.subheadline.bold()).foregroundStyle(.primary)
                        Text(preview(dict[key])).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        dict.removeValue(forKey: key)
                        persist()
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter keys")
        .navigationTitle("Info.plist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = PlistEntry(originalKey: nil, key: "", type: .string, text: "", bool: true, readOnly: false)
                } label: { Image(systemName: "plus") }
            }
        }
        .onAppear(perform: load)
        .sheet(item: $editing) { entry in
            PlistEntryEditor(entry: entry) { updated in
                apply(updated)
            }
        }
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func load() {
        do {
            let r = try PlistIO.read(plistURL)
            dict = r.dict
            format = r.format
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func persist() {
        do {
            try PlistIO.write(dict, to: plistURL, format: format)
            onSave()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func entry(for key: String) -> PlistEntry {
        let value = dict[key] as Any
        if PlistIO.isBool(value), let b = value as? Bool {
            return PlistEntry(originalKey: key, key: key, type: .boolean, text: "", bool: b, readOnly: false)
        }
        if let n = value as? NSNumber {
            return PlistEntry(originalKey: key, key: key, type: .number, text: n.stringValue, bool: false, readOnly: false)
        }
        if let s = value as? String {
            return PlistEntry(originalKey: key, key: key, type: .string, text: s, bool: false, readOnly: false)
        }
        if (value is [Any] || value is [String: Any]), JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return PlistEntry(originalKey: key, key: key, type: .json, text: json, bool: false, readOnly: false)
        }
        return PlistEntry(originalKey: key, key: key, type: .string, text: String(describing: value), bool: false, readOnly: true)
    }

    private func apply(_ e: PlistEntry) {
        let key = e.key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { error = "Key can't be empty"; return }
        let value: Any
        switch e.type {
        case .string:
            value = e.text
        case .boolean:
            value = e.bool
        case .number:
            if let i = Int(e.text) { value = i } else if let d = Double(e.text) { value = d } else {
                error = "“\(e.text)” isn't a number"; return
            }
        case .json:
            guard let data = e.text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  obj is [Any] || obj is [String: Any] else {
                error = "That isn't valid JSON (array or object)."
                return
            }
            value = obj
        }
        if let old = e.originalKey, old != key { dict.removeValue(forKey: old) }
        dict[key] = value
        persist()
    }

    private func preview(_ value: Any?) -> String {
        guard let value else { return "" }
        if PlistIO.isBool(value), let b = value as? Bool { return b ? "YES" : "NO" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let a = value as? [Any] { return "Array (\(a.count) items)" }
        if let d = value as? [String: Any] { return "Dictionary (\(d.count) keys)" }
        if let data = value as? Data { return "Data (\(data.count) bytes)" }
        return String(describing: value)
    }
}

struct PlistEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: PlistEntry
    let onSave: (PlistEntry) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    TextField("Key", text: $entry.key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if entry.readOnly {
                    Section {
                        Text(entry.text).font(.caption.monospaced())
                        Text("This value type (data/date) can't be edited here. Use the file browser to edit Info.plist as XML.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Type") {
                        Picker("Type", selection: $entry.type) {
                            ForEach(PlistValueType.allCases) { t in Text(t.rawValue).tag(t) }
                        }
                    }
                    Section("Value") {
                        switch entry.type {
                        case .boolean:
                            Toggle(entry.bool ? "YES" : "NO", isOn: $entry.bool)
                        case .number:
                            TextField("0", text: $entry.text).keyboardType(.numbersAndPunctuation)
                        case .string:
                            TextField("Value", text: $entry.text, axis: .vertical)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        case .json:
                            TextEditor(text: $entry.text)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 220)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                }
            }
            .navigationTitle(entry.originalKey == nil ? "New key" : "Edit key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(entry)
                        dismiss()
                    }
                    .disabled(entry.readOnly && entry.key == entry.originalKey)
                }
            }
        }
    }
}
