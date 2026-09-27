public import PebbleProtocol
import Defaults
import Foundation
import SwiftUI

extension AppModel {
    public func loadWatchSettings() {
        // The switches this app stored before settings had types, folded in
        // under the same names. Read first so that anything already written in
        // the new shape wins, and left on disk rather than deleted: a reader
        // who moves back to an older build should still find their switches.
        var stored = Defaults[.watchSettings].mapValues { $0 ? 1 : 0 }
        stored.merge(Defaults[.watchSettingValues]) { _, newer in newer }
        // The disk keys these by the firmware's names; this is the one place
        // that mapping happens, and a name this build does not know is left on
        // disk for the build that does.
        watchSettings.values = Dictionary(
            uniqueKeysWithValues: stored.compactMap { key, value in
                WatchSetting(rawValue: key).map { ($0, value) }
            }
        )
        watchSettings.quickLaunch = Dictionary(
            uniqueKeysWithValues: Defaults[.quickLaunchAssignments].compactMap { key, value in
                QuickLaunchButton(rawValue: key).map { ($0, value) }
            }
        )
        watchSettings.activity = Defaults[.activitySettings]
        watchSettings.heartRate = Defaults[.heartRateSettings]
        watchSettings.heartRateZones = Defaults[.heartRateZonePreferences]
        watchSettings.bloodOxygen = Defaults[.bloodOxygenSettings]
        timeline.isReminderAppEnabled = Defaults[.reminderAppEnabled]
    }

    public func watchSettingValue(_ setting: WatchSetting) -> Int {
        watchSettings.values[setting] ?? setting.defaultRawValue
    }

    public func isWatchSettingOn(_ setting: WatchSetting) -> Bool {
        watchSettingValue(setting) != 0
    }

    public func setWatchSetting(_ setting: WatchSetting, isOn: Bool) async {
        await setWatchSetting(setting, rawValue: isOn ? 1 : 0)
    }

    public func setWatchSetting(_ setting: WatchSetting, rawValue: Int) async {
        // A value this setting cannot hold is not sent. The firmware would
        // ignore it and keep what it had, leaving the screen showing one thing
        // and the watch doing another.
        guard setting.accepts(rawValue: rawValue) else { return }
        // A backlight preset is a name for seven other settings, so choosing
        // one writes all seven as well — see `BacklightPreset`. Without them
        // the write reached the watch and changed nothing anybody could see
        // (#115). Choosing "Custom" writes only the preset, which is the same
        // early return the watch's own `backlight_set_preset` takes.
        //
        // The seven first and the chosen setting last, so that a watch which
        // refuses one of them is not left claiming a preset it does not have.
        let implied = setting == .backlightPreset
            ? BacklightPreset.settings(for: rawValue) ?? [:]
            : [:]
        let changed = implied.map { ($0.key, $0.value) } + [(setting, rawValue)]
        for (setting, rawValue) in changed {
            watchSettings.values[setting] = rawValue
        }
        persistWatchSettingValues()
        watchSettings.feedback = nil
        for connection in activeConnections {
            for (setting, rawValue) in changed {
                do {
                    try await connection.client.write(.watchSetting(setting, rawValue: rawValue))
                } catch {
                    // A watch built without this setting refusing it says
                    // nothing about what the reader did.
                    guard !setting.mayBeAbsent else { continue }
                    watchSettings.feedback = .failure(settingsFailureMessage(connection, error))
                }
            }
        }
    }

