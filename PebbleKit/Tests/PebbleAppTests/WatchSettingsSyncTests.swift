import PebbleProtocol
@testable import PebbleTransport
import Defaults
import Foundation
import Testing
@testable import PebbleApp

/// A setting changed on the watch, coming back to the phone.
///
/// It never used to. The firmware pushes its settings database only to a phone
/// that claims `settings_sync_support` — bit 23, read by
/// `settings_blob_db_phone_supports_sync` in PebbleOS's
/// `src/fw/services/blob_db/settings_blob_db.c` — and this app claimed
/// everything up to bit 15 and stopped. So the toggles on the settings screen
/// could drift from the watch with nothing to say so, and the comment on
/// `WatchSettingsCodec` had the direction of the bit backwards, which is how it
/// went unnoticed (#87).
@Suite
@MainActor
struct WatchSettingsSyncTests {
    /// The record the firmware sends: the key with its terminator, one byte of
    /// value, in the frame shape `BlobDB2Codec` decodes.
    private func pushed(key: String, value: [UInt8]) -> PebbleProtocolFrame {
        let keyBytes = Array(key.utf8) + [0]
        var payload: [UInt8] = [0x08, 0x0C, 0x00, WatchSettingsCodec.databaseID, 0, 0, 0, 0]
        payload += [UInt8(keyBytes.count)]
        payload += keyBytes
        payload += [UInt8(value.count & 0xFF), UInt8(value.count >> 8)]
        payload += value
        return PebbleProtocolFrame(endpoint: BlobDB2Codec.endpoint, payload: payload)
    }

    private func makeModel(directory: URL, client: MockWatchClient) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
    }

    /// The phone has to say it will take them, or the watch never sends any.
    @Test func thePhoneClaimsTheSettingsSyncCapability() {
        #expect(PhoneVersionCodec.supportedCapabilities.contains(.settingsSync))
        #expect(PhoneCapability.settingsSync.rawValue == 23)

        // Bit 23 is the last byte-and-a-bit of the eight-byte field: byte two,
        // top bit. Checked on the frame rather than on the set, because the
        // watch reads the bytes.
        let frame = PhoneVersionCodec.responseFrame(operatingSystem: .iOS)
        let capabilities = Array(frame.payload.suffix(8))
        #expect(capabilities[2] & (1 << 7) != 0)
    }

    /// What the watch says lands here, and goes on to the other watch.
    ///
    /// Not back to the one that sent it — it already has the value, and
    /// answering a push with a write is how two devices talk each other into a
    /// loop. To the other one because this app keeps one set of settings and
    /// writes it to every watch, which is the shape the notification-app
    /// database already had for a record arriving from one of them.
    @Test func aSettingChangedOnTheWatchReachesThePhoneAndTheOtherWatch() async throws {
        let scanner = MockWatchClient()
        var clients: [WatchID: MockWatchClient] = [:]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: scanner,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { watchID in
                let client = MockWatchClient()
                clients[watchID] = client
                return client
            }
        )
        await model.scan()
        let devices = model.discoveredWatches
        let first = try #require(devices.first)
        let second = try #require(devices.dropFirst().first)
        await model.connect(to: first)
        await model.connect(to: second)

        // On connect both watches were given the app's current value, so the
        // mock's record starts at `wasOn` for each and the assertions below can
        // tell a fresh write from that one without clearing anything.
        let wasOn = model.isWatchSettingOn(.clock24Hour)
        let source = try #require(model.connections.first { $0.watch.id == first.id })

        await model.handleWatchDatabaseWrite(
            pushed(key: WatchSetting.clock24Hour.rawValue, value: [wasOn ? 0 : 1]),
            on: source
        )

        #expect(model.isWatchSettingOn(.clock24Hour) == !wasOn)
        #expect(Defaults[.watchSettingValues][WatchSetting.clock24Hour.rawValue] == (wasOn ? 0 : 1))
        // The other watch is told.
        #expect(clients[second.id]?.writtenWatchSettings[.clock24Hour] == (wasOn ? 0 : 1))
        // The one that told us is not written back to.
        #expect(clients[first.id]?.writtenWatchSettings[.clock24Hour] == (wasOn ? 1 : 0))
    }

    /// A key this app has no switch for.
    ///
    /// Most of them: the firmware's two whitelists run to some seventy keys and
    /// nine of them are this app's. It is taken rather than refused, because
    /// the phone has nowhere to put it and cannot acquire one by saying no —
    /// and because what a refused sync record makes the watch do next was never
    /// measured. Nothing on this side changes.
    @Test func aSettingThisAppDoesNotHaveIsTakenAndChangesNothing() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        let connection = try #require(model.activeConnections.first)
        let before = model.watchSettings.values

        // A real key from `s_syncable_settings` that this app has no switch for.
        await model.handleWatchDatabaseWrite(
            pushed(key: "lightTimeoutMs", value: [0x10, 0x27]),
            on: connection
        )

        #expect(model.watchSettings.values == before)
    }

    /// The record is read, and only when it is a switch.
    @Test func aRecordIsOnlyReadWhenItIsOneByteUnderAKnownName() {
        let key = WatchSettingsCodec.key(for: .backlight)

        #expect(WatchSettingsCodec.decodeRecord(key: key, value: [1])?.0 == .backlight)
        #expect(WatchSettingsCodec.decodeRecord(key: key, value: [1])?.1 == 1)
        #expect(WatchSettingsCodec.decodeRecord(key: key, value: [0])?.1 == 0)
        // The firmware accepts the name either way from the phone and sends it
        // either way back.
        #expect(WatchSettingsCodec.decodeRecord(key: Array("lightEnabled".utf8), value: [1])?.0 == .backlight)
        // Not a switch: `lightTimeoutMs` is a number, and reading its first
        // byte as a boolean would turn 10000 ms into "on".
        #expect(WatchSettingsCodec.decodeRecord(key: Array("lightEnabled".utf8), value: [0x10, 0x27]) == nil)
        #expect(WatchSettingsCodec.decodeRecord(key: Array("lightTimeoutMs".utf8), value: [1]) == nil)
    }
}

