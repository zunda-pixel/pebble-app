import PebbleProtocol
import SwiftUI

struct WatchSettingsView: View {
    var model: AppModel
    var watchID: WatchID

    private var connection: WatchConnection? {
        model.connections.first { $0.watch.id == watchID }
    }

    var body: some View {
        WatchSettingsContent(
            watchSettings: Dictionary(
                uniqueKeysWithValues: WatchSetting.allCases.map { ($0, model.watchSettingValue($0)) }
            ),
            activitySettings: model.watchSettings.activity,
            heartRateSettings: model.watchSettings.heartRate,
            isReminderAppEnabled: model.timeline.isReminderAppEnabled,
            isConnected: connection?.isConnected == true,
            feedback: model.watchSettings.feedback,
            setWatchSetting: { setting, rawValue in
                Task { await model.setWatchSetting(setting, rawValue: rawValue) }
            },
            setActivitySettings: { settings in
                Task { await model.setActivitySettings(settings) }
            },
            setHeartRateSettings: { settings in
                Task { await model.setHeartRateSettings(settings) }
            },
            setReminderAppEnabled: { isOn in
                Task { await model.setReminderAppEnabled(isOn) }
            }
        )
    }
}

/// The watch's own settings, and what its health tracking is told.
/// One watch setting: a switch where it is one, a picker where it is a choice.
///
/// Both write the same thing — the number the firmware keeps — so the row is
/// the only place that has to know which shape a setting has.
struct WatchSettingRow: View {
    var setting: WatchSetting
    var rawValue: Int
    var setRawValue: (Int) -> Void

    var body: some View {
        switch setting.kind {
        case .boolean:
            Toggle(setting.title, isOn: Binding(
                get: { rawValue != 0 },
                set: { setRawValue($0 ? 1 : 0) }
            ))
        case .choice:
            Picker(setting.title, selection: Binding(get: { rawValue }, set: setRawValue)) {
                ForEach(Array(setting.optionTitles.enumerated()), id: \.offset) { option in
                    Text(option.element).tag(option.offset)
                }
            }
        }
    }
}

struct WatchSettingsContent: View {
    var watchSettings: [WatchSetting: Int]
    var activitySettings: ActivitySettings
    var heartRateSettings: HeartRateSettings
    var isReminderAppEnabled: Bool
    var isConnected: Bool
    var feedback: FeatureFeedback?
    var setWatchSetting: (WatchSetting, Int) -> Void
    var setActivitySettings: (ActivitySettings) -> Void
    var setHeartRateSettings: (HeartRateSettings) -> Void
    var setReminderAppEnabled: (Bool) -> Void