    /// A switch flicked on the watch, arriving over the settings database.
    ///
    /// The watch pushes these only to a phone that claimed `settingsSync`,
    /// which this app now does — see `PhoneVersionCodec`. Before that the
    /// toggles here could drift from the watch with nothing to say so.
    ///
    /// Not written back to the watch it came from: it already has the value,
    /// and answering a push with a write is how two watches talk each other
    /// into a loop. Written to every *other* connected watch, because the app's
    /// settings are one set written to all of them — the same shape
    /// `synchronizeNotificationSourceApps` uses for a record from one watch.
    ///
    /// No banner. Nobody on this side asked, so there is no question to answer;
    /// the toggle moving under the reader is the whole of it.
    ///
    /// - Returns: Whether it was a setting this app has, which is what the
    ///   watch is told about its record.
    @discardableResult
    func applyWatchSetting(
        _ setting: WatchSetting,
        rawValue: Int,
        from connection: WatchConnection
    ) async -> Bool {
        guard watchSettings.values[setting] != rawValue else { return true }
        watchSettings.values[setting] = rawValue
        persistWatchSettingValues()
        for other in activeConnections where other !== connection {
            try? await other.client.write(.watchSetting(setting, rawValue: rawValue))
        }
        return true
    }

    public func quickLaunchAssignment(for button: QuickLaunchButton) -> QuickLaunchAssignment {
        watchSettings.quickLaunch[button] ?? .firmwareDefault(for: button)
    }

    public func setQuickLaunch(_ button: QuickLaunchButton, to assignment: QuickLaunchAssignment) async {
        watchSettings.quickLaunch[button] = assignment
        persistQuickLaunchAssignments()
        watchSettings.feedback = nil
        for connection in activeConnections {
            do {
                try await connection.client.write(.quickLaunch(button, assignment))
            } catch {
                watchSettings.feedback = .failure(settingsFailureMessage(connection, error))
            }
        }
    }

    /// A button held down on the wrist to assign whatever was running, pushed
    /// back the way a flicked switch is — see `applyWatchSetting`.
    @discardableResult
    func applyQuickLaunch(
        _ button: QuickLaunchButton,
        assignment: QuickLaunchAssignment,
        from connection: WatchConnection
    ) async -> Bool {
        guard watchSettings.quickLaunch[button] != assignment else { return true }
        watchSettings.quickLaunch[button] = assignment
        persistQuickLaunchAssignments()
        for other in activeConnections where other !== connection {
            try? await other.client.write(.quickLaunch(button, assignment))
        }
        return true
    }

    public func setActivitySettings(_ settings: ActivitySettings) async {
        watchSettings.activity = settings
        Defaults[.activitySettings] = settings
        watchSettings.feedback = nil
        for connection in activeConnections {
            do {
                try await connection.client.write(.activitySettings(settings))
            } catch {
                watchSettings.feedback = .failure(settingsFailureMessage(connection, error))
            }
        }
    }

    public func setHeartRateZones(_ preferences: HeartRateZonePreferences) async {
        // The firmware's handler refuses a disordered record and resets to its
        // defaults, so a slip of the stepper must not be allowed to wipe the
        // reader's other five numbers.
        guard preferences.isValid else { return }
        watchSettings.heartRateZones = preferences
        Defaults[.heartRateZonePreferences] = preferences
        watchSettings.feedback = nil
        for connection in activeConnections {
            do {
                try await connection.client.write(.heartRateZones(preferences))
            } catch {
                watchSettings.feedback = .failure(settingsFailureMessage(connection, error))
            }
        }
    }

    public func setHeartRateSettings(_ settings: HeartRateSettings) async {
        watchSettings.heartRate = settings
        Defaults[.heartRateSettings] = settings
        watchSettings.feedback = nil
        for connection in activeConnections {
            do {
                try await connection.client.write(.heartRateSettings(settings))
            } catch {
                watchSettings.feedback = .failure(settingsFailureMessage(connection, error))
            }
        }
    }

    public func setBloodOxygenSettings(_ settings: BloodOxygenSettings) async {
        watchSettings.bloodOxygen = settings
        Defaults[.bloodOxygenSettings] = settings
        watchSettings.feedback = nil
        for connection in activeConnections {
            do {
                try await connection.client.write(.bloodOxygenSettings(settings))
            } catch {
                watchSettings.feedback = .failure(settingsFailureMessage(connection, error))
            }
        }
    }

