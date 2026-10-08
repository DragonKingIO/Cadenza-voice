import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Reading terms from a file the person picked: a pack or a list in JSON, or plain lines ("term | alias, alias").
enum VocabularyImport {
    static func parse(_ data: Data) -> [VocabEntry]? {
        guard data.count <= 2_000_000 else { return nil }
        var found: [VocabEntry] = []
        if let pack = try? JSONDecoder().decode(VocabPack.self, from: data) { found = pack.entries }
        else if let list = try? JSONDecoder().decode([VocabEntry].self, from: data) { found = list }
        else if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let raw = object["entries"],
                let entries = try? JSONSerialization.data(withJSONObject: raw), let list = try? JSONDecoder().decode([VocabEntry].self, from: entries) { found = list }
        else if let text = String(data: data, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                let aliases = parts.count > 1 ? parts[1].split(whereSeparator: { ",，、;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
                found.append(VocabEntry(term: parts[0], aliases: aliases))
            }
        }
        let valid = found.map(clean).filter { VocabularyRules.problem($0) == nil }
        return valid.isEmpty ? nil : valid
    }

    /// Drops an alias that equals the term or repeats another, so a hand-written list is not rejected for it.
    static func clean(_ e: VocabEntry) -> VocabEntry {
        var seen = Set([e.term.lowercased()]), aliases: [String] = []
        for a in e.aliases where seen.insert(a.lowercased()).inserted { aliases.append(a) }
        return VocabEntry(term: e.term.trimmingCharacters(in: .whitespacesAndNewlines), aliases: Array(aliases.prefix(12)))
    }

    /// Adds `new` to `existing`; a term that is already there takes the new aliases as well.
    static func merge(_ existing: [VocabEntry], _ new: [VocabEntry]) -> [VocabEntry] {
        var out = existing
        for e in new {
            if let i = out.firstIndex(where: { $0.term.lowercased() == e.term.lowercased() }) { out[i] = clean(VocabEntry(term: out[i].term, aliases: out[i].aliases + e.aliases)) }
            else { out.append(e) }
        }
        return Array(out.prefix(VocabularyRules.maxUserEntries))
    }

    /// The person's terms as a pack file, ready to share or to send to the project as a pull request.
    static func exportData(_ entries: [VocabEntry]) -> Data? {
        let pack = VocabPack(id: "my-terms", name: ["en": "My terms"], license: "CC0-1.0", entries: entries)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(pack)
    }
}

struct VocabularyView: View {
    @Bindable var model: SettingsModel
    @State private var user: [VocabEntry] = VocabularyStore.shared.user
    @State private var term = ""
    @State private var aliases = ""
    @State private var message: String?
    @State private var search = ""

    private var language: String { L10n.language }
    private var packs: [VocabPack] { VocabularyStore.shared.packs }

    var body: some View {
        SettingsPage {
            Section {
                Toggle(L10n.tr("vocab.enable"), isOn: Binding(get: { model.vocabulary.enabled }, set: { v in model.persist { $0.vocabulary.enabled = v } }))
                Toggle(L10n.tr("vocab.cloud"), isOn: Binding(get: { model.vocabulary.sendToCloud }, set: { v in model.persist { $0.vocabulary.sendToCloud = v } }))
                    .disabled(!model.vocabulary.enabled)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("vocab.hint"))
                    Text(L10n.tr("vocab.cloud.hint"))
                }.font(.callout).foregroundStyle(.primary)
            }
            Section {
                HStack {
                    TextField(L10n.tr("vocab.term"), text: $term).textFieldStyle(.roundedBorder)
                    TextField(L10n.tr("vocab.aliases"), text: $aliases, prompt: Text(L10n.tr("vocab.aliases.prompt"))).textFieldStyle(.roundedBorder)
                    Button(L10n.tr("vocab.add")) { add() }.disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let message { Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
                if user.count > 8 { TextField(L10n.tr("vocab.search"), text: $search).textFieldStyle(.roundedBorder) }
                ForEach(shown, id: \.term) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.term)
                            if !entry.aliases.isEmpty { Text(entry.aliases.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(role: .destructive) { remove(entry) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L10n.tr("vocab.remove"))
                    }
                }
                HStack {
                    Button(L10n.tr("vocab.import")) { importFile() }
                    Button(L10n.tr("vocab.export")) { exportFile() }.disabled(user.isEmpty)
                }
            } header: { Text(L10n.format("vocab.mine", String(user.count))) } footer: {
                Text(L10n.tr("vocab.mine.hint")).font(.callout).foregroundStyle(.primary)
            }
            Section {
                if packs.isEmpty { Text(L10n.tr("vocab.packs.none")).foregroundStyle(.secondary) }
                ForEach(packs, id: \.id) { pack in
                    Toggle(isOn: Binding(get: { model.vocabulary.isOn(pack) }, set: { v in model.persist { $0.vocabulary.packOverrides[pack.id] = v } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.localizedName(language) + " · " + L10n.format("vocab.count", String(pack.entries.count)))
                            Text(pack.localizedDescription(language)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(!model.vocabulary.enabled)
                }
            } header: { Text(L10n.tr("vocab.packs")) } footer: {
                Text(L10n.tr("vocab.packs.hint")).font(.callout).foregroundStyle(.primary)
            }
        }
        .onAppear { user = VocabularyStore.shared.user }
    }

    private var shown: [VocabEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? user : user.filter { $0.term.lowercased().contains(q) || $0.aliases.contains { $0.lowercased().contains(q) } }
    }

    private func save(_ entries: [VocabEntry]) -> Bool {
        guard VocabularyStore.shared.setUser(entries) else { message = L10n.tr("vocab.err.save"); return false }
        user = entries; model.persist { _ in }   // refresh anything that shows counts
        return true
    }

    private func add() {
        let list = aliases.split(whereSeparator: { ",，、;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let entry = VocabularyImport.clean(VocabEntry(term: term, aliases: list))
        guard VocabularyRules.problem(entry) == nil else { message = L10n.tr("vocab.err.invalid"); return }
        if save(VocabularyImport.merge(user, [entry])) { term = ""; aliases = ""; message = nil }
    }

    private func remove(_ entry: VocabEntry) { _ = save(user.filter { $0.term != entry.term }) }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let entries = VocabularyImport.parse(data) else { message = L10n.tr("vocab.err.import"); return }
        let before = user.count
        if save(VocabularyImport.merge(user, entries)) { message = L10n.format("vocab.imported", String(entries.count), String(user.count - before)) }
    }

    private func exportFile() {
        guard let data = VocabularyImport.exportData(user) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "my-terms.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = (try? data.write(to: url, options: .atomic)) != nil ? L10n.tr("vocab.exported") : L10n.tr("vocab.err.save")
    }
}
