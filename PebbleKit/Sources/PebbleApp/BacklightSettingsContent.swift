import PebbleProtocol
import SwiftUI

/// The backlight, whole, on a screen of its own.
///
/// The watch keeps these behind its own Backlight Settings submenu, and this
/// screen follows it for the same two reasons: eight rows of one feature were
/// drowning the main list, and a reader who changes the duration while a
/// preset is chosen sees the brightness fall to Custom — surprising on a flat
/// list (#116), expected on a screen that groups the preset with the values
/// it stands for.
struct BacklightSettingsContent: View {
    var watchSettings: [WatchSetting: Int]
    var board: WatchBoard?
    var feedback: FeatureFeedback?
    var setWatchSetting: (WatchSetting, Int) -> Void

    /// The rows below the preset, in the order of `WatchSetting.allCases`.
    ///
    /// The colour is not one of them, although it is a backlight setting: the
    /// footer under these says changing them makes the brightness Custom, and
    /// the colour does not — no preset stands for a colour, and
    /// `backlight_get_preset` never compares it. It sits with the preset
    /// above instead.
    private var individualSettings: [WatchSetting] {
        WatchSetting.allCases.filter {
            $0.isBacklight && $0 != .backlight && $0 != .backlightPreset
                && $0 != .backlightColor && $0.isOffered(on: board)
        }
    }

    private func row(_ setting: WatchSetting) -> WatchSettingRow {
        WatchSettingRow(
            setting: setting,
            rawValue: watchSettings[setting] ?? setting.defaultRawValue,
            setRawValue: { setWatchSetting(setting, $0) }
        )
    }

    var body: some View {
        Form {
            // The same banner the main screen shows: a write these rows caused
            // should not answer on a screen the reader has left.
            if feedback != nil {
                Section { FeedbackBanner(feedback: feedback) }
            }
            Section {
                row(.backlight)
                row(.backlightPreset)
                if WatchSetting.backlightColor.isOffered(on: board) {
                    row(.backlightColor)
                }
            }
            Section {
                ForEach(individualSettings, id: \.self, content: row)
            } footer: {
                Text("Changing any of these sets Backlight Brightness to Custom, as it does on the watch itself.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Backlight"))
    }
}

#Preview("Backlight screen") {
    NavigationStack {
        BacklightSettingsContent(
            watchSettings: [
                .backlight: 1, .backlightPreset: 3, .backlightTimeout: 8_000,
                .backlightIntensity: 72,
            ],
            board: .obelixPVT,
            feedback: nil,
            setWatchSetting: { _, _ in }
        )
    }
}