/// Settings that are not switches.
///
/// The nine this app started with are all booleans, and everything from the
/// stored preference to the BlobDB record assumed so. The firmware's list is
/// some seventy keys and several are one-byte choices — the distance unit, the
/// wind unit, the text size — with their values numbered in `prefs.c` (#93).
@Suite
@MainActor
struct WatchSettingChoiceTests {
    private func makeModel(directory: URL, client: MockWatchClient) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
    }

    /// One byte, the number the firmware keeps.
    @Test func aChoiceIsSentAsItsNumber() throws {
        let frame = WatchSettingsCodec.insertFrame(.textSize, rawValue: 3, token: 1)

        // The value is the last byte of the record, after the key.
        #expect(frame.payload.last == 3)
    }

    /// `PreferredContentSize` runs 0...3, and `system_theme_set_content_size`
    /// ignores anything past the end — so sending it would leave the screen
    /// saying one thing and the watch doing another.
    @Test func aValueTheSettingCannotHoldIsNotSent() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))

        // Connecting wrote every setting once, so the mock's record starts at
        // the default and a refused write is one that leaves it there.
        await model.setWatchSetting(.textSize, rawValue: 9)

        #expect(client.writtenWatchSettings[.textSize] == WatchSetting.textSize.defaultRawValue)
        #expect(model.watchSettingValue(.textSize) == WatchSetting.textSize.defaultRawValue)
    }

    @Test func aValueTheSettingCanHoldIsSentAndKept() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))

        await model.setWatchSetting(.unitsDistance, rawValue: 0)

        #expect(client.writtenWatchSettings[.unitsDistance] == 0)
        #expect(model.watchSettingValue(.unitsDistance) == 0)
    }

    /// A choice arriving from the watch, read as its number rather than as
    /// "non-zero".
    @Test func aChoiceComingBackFromTheWatchKeepsItsNumber() {
        let key = WatchSettingsCodec.key(for: .textSize)

        #expect(WatchSettingsCodec.decodeRecord(key: key, value: [2])?.1 == 2)
        // A switch is still non-zero-or-not, the way C reads one.
        #expect(
            WatchSettingsCodec.decodeRecord(key: WatchSettingsCodec.key(for: .backlight), value: [7])?.1 == 1
        )
    }

    /// A number this setting has no meaning for is refused rather than shown:
    /// a picker with nothing selected, written on to the next watch, is worse
    /// than not hearing it.
    @Test func aChoiceOutOfRangeFromTheWatchIsRefused() {
        #expect(WatchSettingsCodec.decodeRecord(key: WatchSettingsCodec.key(for: .unitsWind), value: [9]) == nil)
    }
}

