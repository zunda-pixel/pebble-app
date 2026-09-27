public enum PebbleCRC32 {
    public static func calculate(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        let alignedCount = bytes.count - bytes.count % 4
        var offset = 0
        while offset < alignedCount {
            let word = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            value = accumulate(word, into: value)
            offset += 4
        }
        if offset < bytes.count {
            // A trailing partial word is zero-padded on the left and then read back
            // little-endian, which reverses the remaining bytes.
            var word: UInt32 = 0
            for (index, byte) in bytes[offset...].reversed().enumerated() {
                word |= UInt32(byte) << (UInt32(index) * 8)
            }
            value = accumulate(word, into: value)
        }
        return value
    }

    private static func accumulate(_ word: UInt32, into value: UInt32) -> UInt32 {
        var value = value ^ word
        for _ in 0..<32 {
            value = value & 0x80000000 != 0
                ? value << 1 ^ 0x04C11DB7
                : value << 1
        }
        return value
    }
}
