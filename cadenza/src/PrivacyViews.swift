import SwiftUI
import AppKit

// MARK: - Minimal Markdown blocks for the bundled notices

enum LegalBlock: Equatable {
    case heading(Int, String), bullet(String), paragraph(String), row([String])

    static func parse(_ markdown: String) -> [LegalBlock] {
        var blocks: [LegalBlock] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(min(level, 3), line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix("|") {
                let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue } // header separator
                blocks.append(.row(cells))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }
}

struct LegalDocumentSheet: View {
    let document: LegalDocument
    var onClose: () -> Void
    var body: some View { MarkdownSheet(title: document.title, markdown: document.text(), onClose: onClose) }
}

/// Bundled Markdown shown in a sheet (privacy notice, terms, interface documentation).
struct MarkdownSheet: View {
    let title: String
    let markdown: String?
    var onClose: () -> Void

    private var blocks: [LegalBlock] { markdown.map(LegalBlock.parse) ?? [] }

    private func styled(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(attributed) }
        return Text(text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline); Spacer(); Button(L10n.tr("legal.close")) { onClose() }.keyboardShortcut(.cancelAction) }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if blocks.isEmpty { Text(L10n.tr("legal.unavailable")).foregroundStyle(.secondary) }
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .heading(let level, let text): Text(text).font(level == 1 ? .title2.bold() : .headline).padding(.top, level == 1 ? 0 : 6)
                        case .bullet(let text): HStack(alignment: .top, spacing: 6) { Text("•"); styled(text) }
                        case .paragraph(let text): styled(text)
                        case .row(let cells):
                            VStack(alignment: .leading, spacing: 2) {
                                if let first = cells.first { styled(first).fontWeight(.semibold) }
                                ForEach(Array(cells.dropFirst().enumerated()), id: \.offset) { _, cell in styled(cell).font(.callout).foregroundStyle(.secondary) }
                            }.padding(.vertical, 3)
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
    }
}

// MARK: - Privacy page pieces

struct PrivacyPromiseSection: View {
    var body: some View {
        Section {
            ForEach(["privacy.promise.collect", "privacy.promise.voice", "privacy.promise.keep", "privacy.promise.keys"], id: \.self) { key in
                Label { Text(key == "privacy.promise.collect" ? L10n.format(key, String(describing: Brand.name)) : L10n.tr(key)).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "lock.shield").foregroundStyle(.tint) }
            }
        } header: { Text(L10n.tr("privacy.promise.header")) }
    }
}

struct PrivacyControlsSection: View {
    @State private var logging = DiagnosticLogging.enabled
    @State private var logSize = LogFile.size
    @State private var confirmingKeys = false
    @State private var message = ""
    @State private var shown: LegalDocument?

    var body: some View {
        Section {
            Toggle(L10n.tr("privacy.log.toggle"), isOn: Binding(get: { logging }, set: { logging = $0; DiagnosticLogging.enabled = $0 }))
            LabeledContent(L10n.tr("privacy.log.size")) {
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(logSize), countStyle: .file)).foregroundStyle(.secondary)
                    Button(L10n.tr("privacy.log.clear"), role: .destructive) { message = LogFile.clear() ? L10n.tr("privacy.log.cleared") : L10n.tr("privacy.failed"); logSize = LogFile.size }
                        .buttonStyle(.borderless).disabled(logSize == 0)
                }
            }
            LabeledContent(L10n.tr("privacy.credentials")) {
                Button(L10n.tr("privacy.credentials.delete"), role: .destructive) { confirmingKeys = true }.buttonStyle(.borderless)
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
        } header: { Text(L10n.tr("privacy.controls.header")) } footer: {
            Text(L10n.tr("privacy.log.footer")).font(.callout).foregroundStyle(.primary)
        }
        .confirmationDialog(L10n.tr("privacy.credentials.confirm"), isPresented: $confirmingKeys) {
            Button(L10n.tr("privacy.credentials.delete"), role: .destructive) {
                let result = PrivacyControls.deleteAllCredentials()
                message = result.failed > 0 ? L10n.tr("privacy.failed") : result.removed == 0 ? L10n.tr("privacy.credentials.none") : L10n.format("privacy.credentials.done", result.removed)
            }
        }
        Section {
            ForEach(LegalDocument.allCases, id: \.self) { doc in
                Button(doc.title) { shown = doc }.buttonStyle(.link)
            }
            LabeledContent(L10n.tr("legal.status")) {
                Text(TermsAcceptance.accepted ? L10n.format("legal.accepted", LegalDocument.version) : L10n.tr("legal.notAccepted")).foregroundStyle(.secondary)
            }
        } header: { Text(L10n.tr("legal.header")) }
        .sheet(item: $shown) { doc in LegalDocumentSheet(document: doc) { shown = nil } }
        .onAppear { logSize = LogFile.size; logging = DiagnosticLogging.enabled }
    }
}

extension LegalDocument: Identifiable { var id: String { rawValue } }
