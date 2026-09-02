public import PebbleProtocol
import Defaults
import Foundation
import SwiftUI

extension AppModel {
    public func loadWatchSettings() {
        watchSettings = Defaults[.watchSettings]
        activitySettings = Defaults[.activitySettings]
        heartRateSettings = Defaults[.heartRateSettings]
        isReminderAppEnabled = Defaults[.reminderAppEnabled]
    }

    public func isWatchSettingOn(_ setting: WatchSetting) -> Bool {
        watchSettings[setting.rawValue] ?? setting.defaultValue
    }

    public func setWatchSetting(_ setting: WatchSetting, isOn: Bool) async {
        watchSettings[setting.rawValue] = isOn
        Defaults[.watchSettings] = watchSettings
        for connection in activeConnections {
            do {
                try await connection.client.writeWatchSetting(setting, isOn: isOn)
            } catch {
                watchSettingsStatusMessage = settingsFailureMessage(connection, error)
            }
        }
    }

    public func setActivitySettings(_ settings: PebbleActivitySettings) async {
        activitySettings = settings
        Defaults[.activitySettings] = settings
        for connection in activeConnections {
            do {
                try await connection.client.writeActivitySettings(settings)
            } catch {
                watchSettingsStatusMessage = settingsFailureMessage(connection, error)
            }
        }
    }

    public func setHeartRateSettings(_ settings: PebbleHeartRateSettings) async {
        heartRateSettings = settings
        Defaults[.heartRateSettings] = settings
        for connection in activeConnections {
            do {
                try await connection.client.writeHeartRateSettings(settings)
            } catch {
                watchSettingsStatusMessage = settingsFailureMessage(connection, error)
            }
        }
    }

    public func setReminderAppEnabled(_ isEnabled: Bool) async {
        isReminderAppEnabled = isEnabled
        Defaults[.reminderAppEnabled] = isEnabled
        for connection in activeConnections {
            try? await connection.client.writeReminderAppState(isEnabled ? .enabled : .notEnabled)
        }
    }

    // A watch too old to have the settings database refuses those writes and
    // keeps the rest, so each group is sent on its own.
    func synchronizeWatchSettings(on connection: WatchConnection) async {
        guard connection.isConnected, !connection.device.isRunningRecoveryFirmware else { return }
        for setting in WatchSetting.allCases {
            try? await connection.client.writeWatchSetting(setting, isOn: isWatchSettingOn(setting))
        }
        try? await connection.client.writeActivitySettings(activitySettings)
        try? await connection.client.writeHeartRateSettings(heartRateSettings)
        try? await connection.client.writeReminderAppState(
            isReminderAppEnabled ? .enabled : .notEnabled
        )
        await sendHealthDays(to: connection)
    }

    func sendHealthDays(to connection: WatchConnection) async {
        guard connection.isConnected else { return }
        for day in healthDays() {
            do {
                try await connection.client.writeHealthDay(day)
            } catch {
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "health",
                    message: "\(connection.device.name) rejected a day: \(String(reflecting: error))"
                )
                return
            }
        }
    }

    // The firmware writes a day's record straight over its own metrics for that
    // day, so today is never sent and a day the phone knows nothing about is
    // left alone.
    func healthDays(now: Date = .now) -> [PebbleHealthDay] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard let oldest = calendar.date(byAdding: .day, value: -6, to: startOfToday) else {
            return []
        }
        return healthSamples.compactMap { sample in
            let day = calendar.startOfDay(for: sample.date)
            guard sample.source != .watch, day >= oldest, day < startOfToday else { return nil }
            guard let weekday = calendar.dateComponents([.weekday], from: day).weekday else {
                return nil
            }
            return PebbleHealthDay(
                // `weekday` counts from 1 for Sunday; the firmware counts from 0.
                weekday: weekday - 1,
                lastProcessed: day,
                steps: UInt32(clamping: sample.steps),
                // Left at zero rather than guessed: the watch shows what it was told.
                activeKilocalories: 0,
                restingKilocalories: 0,
                distanceMetres: 0,
                activeSeconds: 0,
                sleepSeconds: UInt32(clamping: sample.sleepMinutes * 60),
                deepSleepSeconds: UInt32(clamping: sample.deepSleepMinutes * 60)
            )
        }
    }

    private func settingsFailureMessage(
        _ connection: WatchConnection,
        _ error: any Error
    ) -> LocalizedStringKey {
        "\(connection.device.name) did not accept the setting. \(error.localizedDescription)"
    }
}
