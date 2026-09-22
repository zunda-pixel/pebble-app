import PebbleProtocol
import SwiftUI

struct WatchSettingsView: View {
    var model: AppModel
    var watchID: WatchID

    private var connection: WatchConnection? {
        model.connections.first { $0.watch.id == watchID }
    }

    /// The connected watch's board, or the remembered one while it is away.
    /// Nil for a watch neither knows, which hides the rows only some boards
    /// have.
    private var board: WatchBoard? {
        WatchSummary(watchID: watchID, model: model).board
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
            quickLaunchAssignments: { model.quickLaunchAssignment(for: $0) },
            applications: model.applications.apps + model.applications.watchfaces,
            activitySettings: model.watchSettings.activity,
            heartRateSettings: model.watchSettings.heartRate,
            heartRateZones: model.watchSettings.heartRateZones,
            bloodOxygenSettings: model.watchSettings.bloodOxygen,
            isReminderAppEnabled: model.timeline.isReminderAppEnabled,
            isConnected: connection?.isConnected == true,
            feedback: model.watchSettings.feedback,
            setWatchSetting: { setting, rawValue in
                Task { await model.setWatchSetting(setting, rawValue: rawValue) }
            },
            setQuickLaunch: { button, assignment in
                Task { await model.setQuickLaunch(button, to: assignment) }
            },
            setHeartRateZones: { preferences in
                Task { await model.setHeartRateZones(preferences) }
            },
            setActivitySettings: { settings in
                Task { await model.setActivitySettings(settings) }
            },
            setHeartRateSettings: { settings in
                Task { await model.setHeartRateSettings(settings) }
            },
            setBloodOxygenSettings: { settings in
                Task { await model.setBloodOxygenSettings(settings) }
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

    /// A colour mid-pick. The picker has no "the drag ended" callback the way
    /// the slider does, so this is written after a quiet moment instead — see
    /// the `.task(id:)` on the row.
    @State private var colorDraft: Int?

    /// For reading a picked `Color` back as sRGB numbers.
    @Environment(\.self) private var environment

    private func commitDraft() {
        guard let draft else { return }
        setRawValue(draft)
        self.draft = nil
    }

    /// One end of a schedule as a `Date` today, for a `DatePicker` that only
    /// shows the clock. Only the hour and minute survive the trip back. Key
    /// paths rather than closures, so hour and minute cannot be swapped at a
    /// call site without the compiler noticing.
    private func scheduleTimeBinding(
        _ schedule: QuietTimeSchedule,
        hour hourPath: WritableKeyPath<QuietTimeSchedule, Int>,
        minute minutePath: WritableKeyPath<QuietTimeSchedule, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: schedule[keyPath: hourPath],
                    minute: schedule[keyPath: minutePath],
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                var changed = schedule
                changed[keyPath: hourPath] = components.hour ?? 0
                changed[keyPath: minutePath] = components.minute ?? 0
                setRawValue(changed.rawValue)
            }
        )
    }

    var body: some View {
        switch setting.kind {
        case .boolean:
            Toggle(setting.title, isOn: Binding(
                get: { rawValue != 0 },
                set: { setRawValue($0 ? 1 : 0) }
            ))
        case .choice, .duration:
            // A closure literal rather than the function value: formed here it
            // is isolated to the view's actor, which is what the binding's
            // @isolated(any) setter wants; the bare reference is a non-Sendable
            // function value and warns.
            Picker(setting.title, selection: Binding(get: { rawValue }, set: { setRawValue($0) })) {
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
        case .schedule:
            // Two clock rows rather than one row of four numbers: the value is
            // a daily time range, and a reader thinks in clock times.
            let schedule = QuietTimeSchedule(rawValue: rawValue)
            DatePicker(
                "Start",
                selection: scheduleTimeBinding(schedule, hour: \.fromHour, minute: \.fromMinute),
                displayedComponents: .hourAndMinute
            )
            DatePicker(
                "End",
                selection: scheduleTimeBinding(schedule, hour: \.toHour, minute: \.toMinute),
                displayedComponents: .hourAndMinute
            )
        case .color:
            ColorPicker(
                setting.title,
                selection: Binding(
                    get: { Color(packedRGB: colorDraft ?? rawValue) },
                    set: { colorDraft = $0.packedRGB(in: environment) }
                ),
                supportsOpacity: false
            )
            // A drag around the colour wheel is a stream of values and each
            // write goes to the watch, so the write waits for a quiet moment.
            // `task(id:)` cancels the sleeping task whenever the draft moves
            // again, which is the debounce.
            .task(id: colorDraft) {
                guard let colorDraft else { return }
                guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
                setRawValue(colorDraft)
                self.colorDraft = nil
            }
        }
    }
}

extension WatchSetting {
    /// The rows that belong on the Backlight screen rather than the main list.
    var isBacklight: Bool {
        switch self {
        case .backlight, .backlightAmbientSensor, .backlightMotion, .backlightPreset,
             .backlightTimeout, .backlightIntensity, .backlightTouchWake, .backlightDynamicMode,
             .backlightColor:
            true
        default:
            false
        }
    }

