import API
import SwiftUI

/// The watch's own settings, and what its health tracking is told.
struct WatchSettingsView: View {
    var model: AppModel
    var watchID: String

    private var connection: WatchConnection? {
        model.connections.first { $0.device.id == watchID }
    }

    private var isConnected: Bool {
        connection?.isConnected == true
    }

    var body: some View {
        Form {
            Section {
                ForEach(WatchSetting.allCases, id: \.self) { setting in
                    Toggle(setting.title, isOn: Binding(
                        get: { model.isWatchSettingOn(setting) },
                        set: { isOn in Task { await model.setWatchSetting(setting, isOn: isOn) } }
                    ))
                }
            } header: {
                Text("On the Watch")
            } footer: {
                Text("These are the watch's own settings. They are written again whenever it connects, so this is the copy that wins.")
            }

            Section {
                Toggle("Track Activity", isOn: Binding(
                    get: { model.activitySettings.isTrackingEnabled },
                    set: { isOn in
                        var settings = model.activitySettings
                        settings.isTrackingEnabled = isOn
                        Task { await model.setActivitySettings(settings) }
                    }
                ))
                Toggle("Activity Insights", isOn: Binding(
                    get: { model.activitySettings.areActivityInsightsEnabled },
                    set: { isOn in
                        var settings = model.activitySettings
                        settings.areActivityInsightsEnabled = isOn
                        Task { await model.setActivitySettings(settings) }
                    }
                ))
                Toggle("Sleep Insights", isOn: Binding(
                    get: { model.activitySettings.areSleepInsightsEnabled },
                    set: { isOn in
                        var settings = model.activitySettings
                        settings.areSleepInsightsEnabled = isOn
                        Task { await model.setActivitySettings(settings) }
                    }
                ))
            } header: {
                Text("Health")
            }

            Section {
                Stepper(
                    "Height: \(heightMeasurement.formatted(.measurement(width: .abbreviated)))",
                    value: Binding(
                        get: { Int(model.activitySettings.heightMillimetres) },
                        set: { value in
                            var settings = model.activitySettings
                            settings.heightMillimetres = Int16(clamping: value)
                            Task { await model.setActivitySettings(settings) }
                        }
                    ),
                    in: 1_000...2_300,
                    step: 10
                )
                Stepper(
                    "Weight: \(weightMeasurement.formatted(.measurement(width: .abbreviated)))",
                    value: Binding(
                        get: { Int(model.activitySettings.weightDecagrams) },
                        set: { value in
                            var settings = model.activitySettings
                            settings.weightDecagrams = Int16(clamping: value)
                            Task { await model.setActivitySettings(settings) }
                        }
                    ),
                    in: 3_000...20_000,
                    step: 50
                )
                Stepper(
                    "Age: \(model.activitySettings.ageYears, format: .number)",
                    value: Binding(
                        get: { Int(model.activitySettings.ageYears) },
                        set: { value in
                            var settings = model.activitySettings
                            settings.ageYears = Int8(clamping: value)
                            Task { await model.setActivitySettings(settings) }
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
                    get: { model.heartRateSettings.isEnabled },
                    set: { isOn in
                        var settings = model.heartRateSettings
                        settings.isEnabled = isOn
                        Task { await model.setHeartRateSettings(settings) }
                    }
                ))
                if model.heartRateSettings.isEnabled {
                    Picker("Reading", selection: Binding(
                        get: { model.heartRateSettings.interval },
                        set: { interval in
                            var settings = model.heartRateSettings
                            settings.interval = interval
                            Task { await model.setHeartRateSettings(settings) }
                        }
                    )) {
                        ForEach(PebbleHeartRateInterval.allCases, id: \.self) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    Toggle("Read During Activity", isOn: Binding(
                        get: { model.heartRateSettings.isEnabledDuringActivity },
                        set: { isOn in
                            var settings = model.heartRateSettings
                            settings.isEnabledDuringActivity = isOn
                            Task { await model.setHeartRateSettings(settings) }
                        }
                    ))
                }
            } header: {
                Text("Heart Rate")
            }

            Section {
                Toggle("Reminders App", isOn: Binding(
                    get: { model.isReminderAppEnabled },
                    set: { isOn in Task { await model.setReminderAppEnabled(isOn) } }
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
            if let message = model.watchSettingsStatusMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Watch Settings")
    }

    private var heightMeasurement: Measurement<UnitLength> {
        Measurement(value: Double(model.activitySettings.heightMillimetres), unit: .millimeters)
            .converted(to: Locale.current.measurementSystem == .us ? .inches : .centimeters)
    }

    private var weightMeasurement: Measurement<UnitMass> {
        // The firmware counts weight in decagrams: 7000 is 70 kg.
        Measurement(value: Double(model.activitySettings.weightDecagrams) / 100, unit: .kilograms)
            .converted(to: Locale.current.measurementSystem == .us ? .pounds : .kilograms)
    }
}