    public func setReminderAppEnabled(_ isEnabled: Bool) async {
        timeline.isReminderAppEnabled = isEnabled
        Defaults[.reminderAppEnabled] = isEnabled
        watchSettings.feedback = nil
        for connection in activeConnections {
            do {
                try await connection.client.write(.reminderAppState(isEnabled ? .enabled : .notEnabled))
            } catch {
                // Said out loud like the three switches beside it. This one used
                // to swallow the refusal, so the toggle stayed where the reader
                // put it and the watch's Reminders app did not.
                watchSettings.feedback = .failure(settingsFailureMessage(connection, error))
            }
        }
    }

    // A watch too old to have the settings database refuses those writes and
    // keeps the rest, so each group is sent on its own.
    func synchronizeWatchSettings(on connection: WatchConnection) async {
        guard connection.isConnected, !connection.watch.isRunningRecoveryFirmware else { return }
        for setting in WatchSetting.allCases {
            try? await connection.client.write(
                .watchSetting(setting, rawValue: watchSettingValue(setting))
            )
        }
        // Only the buttons the reader has set. Writing the firmware default to
        // the rest would be harmless today, but a default written is a default
        // this app now owns, and it has no reason to own what nobody touched.
        for (button, assignment) in watchSettings.quickLaunch {
            try? await connection.client.write(.quickLaunch(button, assignment))
        }
        try? await connection.client.write(.activitySettings(watchSettings.activity))
        try? await connection.client.write(.heartRateSettings(watchSettings.heartRate))
        try? await connection.client.write(.heartRateZones(watchSettings.heartRateZones))
        try? await connection.client.write(.bloodOxygenSettings(watchSettings.bloodOxygen))
        try? await connection.client.write(
            .reminderAppState(timeline.isReminderAppEnabled ? .enabled : .notEnabled)
        )
        await sendHealthDays(to: connection)
    }

    func sendHealthDays(to connection: WatchConnection) async {
        guard connection.isConnected else { return }
        let days = healthDays()
        for day in days {
            do {
                try await connection.client.write(.healthDay(day))
            } catch {
                await DiagnosticLog.shared.record(
                    .error,
                    category: "health",
                    message: "\(connection.watch.name) rejected a day: \(String(reflecting: error))"
                )
                return
            }
        }
        // The month against today, and what this weekday usually looks like.
        // Sent beside the days because the watch's own Health screens compare
        // against these, and without them every day reads as unprecedented.
        if let averages = Self.thirtyDayAverages(of: health.samples) {
            try? await connection.client.write(
                .healthAverages(steps: averages.steps, sleepSeconds: averages.sleepSeconds)
            )
        }
        guard !days.isEmpty else { return }
        // Which fields were filled, not what was in them: four of the six come
        // from Apple Health and are zero until the reader allows it, and a week
        // of zeroes on the watch looks the same as a week that never arrived.
        let measured = [
            days.contains { $0.steps > 0 } ? "steps" : nil,
            days.contains { $0.sleepSeconds > 0 } ? "sleep" : nil,
            days.contains { $0.activeKilocalories + $0.restingKilocalories > 0 } ? "energy" : nil,
            days.contains { $0.distanceMetres > 0 } ? "distance" : nil,
            days.contains { $0.activeSeconds > 0 } ? "exercise" : nil,
        ].compactMap { $0 }
        await DiagnosticLog.shared.record(
            category: "health",
            message: "\(connection.watch.name) took \(days.count) day(s) of "
                + (measured.isEmpty ? "nothing but zeroes" : measured.joined(separator: ", "))
        )
    }

