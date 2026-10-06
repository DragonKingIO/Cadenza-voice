import SwiftUI
import AppKit

/// General page: language and appearance.
struct GeneralView: View {
    @Bindable var model: SettingsModel
    @State private var language = AppLanguage.current

    var body: some View {
        SettingsPage {
            Section {
                Picker(L10n.tr("general.language"), selection: Binding(get: { language }, set: { value in
                    language = value
                    AppLanguage.current = value
                })) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(L10n.tr("general.language.hint")).font(.callout).foregroundStyle(.primary)
            }
            Section {
                Picker(L10n.tr("general.appearance"), selection: Binding(get: { model.appearanceMode }, set: { value in
                    model.persist { $0.appearanceMode = value }
                    AppearanceController.apply(value)
                })) {
                    Text(L10n.tr("appearance.system")).tag("system")
                    Text(L10n.tr("appearance.light")).tag("light")
                    Text(L10n.tr("appearance.dark")).tag("dark")
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.tr("general.appearance.header"))
            }
            if CharacterAssets.present { IndicatorStyleSection() }
            Section {
                Toggle(L10n.tr("general.showDeveloper"), isOn: Binding(get: { model.showDeveloper }, set: { model.setShowDeveloper($0) }))
            } header: { Text(L10n.tr("general.advanced")) } footer: {
                Text(L10n.tr("general.showDeveloper.hint")).font(.callout).foregroundStyle(.primary)
            }
        }
    }
}
