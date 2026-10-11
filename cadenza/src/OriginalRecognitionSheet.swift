import SwiftUI

/// Comparing the latest result is an explicit action, separate from the recording HUD and external text insertion.
struct OriginalRecognitionSheet: View {
    @Bindable var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    private var pipeline: VoicePipeline? { model.pipeline }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("result.original.title")).font(.headline)
            Form {
                Section(L10n.tr("result.original.label")) {
                    ScrollView { Text(pipeline?.lastOriginalTranscript ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 100)
                }
                Section(L10n.tr("result.processed.label")) {
                    ScrollView { Text(pipeline?.lastProcessedTranscript ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 100)
                }
            }.formStyle(.grouped)
            Text(L10n.tr("result.original.scope")).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(L10n.tr("result.original.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr(pipeline?.showingOriginalTranscript == true ? "result.processed.use" : "result.original.use")) {
                    model.selectOriginalResult(!model.originalResultSelected); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(pipeline?.canCompareTranscript != true)
            }
        }.padding(20).frame(width: 520, height: 430)
    }
}
