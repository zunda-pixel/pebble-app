public import Foundation

public enum HealthSyncCodec {
    public static var endpoint: UInt16 { 911 }

    public static func requestFrame(since date: Date?, now: Date = Date()) -> PebbleProtocolFrame {
        let interval = date.map { max(0, now.timeIntervalSince($0)) } ?? Double(UInt32.max)
        let seconds = UInt32(min(Double(UInt32.max), interval))
        return PebbleProtocolFrame(endpoint: endpoint, payload: [0x01] + seconds.littleEndianBytes)
    }
}
