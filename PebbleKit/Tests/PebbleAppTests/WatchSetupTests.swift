import Testing
@testable import PebbleApp

/// Which screens a watch's first connection puts in front of the reader.
@Suite
struct WatchSetupTests {
    @Test
    func aWatchWithFirmwareIsWelcomedAndThenAsksForEverything() {
        let steps = WatchSetupStep.steps(
            isRunningRecoveryFirmware: false,
            permissions: PhonePermissions()
        )

        #expect(steps.first == .welcome)
        #expect(steps.last == .finished)
        #expect(!steps.contains(.firmware))
        // One screen per permission, in the order they are asked.
        #expect(steps.dropFirst().dropLast() == PhonePermissionKind.asked.map { .permission($0) })
    }

    @Test
    func firmwareComesBeforeAnyPermission() throws {
        let steps = WatchSetupStep.steps(
            isRunningRecoveryFirmware: true,
            permissions: PhonePermissions()
        )

        // Nothing a permission unlocks reaches a watch in its recovery firmware.
        let firmware = try #require(steps.firstIndex(of: .firmware))
        let firstPermission = try #require(steps.firstIndex(of: .permission(PhonePermissionKind.asked[0])))
        #expect(firmware < firstPermission)
        #expect(steps[1] == .firmware)
    }

    @Test
    func whatIsAlreadyAllowedIsNotAskedForAgain() {
        let steps = WatchSetupStep.steps(
            isRunningRecoveryFirmware: false,
            permissions: PhonePermissions(
                calendar: .allowed,
                reminders: .notDetermined,
                location: .allowed,
                health: .allowed
            )
        )

        #expect(steps == [.welcome, .permission(.reminders), .finished])
    }

    @Test
    func aWriteOnlyCalendarIsAskedForAgain() {
        // Events are read to make pins of them, so permission to add one is not
        // the permission this app needs.
        #expect(PhonePermissionKind.calendar.isWorthAsking(in: PhonePermissions(calendar: .partly)))
    }

    @Test
    func nothingIsAskedWhenNoAnswerCouldChangeIt() {
        #expect(!PhonePermissionKind.health.isWorthAsking(in: PhonePermissions(health: .unavailable)))
        #expect(!PhonePermissionKind.location.isWorthAsking(in: PhonePermissions(location: .restricted)))
        // A refusal is still shown: that screen offers the privacy settings,
        // which is the only place it can be taken back.
        #expect(PhonePermissionKind.calendar.isWorthAsking(in: PhonePermissions(calendar: .denied)))
    }

    @Test
    func healthIsOnlyAskedForWhereHealthExists() {
        #if os(iOS)
        #expect(PhonePermissionKind.asked.contains(.health))
        #else
        #expect(!PhonePermissionKind.asked.contains(.health))
        #endif
        // Bluetooth is never asked for here: a watch cannot have connected
        // without it, so it is not one of these kinds at all.
        #expect(Set(PhonePermissionKind.asked).isSubset(of: Set(PhonePermissionKind.allCases)))
    }
}
