import PebbleProtocol
import SwiftUI

struct WatchSettingsView: View {
    var model: AppModel
    var watchID: WatchID

    private var connection: WatchConnection? {
        model.connections.first { $0.watch.id == watchID }
    }

    /// The connected watch's board, or the remembered one while it is away —
    /// the same fallback the firmware screen uses. Nil for a watch neither
    /// knows, which hides the rows only some boards have.
    private var board: WatchBoard? {
        connection?.watch.board ?? model.watches.saved.first { $0.id == watchID }?.board
    }

    var body: some View {
        WatchSettingsContent(
            watchSettings: Dictionary(
                uniqueKeysWithValues: WatchSetting.allCases.map { setting in
                    // The brightness row shows the preset the watch would
                    // report rather than the number last written, the way
                    // `backlight_get_preset` derives it: turning the brightness
                    // down by hand leaves the watch on "Custom", and this
                    // screen has to say so instead of claiming a preset the
                    // watch has left behind.
                    guard setting == .backlightPreset else {
                        return (setting, model.watchSettingValue(setting))
                    }
                    return (
                        setting,
                        BacklightPreset.reported(by: { model.watchSettingValue($0) }, on: board)
                    )
                }
            ),
            board: board,
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

    /// Where a dragging slider is now, before it has been written anywhere.
    /// Nil while nothing is being dragged, so that a value arriving from the
    /// watch is shown rather than being held off by a stale draft.
    @State private var draft: Int?

    private func commitDraft() {
        guard let draft else { return }
        setRawValue(draft)
        self.draft = nil
    }

    var body: some View {
        switch setting.kind {
        case .boolean:
            Toggle(setting.title, isOn: Binding(
                get: { rawValue != 0 },
                set: { setRawValue($0 ? 1 : 0) }
            ))
        case .choice, .duration:
            Picker(setting.title, selection: Binding(get: { rawValue }, set: setRawValue)) {
                // Tagged by the value, not by where the option sits: a
                // duration's value is its milliseconds.
                ForEach(Array(zip(setting.optionRawValues, setting.optionTitles)), id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
        case .number(let range):
            // Not a picker: a hundred numbered rows would be a worse way to
            // say "somewhere between dim and bright".
            VStack(alignment: .leading) {
                LabeledContent(setting.title) {
                    Text(Double(draft ?? rawValue) / 100, format: .percent)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(draft ?? rawValue) },
                        set: { draft = Int($0.rounded()) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    // Whole numbers, because the setting is one — and because a
                    // slider adjusted by voice moves by its step.
                    step: 1,
                    // On the way up rather than on every step: each write goes
                    // to the watch, and a drag across the slider would be a
                    // hundred of them.
                    onEditingChanged: { isDragging in
                        guard !isDragging else { return }
                        commitDraft()
                    }
                )
                // The documented callback covers a drag; it says nothing about
                // a slider moved by voice, and a value that is only ever shown
                // is a value quietly thrown away. So a draft left behind is
                // written when the screen goes rather than never.
                .onDisappear(perform: commitDraft)
            }
        }
    }
}

struct WatchSettingsContent: View {
    var watchSettings: [WatchSetting: Int]
    var board: WatchBoard?
    var activitySettings: ActivitySettings
    var heartRateSettings: HeartRateSettings
    var isReminderAppEnabled: Bool
    var isConnected: Bool
    var feedback: FeatureFeedback?
    var setWatchSetting: (WatchSetting, Int) -> Void
    var setActivitySettings: (ActivitySettings) -> Void
    var setHeartRateSettings: (HeartRateSettings) -> Void
    var setReminderAppEnabled: (Bool) -> Void

    /// The settings that get a row, which depends on whose settings they are:
    /// touch wake is only on a watch with a touchscreen, and the dynamic
    /// backlight mode is out of the sync whitelist itself on a board built
    /// without it. What each board has is read from its PebbleOS defconfig —
    /// see `WatchBoard.hasTouch` and friends.
    private var shownSettings: [WatchSetting] {
        WatchSetting.allCases.filter { $0.isOffered(on: board) }
    }

    var body: some View {
        Form {
            // First, not last. A setting written to the watch answered below
            // every other setting, where the reader had stopped looking.
            if feedback != nil {
                Section { FeedbackBanner(feedback: feedback) }
            }
            Section {
                ForEach(shownSettings, id: \.self) { setting in
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
            // A Pebble Time 2, which has every conditional row.
            board: .obelixPVT,
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
            // A watch the app cannot place, which hides the conditional rows.
            board: nil,
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

/// The three backlight rows on their own, which is where the shapes differ:
/// a preset picker, a duration picker, and the level as a slider.
#Preview("Backlight rows") {
    Form {
        Section {
            WatchSettingRow(setting: .backlightPreset, rawValue: 3, setRawValue: { _ in })
            WatchSettingRow(setting: .backlightTimeout, rawValue: 8_000, setRawValue: { _ in })
            WatchSettingRow(setting: .backlightIntensity, rawValue: 72, setRawValue: { _ in })
        }
    }
    .formStyle(.grouped)
}