/// Settings wider than a byte.
///
/// `lightTimeoutMs` is a `uint32_t` in `prefs.c`, and
/// `settings_blob_db_insert` writes what arrives straight into the settings
/// file — so a four-byte pref given one byte is read back as that byte plus
/// three of whatever was beside it (#93).
@Suite
struct WatchSettingWidthTests {
    @Test func aDurationIsSentAsFourLittleEndianBytes() {
        let frame = WatchSettingsCodec.insertFrame(.backlightTimeout, rawValue: 8_000, token: 1)

        // 8000 = 0x1F40, little-endian across four bytes.
        #expect(Array(frame.payload.suffix(4)) == [0x40, 0x1F, 0x00, 0x00])
    }

    @Test func aSwitchIsStillOneByte() {
        let frame = WatchSettingsCodec.insertFrame(.backlight, rawValue: 1, token: 1)

        #expect(frame.payload.last == 1)
        #expect(WatchSetting.backlight.kind.width == 1)
        #expect(WatchSetting.backlightTimeout.kind.width == 4)
    }

    /// Four bytes back, read as one number rather than as its first byte.
    @Test func aDurationComingBackFromTheWatchIsReadWhole() {
        let key = WatchSettingsCodec.key(for: .backlightTimeout)

        #expect(WatchSettingsCodec.decodeRecord(key: key, value: [0x40, 0x1F, 0, 0])?.1 == 8_000)
        // One byte is not a `uint32_t`, whatever it says.
        #expect(WatchSettingsCodec.decodeRecord(key: key, value: [0x40]) == nil)
    }

    /// Only the lengths the watch itself offers, from
    /// `src/fw/apps/system/settings/display.c`.
    @Test func aLengthTheWatchDoesNotOfferIsRefused() {
        let key = WatchSettingsCodec.key(for: .backlightTimeout)

        #expect(WatchSetting.backlightTimeout.accepts(rawValue: 5_000))
        #expect(!WatchSetting.backlightTimeout.accepts(rawValue: 4_000))
        #expect(WatchSettingsCodec.decodeRecord(key: key, value: [0xA0, 0x0F, 0, 0]) == nil)
    }

    /// A picker carries the value, not the row it sits at: for a duration
    /// those differ.
    @Test func theOptionsCarryTheirOwnValues() {
        #expect(WatchSetting.backlightTimeout.optionRawValues == [3_000, 5_000, 8_000])
        #expect(WatchSetting.textSize.optionRawValues == [0, 1, 2, 3])
        #expect(
            WatchSetting.backlightTimeout.optionRawValues.count
                == WatchSetting.backlightTimeout.optionTitles.count
        )
    }
}

