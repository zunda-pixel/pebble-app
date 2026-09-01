public import Foundation
import MemberwiseInit

/// How to reach a contact. The watch keeps addresses apart from the contact
/// itself because it is an address, not a person, that a reply is sent to.
public enum PebbleContactAddressKind: UInt8, Codable, Equatable, Sendable {
    case phoneNumber = 1
    case email = 2
}

@MemberwiseInit(.public)
public struct PebbleContactAddress: Codable, Equatable, Sendable, Identifiable {
    /// The watch refers to an address by this, both in the send-text list and
    /// when it tells the phone which address a reply is for, so it has to stay
    /// the same between syncs.
    public var id: UUID
    public var kind: PebbleContactAddressKind
    public var value: String
    /// Whether the watch's Send Text app puts this one at the top.
    public var isFavourite: Bool = false
}

@MemberwiseInit(.public)
public struct PebbleContact: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The phone's own identifier for this contact, kept so a contact renamed
    /// on the phone updates the same record rather than making a second one.
    public var systemIdentifier: String
    public var name: String
    public var addresses: [PebbleContactAddress]
}

/// The contacts database, which is what the watch's Send Text app shows.
///
/// A record is the contact's own attributes followed by its addresses, each
/// with attributes of its own — the same shape as a timeline item's actions,
/// with an address header in place of an action header
/// (`attribute_group.c`).
public enum ContactsCodec {
    public static var databaseID: UInt8 { 8 }

    static let titleAttribute: UInt8 = 1
    static let addressAttribute: UInt8 = 39

    public static func key(for contact: PebbleContact) -> [UInt8] {
        BlobDBCodec.uuidBytes(contact.id)
    }

    public static func value(for contact: PebbleContact) -> [UInt8] {
        var bytes = BlobDBCodec.uuidBytes(contact.id)
        // Flags: the firmware keeps the field but reads nothing out of it yet.
        bytes += UInt32(0).littleEndianBytes
        bytes.append(1)
        bytes.append(UInt8(clamping: contact.addresses.count))
        bytes += attribute(id: titleAttribute, content: Array(contact.name.utf8))
        for address in contact.addresses.prefix(Int(UInt8.max)) {
            bytes += BlobDBCodec.uuidBytes(address.id)
            bytes.append(address.kind.rawValue)
            bytes.append(1)
            bytes += attribute(id: addressAttribute, content: Array(address.value.utf8))
        }
        return bytes
    }

    public static func insertFrame(_ contact: PebbleContact, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: key(for: contact),
            value: value(for: contact),
            token: token
        )
    }

    public static func deleteFrame(id: UUID, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.deleteFrame(databaseID: databaseID, key: BlobDBCodec.uuidBytes(id), token: token)
    }

    private static func attribute(id: UInt8, content: [UInt8]) -> [UInt8] {
        [id] + UInt16(content.count).littleEndianBytes + content
    }
}

/// Which contacts the watch's Send Text app lists, and in what order.
///
/// The contacts database holds everyone the phone sent; this says which of them
/// the app shows. A watch given contacts but no list shows "Add contacts in
/// mobile app", because the app reads this and not the database.
public enum SendTextPrefsCodec {
    /// The watch app preferences database, shared with the weather app's
    /// location order and the reminder app's switch.
    public static var databaseID: UInt8 { 9 }
    public static var key: String { "sendTextApp" }

    /// Every address the reader chose, whichever kind it is. The app shows the
    /// string and does not look at the kind, so an email address is a row that
    /// works — and an email address is what sends an iMessage rather than a
    /// text.
    public static func value(for contacts: [PebbleContact]) -> [UInt8] {
        var records: [UInt8] = []
        var count = 0
        for contact in contacts {
            for address in contact.addresses {
                guard count < Int(UInt8.max) else { break }
                records += BlobDBCodec.uuidBytes(contact.id)
                records += BlobDBCodec.uuidBytes(address.id)
                records.append(address.isFavourite ? 1 : 0)
                count += 1
            }
        }
        return [UInt8(count)] + records
    }

    public static func insertFrame(
        contacts: [PebbleContact],
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: Array(key.utf8),
            value: value(for: contacts),
            token: token
        )
    }
}

public actor PebbleContactLibrary {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("contacts.json")
    }

    public func contacts() throws -> [PebbleContact] {
        try PersistentJSON.loadRecovering([PebbleContact].self, from: fileURL) ?? []
    }

    public func save(_ contacts: [PebbleContact]) throws {
        try PersistentJSON.save(contacts, to: fileURL)
    }
}
