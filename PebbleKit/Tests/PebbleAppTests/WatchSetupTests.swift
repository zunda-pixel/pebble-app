import Testing
@testable import PebbleApp

/// Which screens a watch's first connection puts in front of the reader, and
/// which permissions get a switch on the one that asks for them.
@Suite
struct WatchSetupTests {
    @Test
    func aWatchWithFirmwareIsWelcomedAndThenAsksForPermissions() {
        let steps = WatchSetupStep.steps(
            isRunningRecoveryFirmware: false,
            permissions: PhonePermissions()
        )

        #expect(steps == [.welcome, .permissions, .finished])
    }

    @Test
    func firmwareComesBeforeThePermissions() throws {
        let steps = WatchSetupStep.steps(
            isRunningRecoveryFirmware: true,
            permissions: PhonePermissions()
        )

        // Nothing a permission unlocks reaches a watch in its recovery firmware.
        #expect(steps == [.welcome, .firmware, .permissions, .finished])
    }

    @Test
    func thePermissionScreenIsSkippedWhenThereIsNothingLeftToAsk() {
        let steps = WatchSetupStep.steps(
            isRunningRecoveryFirmware: false,
            permissions: PhonePermissions(
                calendar: .allowed,
                reminders: .allowed,
                location: .allowed,
                health: .allowed
            )
        )

        #expect(steps == [.welcome, .finished])
    }

    @Test
    func everySwitchThisPhoneCanAnswerIsShownEvenWhenItIsAlreadyOn() {
        // One screen, so what is granted is shown beside what is not rather
        // than left out: the row is the answer as much as the question.
        let permissions = PhonePermissions(calendar: .allowed, reminders: .notDetermined)

        #expect(PhonePermissionKind.calendar.isListed(in: permissions))
        #expect(PhonePermissionKind.reminders.isListed(in: permissions))
    }

    @Test
    func aWriteOnlyCalendarIsAskedForAgain() {
        // Events are read to make pins of them, so permission to add one is not
        // the permission this app needs.
        #expect(PhonePermissionKind.calendar.isWorthAsking(in: PhonePermissions(calendar: .partly)))
    }

    @Test
    func nothingIsShownWhenNoAnswerCouldChangeIt() {
        #expect(!PhonePermissionKind.health.isListed(in: PhonePermissions(health: .unavailable)))
        #expect(!PhonePermissionKind.location.isListed(in: PhonePermissions(location: .restricted)))
        // A refusal keeps its row: that row offers the privacy settings, which
        // is the only place it can be taken back.
        #expect(PhonePermissionKind.calendar.isListed(in: PhonePermissions(calendar: .denied)))
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
