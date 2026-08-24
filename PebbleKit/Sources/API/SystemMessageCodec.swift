public enum SystemMessageCodec {
    public static var endpoint: UInt16 { 18 }
    public static func firmwareUpdateStartFrame(bytesToSend: UInt32) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0, 1] + UInt32(0).littleEndianBytes + bytesToSend.littleEndianBytes)
    }
    public static func firmwareUpdateCompleteFrame() -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0, 2])
    }
}
private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian) { Array($0) } }
}
