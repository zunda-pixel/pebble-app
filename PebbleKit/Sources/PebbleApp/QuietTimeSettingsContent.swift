import PebbleProtocol
import SwiftUI

/// The watch's own Quiet Time, which is not this app's Quiet Hours: this
/// silences the watch, while Quiet Hours on the Notifications screen decides
/// what the phone forwards at all. Kept apart so the two are never mistaken
/// for one setting (#93).
struct QuietTimeSettingsContent: View {
    var watchSettings: [WatchSetting: Int]
    var feedback: FeatureFeedback?
    var setWatchSetting: (WatchSetting, Int) -> Void

    private func row(_ setting: WatchSetting) -> WatchSettingRow {
        WatchSettingRow(
            setting: setting,
            rawValue: watchSettings[setting] ?? setting.defaultRawValue,
            setRawValue: { setWatchSetting(setting, $0) }
        )
    }

    private func isOn(_ setting: WatchSetting) -> Bool {
        (watchSettings[setting] ?? setting.defaultRawValue) != 0
    }

    var body: some View {
        Form {
            if feedback != nil {
                Section { FeedbackBanner(feedback: feedback) }
            }
            Section {
                row(.quietTimeManual)
                row(.quietTimeSmart)
            } footer: {
                Text("Quiet Time silences the watch. What the phone forwards is decided by Quiet Hours on the Notifications screen.")
            }
            Section {
                row(.quietTimeAutoDismiss)
            } footer: {
                Text("While Quiet Time is on, clear an arriving notification and return to the watchface instead of showing its popup.")
            }
            Section("Weekdays") {
                row(.quietTimeWeekdayScheduleEnabled)
                if isOn(.quietTimeWeekdayScheduleEnabled) {
                    row(.quietTimeWeekdaySchedule)
                }
            }
            Section("Weekends") {
                row(.quietTimeWeekendScheduleEnabled)
                if isOn(.quietTimeWeekendScheduleEnabled) {
                    row(.quietTimeWeekendSchedule)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Quiet Time"))
    }
}

#Preview("Quiet Time") {
    NavigationStack {
        QuietTimeSettingsContent(
            watchSettings: [
                .quietTimeWeekdayScheduleEnabled: 1,
                .quietTimeWeekdaySchedule: QuietTimeSchedule(
                    fromHour: 22, fromMinute: 30, toHour: 7, toMinute: 0
                ).rawValue,
            ],
            feedback: nil,
            setWatchSetting: { _, _ in }
        )
    }
}
