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
        #expect(Defaults[.watchSettings][WatchSetting.clock24Hour.rawValue] == !wasOn)
        // The other watch is told.
        #expect(clients[second.id]?.writtenWatchSettings[.clock24Hour] == !wasOn)
        // The one that told us is not written back to.
        #expect(clients[first.id]?.writtenWatchSettings[.clock24Hour] == wasOn)
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
        #expect(WatchSettingsCodec.decodeRecord(key: key, value: [1])?.1 == true)
        #expect(WatchSettingsCodec.decodeRecord(key: key, value: [0])?.1 == false)
        // The firmware accepts the name either way from the phone and sends it
        // either way back.
        #expect(WatchSettingsCodec.decodeRecord(key: Array("lightEnabled".utf8), value: [1])?.0 == .backlight)
        // Not a switch: `lightTimeoutMs` is a number, and reading its first
        // byte as a boolean would turn 10000 ms into "on".
        #expect(WatchSettingsCodec.decodeRecord(key: Array("lightEnabled".utf8), value: [0x10, 0x27]) == nil)
        #expect(WatchSettingsCodec.decodeRecord(key: Array("lightTimeoutMs".utf8), value: [1]) == nil)
    }
}
