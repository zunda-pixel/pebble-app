public import Foundation

public enum HealthSyncCodec {
    public static var endpoint: UInt16 { 911 }

    public static func requestFrame(since date: Date?, now: Date = Date()) -> PebbleProtocolFrame {
        let interval = date.map { max(0, now.timeIntervalSince($0)) } ?? Double(UInt32.max)
        let seconds = UInt32(min(Double(UInt32.max), interval))
        return PebbleProtocolFrame(endpoint: endpoint, payload: [0x01] + seconds.littleEndianBytes)
    }
}

public enum HealthSyncResponseCodec {
    public static func decode(_ frame: PebbleProtocolFrame) throws -> Bool {
        guard frame.endpoint == HealthSyncCodec.endpoint, frame.payload.count >= 2, frame.payload[0] == 0x11 else {
            throw HealthSyncResponseError.invalidPayload
        }
        return frame.payload[1] == 0x01
    }
}
public enum HealthSyncResponseError: Error, Equatable, Sendable { case invalidPayload }
