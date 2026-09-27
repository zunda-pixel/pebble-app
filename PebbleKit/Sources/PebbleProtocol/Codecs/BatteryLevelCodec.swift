public enum BatteryLevelCodec {
    public static func decode(_ bytes: [UInt8]) -> Int? {
        guard let value = bytes.first, value <= 100 else {
            return nil
        }
        return Int(value)
    }
}
