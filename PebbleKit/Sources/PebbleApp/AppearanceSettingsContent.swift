import PebbleProtocol
import SwiftUI

/// How the watch looks and reads: the clock, the text, the units, and the
/// few settings that are about nothing in particular.
struct AppearanceSettingsContent: View {
    var watchSettings: [WatchSetting: Int]
    var board: WatchBoard?
    var isConnected: Bool
    var feedback: FeatureFeedback?
    var setWatchSetting: (WatchSetting, Int) -> Void

    /// Grouped by what a setting is about rather than listed in declaration
    /// order. Static and spelled out, so `WatchSettingGroupingTests` can hold
    /// that every setting is on exactly one screen — a new case added to
    /// `WatchSetting` fails a test instead of silently getting no row.
    static let appearanceSettings: [WatchSetting] = [
        .clock24Hour, .timelineQuickView, .textSize, .standbyMode, .menuScrollWrapAround,
    ]
    static let unitSettings: [WatchSetting] = [.unitsDistance, .unitsWind]

    private func rows(_ settings: [WatchSetting]) -> some View {
        ForEach(settings.filter { $0.isOffered(on: board) }, id: \.self) { setting in
            WatchSettingRow(
                setting: setting,
                rawValue: watchSettings[setting] ?? setting.defaultRawValue,
                setRawValue: { setWatchSetting(setting, $0) }
            )
        }
    }

    var body: some View {
        Form {
            // First, not last. A setting written to the watch answered below
            // every other setting, where the reader had stopped looking.
            if feedback != nil {
                Section { FeedbackBanner(feedback: feedback) }
            }
            Section("Appearance") {
                rows(Self.appearanceSettings)
            }
            Section("Units") {
                rows(Self.unitSettings)
            }
            if !isConnected {
                Section {
                    Label("Changes are kept and written when the watch connects.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Appearance"))
    }
}

#Preview("Connected") {
    NavigationStack {
        AppearanceSettingsContent(
            watchSettings: [.clock24Hour: 1, .unitsDistance: 0, .textSize: 2],
            // A Pebble Time 2, which has every conditional row.
            board: .obelixPVT,
            isConnected: true,
            feedback: nil,
            setWatchSetting: { _, _ in }
        )
    }
}

#Preview("Watch away") {
    NavigationStack {
        AppearanceSettingsContent(
            watchSettings: [:],
            // A watch the app cannot place, which hides the conditional rows.
            board: nil,
            isConnected: false,
            feedback: .failure("Pebble 5209 did not accept the setting."),
            setWatchSetting: { _, _ in }
        )
    }
}
