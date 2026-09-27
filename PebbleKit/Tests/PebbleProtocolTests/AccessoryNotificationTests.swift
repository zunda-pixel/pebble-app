import Foundation
import Testing
@testable import PebbleProtocol

@Suite
struct AccessoryNotificationCodecTests {
    private func notification(
        title: String? = "Mia",
        body: String? = "Lunch?",
        sourceIdentifier: String? = "com.apple.MobileSMS",
        actions: [ForwardedNotification.Action] = []
    ) -> ForwardedNotification {
        ForwardedNotification(
            identifier: "n1",
            title: title,
            subtitle: nil,
            body: body,
            sourceName: "Messages",
            sourceIdentifier: sourceIdentifier,
            shouldAlert: true,
            actions: actions
        )
    }

    @Test
    func aNotificationIsWrittenAsTheWatchParsesIt() {
        let bytes = AccessoryNotificationCodec.encode(.present(notification(
            actions: [.init(identifier: "r", title: "Reply", collectsText: true)]
        )))

        // `prv_present` and `prv_parse_action` in accessory_notifications.c.
        #expect(bytes == [0x01]
            + [0x01, 3] + Array("Mia".utf8)
            + [0x03, 6] + Array("Lunch?".utf8)
            + [0x04, 8] + Array("Messages".utf8)
            + [0x08, 19] + Array("com.apple.MobileSMS".utf8)
            + [0x05, 22] + Array("com.apple.MobileSMS".utf8) + [0x1F] + Array("n1".utf8)
            + [0x06, 1, 1]
            + [0x07, 9, 0x01, 1] + Array("r".utf8) + [5] + Array("Reply".utf8))
    }

    @Test
    func twoAppsNotificationsWithOneIdentifierAreTwoOnTheWatch() {
        let messages = AccessoryNotificationCodec.encode(.present(notification()))
        let mail = AccessoryNotificationCodec.encode(.present(notification(sourceIdentifier: "com.apple.mobilemail")))

        let fromMessages = tlvs(messages).first { $0.tag == 0x05 }?.value
        let fromMail = tlvs(mail).first { $0.tag == 0x05 }?.value
        #expect(fromMessages != nil)
        #expect(fromMessages != fromMail)
        #expect(fromMail == Array("com.apple.mobilemail".utf8) + [0x1F] + Array("n1".utf8))
    }

    @Test
    func aReplyNamesTheNotificationByTheIdentifierItsPresentCarried() {
        let bytes = AccessoryNotificationCodec.encode(.present(notification()))

        let presented = tlvs(bytes).first { $0.tag == 0x05 }?.value
        let onTheWatch = AccessoryNotificationCodec.identifierOnTheWatch(
            sourceIdentifier: "com.apple.MobileSMS",
            notificationIdentifier: "n1"
        )
        #expect(presented == Array(onTheWatch.utf8))
    }

    @Test
    func aNotificationWithNoSourceIdentifierLeavesItsTagOut() {
        let unnamed = AccessoryNotificationCodec.encode(.present(notification(sourceIdentifier: nil)))
        let empty = AccessoryNotificationCodec.encode(.present(notification(sourceIdentifier: "")))

        #expect(unnamed == [0x01]
            + [0x01, 3] + Array("Mia".utf8)
            + [0x03, 6] + Array("Lunch?".utf8)
            + [0x04, 8] + Array("Messages".utf8)
            + [0x05, 3] + [0x1F] + Array("n1".utf8)
            + [0x06, 1, 1])
        #expect(empty == unnamed)
    }

    @Test
    func aSourceIdentifierIsCutToWhatTheWatchCanKeyItsPreferencesBy() {
        let identifier = "com.example." + String(repeating: "x", count: 200)
        let bytes = AccessoryNotificationCodec.encode(.present(notification(sourceIdentifier: identifier)))

        // `SETTINGS_KEY_MAX_LEN` in settings_raw_iter.h.
        #expect(tlvs(bytes).first { $0.tag == 0x08 }?.value == Array(identifier.utf8.prefix(127)))
    }

    @Test
    func aTitleTooLongForTheWatchIsCutBetweenCharacters() {
        let title = String(repeating: "あ", count: 30)
        let bytes = AccessoryNotificationCodec.encode(.present(notification(title: title, body: nil)))

        #expect(Array(bytes[1...2]) == [0x01, 63])
        #expect(String(bytes: bytes[3..<66], encoding: .utf8) == String(repeating: "あ", count: 21))
    }

    @Test
    func anActionTheWatchCouldNotShowOrAnswerIsLeftOut() throws {
        let actions: [ForwardedNotification.Action] = [
            .init(identifier: "untitled", title: "", collectsText: false),
            .init(identifier: String(repeating: "x", count: 250), title: "Long", collectsText: false),
        ] + (1...5).map { .init(identifier: "a\($0)", title: "A\($0)", collectsText: false) }

        let bytes = AccessoryNotificationCodec.encode(.present(notification(actions: actions)))

        let actionIdentifiers = tlvs(bytes).filter { $0.tag == 0x07 }.map { value in
            String(decoding: value.value[2..<(2 + Int(value.value[1]))], as: UTF8.self)
        }
        #expect(actionIdentifiers == ["a1", "a2", "a3", "a4"])
    }

    @Test
    func aRemovalCutsTheIdentifierTheWayItsPresentDid() {
        let identifier = String(repeating: "通", count: 90)
        let present = AccessoryNotificationCodec.encode(.present(notification()).withIdentifier(identifier))
        let removal = AccessoryNotificationCodec.encode(
            .remove(sourceIdentifier: "com.apple.MobileSMS", notificationIdentifier: identifier)
        )

        let presented = tlvs(present).first { $0.tag == 0x05 }?.value
        #expect(presented?.count == 254)
        #expect(removal.first == 0x02)
        #expect(Array(removal.dropFirst()) == presented)
        #expect(AccessoryNotificationCodec.encode(.removeAll) == [0x03])
    }

    @Test
    func aReplyCarriesItsTextOnlyWhenThereIsSome() throws {
        // `accessory_notifications_invoke_action`: the text length is written
        // for every action, zero for a plain one.
        let typed = try AccessoryNotificationCodec.decodeReply(
            [2] + Array("n1".utf8) + [1] + Array("r".utf8) + [3, 0] + Array("は".utf8)
        )
        let plain = try AccessoryNotificationCodec.decodeReply([2] + Array("n1".utf8) + [2] + Array("ok".utf8) + [0, 0])

        #expect(typed == AccessoryNotificationReply(notificationIdentifier: "n1", actionIdentifier: "r", text: "は"))
        #expect(plain == AccessoryNotificationReply(notificationIdentifier: "n1", actionIdentifier: "ok", text: nil))
        #expect(throws: AccessoryNotificationCodecError.truncated) {
            try AccessoryNotificationCodec.decodeReply([2] + Array("n1".utf8) + [4] + Array("ok".utf8))
        }
    }

    private func tlvs(_ bytes: [UInt8]) -> [(tag: UInt8, value: [UInt8])] {
        var result: [(tag: UInt8, value: [UInt8])] = []
        var offset = 1
        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset + 1])
            result.append((bytes[offset], Array(bytes[(offset + 2)..<(offset + 2 + length)])))
            offset += 2 + length
        }
        return result
    }
}