    // The firmware writes a day's record straight over its own metrics for that
    // day, so today is never sent — it is still being counted — and a day the
    // phone knows nothing about is left alone.
    func healthDays(now: Date = .now) -> [WatchHealthDay] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard let oldest = calendar.date(byAdding: .day, value: -6, to: startOfToday) else {
            return []
        }
        return health.samples.compactMap { sample in
            let day = calendar.startOfDay(for: sample.date)
            guard day >= oldest, day < startOfToday else { return nil }
            // A day is worth writing if the phone knows something the watch
            // does not. `source` alone cannot say so any more: a day the watch
            // synced after Apple Health was read is one record marked `watch`
            // that carries the energy and distance the watch never counted, and
            // skipping it left those four fields at zero on a watch that could
            // have had them.
            let phoneOnly = sample.activeKilocalories + sample.restingKilocalories
                + sample.distanceMetres + sample.activeMinutes
            guard sample.source != .watch || phoneOnly > 0 else { return nil }
            guard let weekday = calendar.dateComponents([.weekday], from: day).weekday else {
                return nil
            }
            let typical = Self.typicalSleep(onWeekday: weekday - 1, of: health.samples, before: startOfToday)
            return WatchHealthDay(
                // `weekday` counts from 1 for Sunday; the firmware counts from 0.
                weekday: weekday - 1,
                lastProcessed: day,
                steps: UInt32(clamping: sample.steps),
                // Measured or nothing. A day Apple Health has no reading for
                // stays at zero rather than being worked out from the steps:
                // the watch shows what it was told, and an estimate shown as a
                // count is a lie the reader cannot see.
                activeKilocalories: UInt32(clamping: sample.activeKilocalories),
                restingKilocalories: UInt32(clamping: sample.restingKilocalories),
                distanceMetres: UInt32(clamping: sample.distanceMetres),
                activeSeconds: UInt32(clamping: sample.activeMinutes * 60),
                sleepSeconds: UInt32(clamping: sample.sleepMinutes * 60),
                deepSleepSeconds: UInt32(clamping: sample.deepSleepMinutes * 60),
                typicalSleepSeconds: typical?.sleep,
                typicalDeepSleepSeconds: typical?.deep
            )
        }
    }

    /// The disk keeps the firmware's names, so a build that gains or loses a
    /// setting still reads the same file — the mirror of `loadWatchSettings`.
    private func persistWatchSettingValues() {
        Defaults[.watchSettingValues] = Dictionary(
            uniqueKeysWithValues: watchSettings.values.map { ($0.key.rawValue, $0.value) }
        )
    }

    private func persistQuickLaunchAssignments() {
        Defaults[.quickLaunchAssignments] = Dictionary(
            uniqueKeysWithValues: watchSettings.quickLaunch.map { ($0.key.rawValue, $0.value) }
        )
    }

    private func settingsFailureMessage(
        _ connection: WatchConnection,
        _ error: any Error
    ) -> LocalizedStringKey {
        "\(connection.watch.name) did not accept the setting. \(Text(refusalReason(for: error)))"
    }
}

extension AppModel {
    /// Nil where there is no history at all, rather than an average of zero:
    /// half a comparison is worse than none.
    static func thirtyDayAverages(
        of samples: [WatchHealthSample],
        now: Date = .now
    ) -> (steps: UInt32, sleepSeconds: UInt32)? {
        let averages = samples.averages(over: 30, endingBefore: now)
        guard !averages.isEmpty else { return nil }
        return (UInt32(clamping: averages.steps), UInt32(clamping: averages.sleepMinutes * 60))
    }

    /// What this weekday usually looks like: the median over the past four
    /// weeks' worth of that weekday, not the mean — one sleepless deadline
    /// night should not move what "usual" means.
    ///
    /// `weekday` counts from 0 for Sunday, the way the firmware counts.
    static func typicalSleep(
        onWeekday weekday: Int,
        of samples: [WatchHealthSample],
        before startOfToday: Date
    ) -> (sleep: UInt32, deep: UInt32)? {
        let calendar = Calendar.current
        guard let oldest = calendar.date(byAdding: .day, value: -28, to: startOfToday) else {
            return nil
        }
        let days = samples.filter { sample in
            sample.date >= oldest && sample.date < startOfToday
                && sample.sleepMinutes > 0
                && calendar.dateComponents([.weekday], from: sample.date).weekday == weekday + 1
        }
        guard !days.isEmpty else { return nil }
        func median(_ values: [Int]) -> Int {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return (
            sleep: UInt32(clamping: median(days.map { $0.sleepMinutes * 60 })),
            deep: UInt32(clamping: median(days.map { $0.deepSleepMinutes * 60 }))
        )
    }
}