    var body: some View {
        Form {
            // First, not last. A setting written to the watch answered below
            // every other setting, where the reader had stopped looking.
            if feedback != nil {
                Section { FeedbackBanner(feedback: feedback) }
            }
            Section {
                ForEach(WatchSetting.allCases, id: \.self) { setting in
                    WatchSettingRow(
                        setting: setting,
                        rawValue: watchSettings[setting] ?? setting.defaultRawValue,
                        setRawValue: { setWatchSetting(setting, $0) }
                    )
                }
            } header: {
                Text("On the Watch")
            } footer: {
                Text("These are the watch's own settings. They are written again whenever it connects, so this is the copy that wins.")
            }

            Section {
                Toggle("Track Activity", isOn: activityBinding(\.isTrackingEnabled))
                Toggle("Activity Insights", isOn: activityBinding(\.areActivityInsightsEnabled))
                Toggle("Sleep Insights", isOn: activityBinding(\.areSleepInsightsEnabled))
            } header: {
                Text("Health")
            }

            Section {
                Stepper(
                    "Height: \(heightMeasurement.formatted(.measurement(width: .abbreviated)))",
                    value: Binding(
                        get: { Int(activitySettings.heightMillimetres) },
                        set: { value in
                            var settings = activitySettings
                            settings.heightMillimetres = Int16(clamping: value)
                            setActivitySettings(settings)
                        }
                    ),
                    in: 1_000...2_300,
                    step: 10
                )
                Stepper(
                    "Weight: \(weightMeasurement.formatted(.measurement(width: .abbreviated)))",
                    value: Binding(
                        get: { Int(activitySettings.weightDecagrams) },
                        set: { value in
                            var settings = activitySettings
                            settings.weightDecagrams = Int16(clamping: value)
                            setActivitySettings(settings)
                        }
                    ),
                    in: 3_000...20_000,
                    step: 50
                )
                Stepper(
                    "Age: \(activitySettings.ageYears, format: .number)",
                    value: Binding(
                        get: { Int(activitySettings.ageYears) },
                        set: { value in
                            var settings = activitySettings
                            settings.ageYears = Int8(clamping: value)
                            setActivitySettings(settings)
                        }
                    ),
                    in: 5...120
                )
            } header: {
                Text("About You")
            } footer: {
                Text("The watch works out calories and distance from these. They are sent as one record, so all of them are written together.")
            }

            Section {
                Toggle("Heart Rate", isOn: Binding(
                    get: { heartRateSettings.isEnabled },
                    set: { isOn in
                        var settings = heartRateSettings
                        settings.isEnabled = isOn
                        setHeartRateSettings(settings)
                    }
                ))
                if heartRateSettings.isEnabled {
                    // Off is left out of the choices: the watch keeps a separate
                    // flag for that, which is the toggle above, and offering it
                    // twice would let the two disagree.
                    Picker("Reading", selection: Binding(
                        get: { heartRateSettings.interval == .off ? .everyTenMinutes : heartRateSettings.interval },
                        set: { interval in
                            var settings = heartRateSettings
                            settings.interval = interval
                            setHeartRateSettings(settings)
                        }
                    )) {
                        ForEach(HeartRateInterval.allCases.filter { $0 != .off }, id: \.self) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    Toggle("Read During Activity", isOn: Binding(
                        get: { heartRateSettings.isEnabledDuringActivity },
                        set: { isOn in
                            var settings = heartRateSettings
                            settings.isEnabledDuringActivity = isOn
                            setHeartRateSettings(settings)
                        }
                    ))
                }
            } header: {
                Text("Heart Rate")
            }

            Section {
                Toggle("Reminders App", isOn: Binding(
                    get: { isReminderAppEnabled },
                    set: { isOn in setReminderAppEnabled(isOn) }
                ))
            } footer: {
                Text("Turns the watch's own Reminders app on, which is where the reminders added on the Timeline screen appear.")
            }

            if !isConnected {
                Section {
                    Label("Changes are kept and written when the watch connects.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Watch Settings"))
    }

    private func activityBinding(_ keyPath: WritableKeyPath<ActivitySettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { activitySettings[keyPath: keyPath] },
            set: { isOn in
                var settings = activitySettings
                settings[keyPath: keyPath] = isOn
                setActivitySettings(settings)
            }
        )
    }

    private var heightMeasurement: Measurement<UnitLength> {
        Measurement(value: Double(activitySettings.heightMillimetres), unit: .millimeters)
            .converted(to: Locale.current.measurementSystem == .us ? .inches : .centimeters)
    }

    private var weightMeasurement: Measurement<UnitMass> {
        // The firmware counts weight in decagrams: 7000 is 70 kg.
        Measurement(value: Double(activitySettings.weightDecagrams) / 100, unit: .kilograms)
            .converted(to: Locale.current.measurementSystem == .us ? .pounds : .kilograms)
    }
}

#Preview("Connected") {
    NavigationStack {
        WatchSettingsContent(
            watchSettings: [.clock24Hour: 1, .backlight: 1, .unitsDistance: 0, .textSize: 2],
            activitySettings: ActivitySettings(),
            heartRateSettings: HeartRateSettings(),
            isReminderAppEnabled: true,
            isConnected: true,
            feedback: nil,
            setWatchSetting: { _, _ in },
            setActivitySettings: { _ in },
            setHeartRateSettings: { _ in },
            setReminderAppEnabled: { _ in }
        )
    }
}

#Preview("Heart rate off, watch away") {
    NavigationStack {
        WatchSettingsContent(
            watchSettings: [:],
            activitySettings: ActivitySettings(),
            heartRateSettings: HeartRateSettings(
                isEnabled: false,
                interval: .everyThirtyMinutes,
                isEnabledDuringActivity: false
            ),
            isReminderAppEnabled: false,
            isConnected: false,
            feedback: .failure("Pebble 5209 did not accept the setting."),
            setWatchSetting: { _, _ in },
            setActivitySettings: { _ in },
            setHeartRateSettings: { _ in },
            setReminderAppEnabled: { _ in }
        )
    }
}