private extension AccessoryNotificationMessage {
    func withIdentifier(_ identifier: String) -> Self {
        guard case .present(var notification) = self else { return self }
        notification.identifier = identifier
        return .present(notification)
    }
}

@Suite
struct AccessoryTransportFrameTests {
    private let featureID = UUID(uuidString: "807C08BE-0000-4000-8000-000000000001")!

    @Test
    func theWatchsPublicKeyIsTheFrameAfterItsType() {
        let key = [UInt8](repeating: 0xAB, count: 64)

        #expect(AccessoryTransportFrame.publicKey(from: [0x01] + key) == key)
        #expect(AccessoryTransportFrame.publicKey(from: [0x82, 0x02] + key) == nil)
        #expect(AccessoryTransportFrame.publicKey(from: [0x01] + key.dropLast()) == nil)
    }

    @Test
    func aSessionCarriesTheKeyAndTheIdentifierTheWatchDerivesFrom() throws {
        let enc = [0x04] + [UInt8](repeating: 0x11, count: 64)
        let accessory = UUID(uuidString: "FFFD2EEE-254F-E6EB-985F-49E78EAF5FD0")!

        let frame = try AccessoryTransportFrame.session(encapsulatedKey: enc, accessoryIdentifier: accessory)

        // `prv_handle_session_frame`; the identifier upper-case, as in the HPKE
        // info iOS derives with.
        #expect(frame == [0x02] + enc + [36] + Array("FFFD2EEE-254F-E6EB-985F-49E78EAF5FD0".utf8))
        #expect(throws: AccessoryTransportFrameError.malformedKey) {
            try AccessoryTransportFrame.session(encapsulatedKey: Array(enc.dropFirst()), accessoryIdentifier: accessory)
        }
    }

    @Test
    func aMessageLargerThanOneWriteIsSentInMarkedPieces() throws {
        let sealed = [UInt8](repeating: 0x5A, count: 100)

        let writes = try AccessoryTransportFrame.dataWrites(featureID: featureID, sealed: sealed, maximumWriteLength: 50)

        #expect(writes.map(\.count) == [50, 50, 43])
        #expect(writes.map { $0[0] } == [0x03, 0x03, 0x03])
        #expect(writes.map { $0[1] } == [0x03, 0x01, 0x00])
        let logical = writes.flatMap { $0.dropFirst(2) }
        #expect(logical == [36] + Array(featureID.uuidString.utf8) + sealed)
    }

    @Test
    func aMessageThatFitsIsOneFirstAndLastWrite() throws {
        let writes = try AccessoryTransportFrame.dataWrites(featureID: featureID, sealed: [1, 2, 3], maximumWriteLength: 512)

        #expect(writes.count == 1)
        #expect(writes[0][1] == 0x02)
    }

    @Test
    func aWriteIsNeverLargerThanTheWatchAccepts() throws {
        let writes = try AccessoryTransportFrame.dataWrites(
            featureID: featureID,
            sealed: [UInt8](repeating: 0, count: 2_000),
            maximumWriteLength: 4_096
        )

        #expect(writes.allSatisfy { $0.count <= 512 })
    }

    @Test
    func aReplyIsReassembledAndAStaleTailIsDropped() {
        let logical = [36] + Array(featureID.uuidString.utf8) + [9, 8, 7]
        var reassembler = AccessoryTransportResponseReassembler()

        #expect(reassembler.receive([0x82, 0x03] + [1, 2, 3]) == nil)
        #expect(reassembler.receive([0x03, 0x00, 1]) == nil)
        #expect(reassembler.receive([0x82, 0x03] + logical.prefix(20)) == nil)
        let reply = reassembler.receive([0x82, 0x00] + logical.dropFirst(20))

        #expect(reply == AccessoryTransportResponse(featureID: featureID, sealed: [9, 8, 7]))
    }

    @Test
    func aReplyWithNoFeatureIDIsNotOne() {
        var reassembler = AccessoryTransportResponseReassembler()

        #expect(reassembler.receive([0x82, 0x02, 0x00, 1, 2]) == nil)
    }
}
