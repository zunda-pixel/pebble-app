public import Foundation

/// The watch's AccessoryNotifications transport: the GATT service
/// `accessory_transport_service.c` hosts, and the frames written to it and
/// notified from it. Apple fixes neither, so both ends are this app's and the
/// firmware's to agree on; everything inside a DATA or RESPONSE frame is sealed
/// and opened by iOS and the watch, never by the app.
public enum AccessoryTransportFrame {
    public static let serviceUUID = "50000000-328E-0FBB-C642-1AA6699BDADA"
    /// Watch to phone, by notification: PUBKEY and RESPONSE.
    public static let notifyCharacteristicUUID = "50000001-328E-0FBB-C642-1AA6699BDADA"
    /// Phone to watch, by write with response: SESSION and DATA.
    public static let writeCharacteristicUUID = "50000002-328E-0FBB-C642-1AA6699BDADA"

    static let publicKeyType: UInt8 = 0x01
    static let sessionType: UInt8 = 0x02
    static let dataType: UInt8 = 0x03
    static let responseType: UInt8 = 0x82

    static let moreFlag: UInt8 = 0x01
    static let firstFlag: UInt8 = 0x02

    /// A P-256 point without its `0x04` prefix, as the watch notifies it and as
    /// `SecurityMessage` carries it.
    public static let publicKeyByteCount = 64
    /// An uncompressed P-256 point: HPKE's `enc` for this suite.
    public static let encapsulatedKeyByteCount = 65
    /// `ATS_MAX_RX_WRITE`: the ATT attribute value limit, which the watch refuses
    /// a write beyond.
    static let maximumWriteByteCount = 512
    /// `ACCESSORY_TRANSPORT_MAX_FEATURE_ID_LEN`.
    static let maximumFeatureIDByteCount = 64
    /// `ACCESSORY_TRANSPORT_MAX_PAYLOAD`, sealed: nonce, plaintext, tag.
    static let maximumSealedByteCount = 12 + 2_048 + 16

    /// The watch's public key, from the first thing it notifies after a
    /// subscription; nil for any other frame.
    public static func publicKey(from frame: [UInt8]) -> [UInt8]? {
        guard frame.count == 1 + publicKeyByteCount, frame.first == publicKeyType else { return nil }
        return Array(frame.dropFirst())
    }

    /// `enc | u8 uuid_len | uuid`. The identifier is the CoreBluetooth peripheral
    /// the watch was reached as: it is in the HPKE info both ends derive from.
    public static func session(
        encapsulatedKey: [UInt8],
        accessoryIdentifier: UUID
    ) throws -> [UInt8] {
        guard encapsulatedKey.count == encapsulatedKeyByteCount else {
            throw AccessoryTransportFrameError.malformedKey
        }
        let identifier = Array(accessoryIdentifier.uuidString.utf8)
        return [sessionType] + encapsulatedKey + [UInt8(identifier.count)] + identifier
    }

    /// `u8 feature_id_len | feature_id | sealed`, cut into writes of at most
    /// `maximumWriteLength` bytes as `0x03 | flags | chunk`. The watch starts over
    /// on FIRST, so a message a restarted extension abandoned half way is not
    /// spliced onto the next one.
    public static func dataWrites(
        featureID: UUID,
        sealed: [UInt8],
        maximumWriteLength: Int
    ) throws -> [[UInt8]] {
        guard sealed.count <= maximumSealedByteCount else {
            throw AccessoryTransportFrameError.messageTooLarge
        }
        let chunkByteCount = min(maximumWriteLength, maximumWriteByteCount) - 2
        guard chunkByteCount > 0 else { throw AccessoryTransportFrameError.messageTooLarge }
        let featureIDBytes = Array(featureID.uuidString.utf8)
        let logical = [UInt8(featureIDBytes.count)] + featureIDBytes + sealed
        return stride(from: 0, to: logical.count, by: chunkByteCount).map { offset in
            let end = min(offset + chunkByteCount, logical.count)
            var flags: UInt8 = 0
            if offset == 0 { flags |= firstFlag }
            if end < logical.count { flags |= moreFlag }
            return [dataType, flags] + logical[offset..<end]
        }
    }
}

public enum AccessoryTransportFrameError: Error, Equatable, Sendable {
    case malformedKey
    case messageTooLarge
}

/// A reply the watch sealed, reassembled from its RESPONSE notifications.
public struct AccessoryTransportResponse: Equatable, Sendable {
    public var featureID: UUID
    public var sealed: [UInt8]
}

/// Puts `0x82 | flags | chunk` notifications back together. One per link: the
/// watch has a single reply in flight to a phone at a time.
public struct AccessoryTransportResponseReassembler: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// The reply the fragment completes; nil while more is to come, and for
    /// anything that is not a RESPONSE fragment or does not make a reply.
    public mutating func receive(_ frame: [UInt8]) -> AccessoryTransportResponse? {
        guard frame.count >= 2, frame[0] == AccessoryTransportFrame.responseType else { return nil }
        let flags = frame[1]
        if flags & AccessoryTransportFrame.firstFlag != 0 {
            pending = []
        }
        pending += frame.dropFirst(2)
        let maximum = 1 + AccessoryTransportFrame.maximumFeatureIDByteCount
            + AccessoryTransportFrame.maximumSealedByteCount
        guard pending.count <= maximum else {
            pending = []
            return nil
        }
        guard flags & AccessoryTransportFrame.moreFlag == 0 else { return nil }
        let logical = pending
        pending = []
        guard let length = logical.first.map(Int.init), length > 0, logical.count > length,
              let featureID = UUID(uuidString: String(decoding: logical[1...length], as: UTF8.self)) else {
            return nil
        }
        return AccessoryTransportResponse(featureID: featureID, sealed: Array(logical.dropFirst(1 + length)))
    }
}
