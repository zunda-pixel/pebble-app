public enum SystemMessageCodec {
    public static var endpoint: UInt16 { 18 }
    public static func firmwareUpdateStartFrame(bytesToSend: UInt32) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0, 1] + UInt32(0).littleEndianBytes + bytesToSend.littleEndianBytes)
    }
    public static func firmwareUpdateCompleteFrame() -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0, 2])
    }
    public static func decodeFirmwareUpdateStartResponse(_ frame: PebbleProtocolFrame) throws -> Bool {
        guard frame.endpoint == endpoint, frame.payload.count >= 3,
              frame.payload[0] == 0, frame.payload[1] == 0x0A else {
            throw SystemMessageCodecError.invalidResponse
        }
        return frame.payload[2] == 0x01
    }
}
public enum SystemMessageCodecError: Error, Equatable, Sendable { case invalidResponse, updateRejected }
private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian) { Array($0) } }
}