/// A backlight preset, which is not a setting.
///
/// Writing `lightPreset` alone reached the watch and changed nothing anybody
/// could see: the watch's own settings app calls `backlight_set_preset`, which
/// writes the preset key and the seven values it stands for, while a phone
/// write lands on a handler that assigns the global and touches nothing else.
/// `backlight_get_preset` then compares the seven against the preset and
/// answers `Advanced` on any mismatch — its own comment blames "phone sync"
/// for exactly this (#115).
@Suite
@MainActor
struct BacklightPresetTests {
    private func makeModel(directory: URL, client: MockWatchClient) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
    }

    private func connectedModel(
        _ directory: URL,
        _ client: MockWatchClient
    ) async throws -> AppModel {
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        return model
    }

    @Test func choosingAPresetWritesEverythingItStandsFor() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = try await connectedModel(directory, client)

        await model.setWatchSetting(.backlightPreset, rawValue: BacklightPreset.maxBrightness)

        // `s_backlight_preset_settings[BacklightPreset_MaxBrightness]`.
        #expect(client.writtenWatchSettings[.backlightPreset] == 0)
        #expect(client.writtenWatchSettings[.backlightIntensity] == 100)
        #expect(client.writtenWatchSettings[.backlightTimeout] == 5_000)
        #expect(client.writtenWatchSettings[.backlight] == 1)
        #expect(client.writtenWatchSettings[.backlightAmbientSensor] == 1)
        #expect(client.writtenWatchSettings[.backlightMotion] == 1)
        #expect(client.writtenWatchSettings[.backlightTouchWake] == 0)
        #expect(client.writtenWatchSettings[.backlightDynamicMode] == 0)
        // And kept on the phone, so that the connect-time sync writes the same
        // seven again rather than the values the preset replaced.
        #expect(model.watchSettingValue(.backlightIntensity) == 100)
        #expect(model.watchSettingValue(.backlightTimeout) == 5_000)
    }

    /// "Custom" stands for no set of values, so it writes none — the same early
    /// return `backlight_set_preset` takes for `Advanced`.
    @Test func choosingCustomWritesOnlyThePreset() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = try await connectedModel(directory, client)

        await model.setWatchSetting(.backlightPreset, rawValue: BacklightPreset.batterySaver)
        await model.setWatchSetting(.backlightPreset, rawValue: BacklightPreset.advanced)

        #expect(client.writtenWatchSettings[.backlightPreset] == 3)
        // Left where Battery Saver put them rather than reset to anything.
        #expect(client.writtenWatchSettings[.backlightIntensity] == 25)
        #expect(model.watchSettingValue(.backlightIntensity) == 25)
    }

    /// What the watch would report, not what was last chosen.
    @Test func aPresetIsReportedOnlyWhileItsValuesStillMatchIt() {
        var values: [WatchSetting: Int] = [.backlightPreset: BacklightPreset.standard]
        for (setting, value) in BacklightPreset.settings(for: BacklightPreset.standard) ?? [:] {
            values[setting] = value
        }
        let reported = { (setting: WatchSetting) in values[setting] ?? setting.defaultRawValue }

        #expect(BacklightPreset.reported(by: reported) == BacklightPreset.standard)

        // One value moved by hand and the watch has left the preset behind.
        values[.backlightIntensity] = 70
        #expect(BacklightPreset.reported(by: reported) == BacklightPreset.advanced)

        // Every concrete preset has the backlight on, so switching it off is
        // Advanced however well the rest still match.
        values[.backlightIntensity] = 50
        values[.backlight] = 0
        #expect(BacklightPreset.reported(by: reported) == BacklightPreset.advanced)
    }

    /// A watch built without `CONFIG_DYNAMIC_BACKLIGHT` has no such pref, so it
    /// is not compared: doing so would report Custom on every such watch for
    /// ever, whatever was chosen.
    @Test func aSettingTheWatchMayNotHaveIsNotComparedAgainstThePreset() {
        var values: [WatchSetting: Int] = [.backlightPreset: BacklightPreset.batterySaver]
        for (setting, value) in BacklightPreset.settings(for: BacklightPreset.batterySaver) ?? [:] {
            values[setting] = value
        }
        values[.backlightDynamicMode] = 1

        #expect(WatchSetting.backlightDynamicMode.mayBeAbsent)
        #expect(
            BacklightPreset.reported { values[$0] ?? $0.defaultRawValue }
                == BacklightPreset.batterySaver
        )
    }

    /// `BACKLIGHT_INTENSITY_MIN` is 1. Zero is not "off": the handler calls it
    /// invalid and writes `BACKLIGHT_INTENSITY_DEFAULT` back, so a backlight is
    /// turned off with `lightEnabled` instead.
    @Test func theBrightnessIsOneByteAndNeverZero() {
        #expect(WatchSetting.backlightIntensity.kind.width == 1)
        #expect(!WatchSetting.backlightIntensity.accepts(rawValue: 0))
        #expect(WatchSetting.backlightIntensity.accepts(rawValue: 1))
        #expect(WatchSetting.backlightIntensity.accepts(rawValue: 100))
        #expect(!WatchSetting.backlightIntensity.accepts(rawValue: 101))

        let frame = WatchSettingsCodec.insertFrame(.backlightIntensity, rawValue: 100, token: 1)
        #expect(frame.payload.last == 100)
        // And read back as its number rather than as non-zero.
        #expect(
            WatchSettingsCodec.decodeRecord(
                key: WatchSettingsCodec.key(for: .backlightIntensity),
                value: [72]
            )?.1 == 72
        )
    }
}

