import PebbleProtocol
import SwiftUI

/// The watch's health settings, on a page of their own so the main Watch
/// Settings screen stays short. Activity tracking and the body metrics it works
/// from are on every watch; heart rate and blood oxygen only appear on a watch
/// whose board carries the sensor.
struct HealthWatchSettingsContent: View {
    var activitySettings: ActivitySettings
    var heartRateSettings: HeartRateSettings
    var heartRateZones: HeartRateZonePreferences = HeartRateZonePreferences()
    var bloodOxygenSettings: BloodOxygenSettings = BloodOxygenSettings()
    var board: WatchBoard?
    var feedback: FeatureFeedback?
    var setActivitySettings: (ActivitySettings) -> Void
    var setHeartRateSettings: (HeartRateSettings) -> Void
    var setHeartRateZones: (HeartRateZonePreferences) -> Void = { _ in }
    var setBloodOxygenSettings: (BloodOxygenSettings) -> Void = { _ in }

    var body: some View {
        Form {
            if feedback != nil {
                Section { FeedbackBanner(feedback: feedback) }
            }

            Section {
                Toggle("Track Activity", isOn: activityBinding(\.isTrackingEnabled))
                Toggle("Activity Insights", isOn: activityBinding(\.areActivityInsightsEnabled))
                Toggle("Sleep Insights", isOn: activityBinding(\.areSleepInsightsEnabled))
            } header: {
                Text("Activity")
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
                // As the firmware numbers them: 0 female, 1 male, 2 other.
                Picker("Gender", selection: Binding(
                    get: { Int(activitySettings.gender) },
                    set: { value in
                        var settings = activitySettings
                        settings.gender = Int8(clamping: value)
                        setActivitySettings(settings)
                    }
                )) {
                    Text("Female").tag(0)
                    Text("Male").tag(1)
                    Text("Other").tag(2)
                }
            } header: {
                Text("About You")
            } footer: {
                Text("The watch works out calories and distance from these. They are sent as one record, so all of them are written together.")
            }

            // Heart rate and blood oxygen share the one sensor, which only the
            // Pebble Time 2 (obelix) carries. A watch without it — Pebble 2 Duo,
            // Pebble Round 2 — gets neither row, the way the backlight rows hide
            // on a board that lacks their hardware.
            if board?.hasHeartRateSensor == true {
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

                if heartRateSettings.isEnabled {
                    Section {
                        zoneStepper("Resting", \.restingBPM)
                        zoneStepper("Elevated", \.elevatedBPM)
                        zoneStepper("Maximum", \.maximumBPM)
                        zoneStepper("Zone 1", \.zone1BPM)
                        zoneStepper("Zone 2", \.zone2BPM)
                        zoneStepper("Zone 3", \.zone3BPM)
                    } header: {
                        Text("Heart Rate Zones")
                    } footer: {
                        // The same two chains the firmware's own handler enforces;
                        // a step that would break one simply does not move.
                        Text("The watch grades a workout against these. Resting stays under elevated, elevated under maximum, and each zone starts above the one before.")
                    }
                }

                Section {
                    Toggle("Blood Oxygen", isOn: Binding(
                        get: { bloodOxygenSettings.isEnabled },
                        set: { isOn in
                            var settings = bloodOxygenSettings
                            settings.isEnabled = isOn
                            setBloodOxygenSettings(settings)
                        }
                    ))
                    if bloodOxygenSettings.isEnabled {
                        // Off is not a reading here: the watch keeps blood oxygen's
                        // on/off in its own pref, which is the toggle above, so the
                        // interval only ever names how often.
                        Picker("Reading", selection: Binding(
                            get: { bloodOxygenSettings.interval == .off ? .everyTenMinutes : bloodOxygenSettings.interval },
                            set: { interval in
                                var settings = bloodOxygenSettings
                                settings.interval = interval
                                setBloodOxygenSettings(settings)
                            }
                        )) {
                            ForEach(HeartRateInterval.allCases.filter { $0 != .off }, id: \.self) { interval in
                                Text(interval.title).tag(interval)
                            }
                        }
                        Toggle("Read During Activity", isOn: Binding(
                            get: { bloodOxygenSettings.isEnabledDuringActivity },
                            set: { isOn in
                                var settings = bloodOxygenSettings
                                settings.isEnabledDuringActivity = isOn
                                setBloodOxygenSettings(settings)
                            }
                        ))
                    }
                } header: {
                    Text("Blood Oxygen")
                } footer: {
                    Text("Measures blood oxygen (SpO2) on its own schedule, off until you turn it on.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Health"))
    }

    /// One boundary of the zones, stepped in beats per minute. A step that
    /// would put the numbers out of order does not move: the firmware's
    /// handler would refuse the whole record and reset it, so refusing the
    /// step here is the kinder version of the same rule.
    private func zoneStepper(
        _ title: LocalizedStringKey,
        _ keyPath: WritableKeyPath<HeartRateZonePreferences, Int>
    ) -> some View {
        Stepper(
            value: Binding(
                get: { heartRateZones[keyPath: keyPath] },
                set: { value in
                    var changed = heartRateZones
                    changed[keyPath: keyPath] = value
                    guard changed.isValid else { return }
                    setHeartRateZones(changed)
                }
            ),
            in: 1...255
        ) {
            LabeledContent(title) {
                Text("\(heartRateZones[keyPath: keyPath]) bpm")
            }
        }
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

#Preview("Sensor watch") {
    NavigationStack {
        HealthWatchSettingsContent(
            activitySettings: ActivitySettings(),
            heartRateSettings: HeartRateSettings(),
            bloodOxygenSettings: BloodOxygenSettings(
                isEnabled: true,
                interval: .everyThirtyMinutes,
                isEnabledDuringActivity: true
            ),
            board: .obelixPVT,
            feedback: nil,
            setActivitySettings: { _ in },
            setHeartRateSettings: { _ in },
            setHeartRateZones: { _ in },
            setBloodOxygenSettings: { _ in }
        )
    }
}

#Preview("No sensor") {
    NavigationStack {
        HealthWatchSettingsContent(
            activitySettings: ActivitySettings(),
            heartRateSettings: HeartRateSettings(isEnabled: false),
            board: .asterix,
            feedback: nil,
            setActivitySettings: { _ in },
            setHeartRateSettings: { _ in }
        )
    }
}
