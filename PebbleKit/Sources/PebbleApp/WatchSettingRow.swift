import PebbleProtocol
import SwiftUI

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
    /// The rows that belong on the Backlight screen.
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