/// Which rows a board gets, read from its PebbleOS defconfig.
///
/// Per board and not per model, because the emulator differs from the hardware
/// it stands in for: `qemu_emery` is a Pebble Time 2 to `WatchModel`, but its
/// defconfig has no `CONFIG_DYNAMIC_BACKLIGHT` where the real board's does.
@Suite
struct WatchBoardSettingsTests {
    @Test func theTouchRowIsOnlyForABoardWithATouchscreen() {
        // `CONFIG_TOUCH=y` in getafix, obelix, qemu_emery and qemu_gabbro;
        // not in asterix or qemu_flint.
        #expect(WatchSetting.backlightTouchWake.isOffered(on: .obelixPVT))
        #expect(WatchSetting.backlightTouchWake.isOffered(on: .getafixDVT))
        #expect(WatchSetting.backlightTouchWake.isOffered(on: .qemuEmery))
        #expect(!WatchSetting.backlightTouchWake.isOffered(on: .asterix))
        #expect(!WatchSetting.backlightTouchWake.isOffered(on: .qemuFlint))
    }

    @Test func theDynamicModeRowFollowsTheWhitelistItself() {
        // `CONFIG_DYNAMIC_BACKLIGHT=y` in getafix and obelix only — notably
        // not in qemu_emery, which is why this is per board and not per model.
        #expect(WatchSetting.backlightDynamicMode.isOffered(on: .obelixPVT))
        #expect(WatchSetting.backlightDynamicMode.isOffered(on: .getafixEVT))
        #expect(!WatchSetting.backlightDynamicMode.isOffered(on: .qemuEmery))
        #expect(!WatchSetting.backlightDynamicMode.isOffered(on: .asterix))
    }

    /// A watch the app cannot place gets neither: a row that might do nothing
    /// is worse than no row. The robert boards read the same way, since this
    /// PebbleOS tree has no defconfig for them to read.
    @Test func aBoardTheAppCannotPlaceHidesTheConditionalRows() {
        #expect(!WatchSetting.backlightTouchWake.isOffered(on: nil))
        #expect(!WatchSetting.backlightDynamicMode.isOffered(on: nil))
        #expect(!WatchSetting.backlightDynamicMode.isOffered(on: .robertBigboard2))
        // The unconditional ones are unconditional.
        #expect(WatchSetting.backlightIntensity.isOffered(on: nil))
        #expect(WatchSetting.clock24Hour.isOffered(on: nil))
    }

    /// On a board that has the dynamic mode, the preset comparison includes
    /// it, the way that board's own `backlight_get_preset` does.
    @Test func aBoardWithTheDynamicModeComparesItAgainstThePreset() {
        var values: [WatchSetting: Int] = [.backlightPreset: BacklightPreset.standard]
        for (setting, value) in BacklightPreset.settings(for: BacklightPreset.standard) ?? [:] {
            values[setting] = value
        }
        values[.backlightDynamicMode] = 1
        let reported = { (setting: WatchSetting) in values[setting] ?? setting.defaultRawValue }

        // The watch with it says Advanced, so this must too.
        #expect(BacklightPreset.reported(by: reported, on: .obelixPVT) == BacklightPreset.advanced)
        // The watch without it has no such pref to disagree.
        #expect(BacklightPreset.reported(by: reported, on: .qemuEmery) == BacklightPreset.standard)
        #expect(BacklightPreset.reported(by: reported, on: nil) == BacklightPreset.standard)
    }
}