    /// The rows that belong on the Quiet Time screen.
    var isQuietTime: Bool {
        switch self {
        case .quietTimeManual, .quietTimeSmart, .quietTimeAutoDismiss,
             .quietTimeWeekdayScheduleEnabled, .quietTimeWeekendScheduleEnabled,
             .quietTimeWeekdaySchedule, .quietTimeWeekendSchedule:
            true
        default:
            false
        }
    }
}

struct WatchSettingsContent: View {
    var watchSettings: [WatchSetting: Int]
    var board: WatchBoard?
    var quickLaunchAssignments: (QuickLaunchButton) -> QuickLaunchAssignment = { .firmwareDefault(for: $0) }
    var applications: [WatchApplication] = []
    var activitySettings: ActivitySettings
    var heartRateSettings: HeartRateSettings
    var heartRateZones: HeartRateZonePreferences = HeartRateZonePreferences()
    var bloodOxygenSettings: BloodOxygenSettings = BloodOxygenSettings()
    var isReminderAppEnabled: Bool
    var isConnected: Bool
    var feedback: FeatureFeedback?
    var setWatchSetting: (WatchSetting, Int) -> Void
    var setQuickLaunch: (QuickLaunchButton, QuickLaunchAssignment) -> Void = { _, _ in }
    var setHeartRateZones: (HeartRateZonePreferences) -> Void = { _ in }
    var setActivitySettings: (ActivitySettings) -> Void
    var setHeartRateSettings: (HeartRateSettings) -> Void
    var setBloodOxygenSettings: (BloodOxygenSettings) -> Void = { _ in }
    var setReminderAppEnabled: (Bool) -> Void

    /// The main list, grouped by what a setting is about rather than listed in
    /// declaration order. Static and spelled out, so `WatchSettingGroupingTests`
    /// can hold that every setting is either here or on the Backlight screen —
    /// a new case added to `WatchSetting` fails a test instead of silently
    /// getting no row.
    static let appearanceSettings: [WatchSetting] = [.clock24Hour, .timelineQuickView, .textSize]
    static let unitSettings: [WatchSetting] = [.unitsDistance, .unitsWind]
    static let musicSettings: [WatchSetting] = [
        .musicShowVolumeControls, .musicShowProgressBar, .musicShowAlbumArt,
    ]
    /// The ones that are about nothing in particular, in the untitled section
    /// with the Backlight, Quiet Time and Quick Launch links.
    static let generalSettings: [WatchSetting] = [.standbyMode, .menuScrollWrapAround]

    private func rows(_ settings: [WatchSetting]) -> some View {
        ForEach(settings.filter { $0.isOffered(on: board) }, id: \.self) { setting in
            WatchSettingRow(
                setting: setting,
                rawValue: watchSettings[setting] ?? setting.defaultRawValue,
                setRawValue: { setWatchSetting(setting, $0) }
            )
        }
    }

    /// What the one backlight row says at a glance: "Off" when the backlight
    /// is off, the preset's name otherwise — the same summary the watch's own
    /// Display screen puts under its Backlight row (`display.c:666`).
    private var backlightSummary: LocalizedStringKey {
        guard watchSettings[.backlight] ?? WatchSetting.backlight.defaultRawValue != 0 else {
            return "Off"
        }
        let preset = watchSettings[.backlightPreset]
            ?? WatchSetting.backlightPreset.defaultRawValue
        return WatchSetting.backlightPreset.optionTitles.indices.contains(preset)
            ? WatchSetting.backlightPreset.optionTitles[preset]
            : "Custom"
    }

    /// "On" while switched on by hand, "Scheduled" while only a schedule or
    /// the calendar could turn it on, "Off" otherwise.
    private var quietTimeSummary: LocalizedStringKey {
        func isOn(_ setting: WatchSetting) -> Bool {
            (watchSettings[setting] ?? setting.defaultRawValue) != 0
        }
        if isOn(.quietTimeManual) { return "On" }
        if isOn(.quietTimeSmart) || isOn(.quietTimeWeekdayScheduleEnabled)
            || isOn(.quietTimeWeekendScheduleEnabled) {
            return "Scheduled"
        }
        return "Off"
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
            Section("Music") {
                rows(Self.musicSettings)
            }
            Section {
                rows(Self.generalSettings)
                NavigationLink {
                    BacklightSettingsContent(
                        watchSettings: watchSettings,
                        board: board,
                        feedback: feedback,
                        setWatchSetting: setWatchSetting
                    )
                } label: {
                    LabeledContent("Backlight") { Text(backlightSummary) }
                }
                NavigationLink {
                    QuietTimeSettingsContent(
                        watchSettings: watchSettings,
                        feedback: feedback,
                        setWatchSetting: setWatchSetting
                    )
                } label: {
                    LabeledContent("Quiet Time") { Text(quietTimeSummary) }
                }
                NavigationLink {
                    QuickLaunchSettingsContent(
                        assignments: quickLaunchAssignments,
                        applications: applications,
                        feedback: feedback,
                        setAssignment: setQuickLaunch
                    )
                } label: {
                    Text("Quick Launch")
                }
            } footer: {
                // On the last of the four, but it speaks for all of them.
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

#Preview("Blood oxygen on") {
    NavigationStack {
        WatchSettingsContent(
            watchSettings: [:],
            board: .obelixPVT,
            activitySettings: ActivitySettings(),
            heartRateSettings: HeartRateSettings(),
            bloodOxygenSettings: BloodOxygenSettings(
                isEnabled: true,
                interval: .everyThirtyMinutes,
                isEnabledDuringActivity: true
            ),
            isReminderAppEnabled: true,
            isConnected: true,
            feedback: nil,
            setWatchSetting: { _, _ in },
            setActivitySettings: { _ in },
            setHeartRateSettings: { _ in },
            setBloodOxygenSettings: { _ in },
            setReminderAppEnabled: { _ in }
        )
    }
}

/// The backlight screen for a Pebble Time 2, which has every row: the enable
/// switch and the preset above, six individual values below — a duration
/// picker and the level as a slider among them.
