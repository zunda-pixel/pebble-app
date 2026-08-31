/// Byte conversions the Pebble protocol needs, written without unsafe pointers
/// so callers stay inside strict memory safety.

extension FixedWidthInteger {
    /// The value's bytes, most significant first.
    var bigEndianBytes: [UInt8] {
        (0..<(bitWidth / 8)).reversed().map { UInt8(truncatingIfNeeded: self >> ($0 * 8)) }
    }

    /// The value's bytes, least significant first.
    var littleEndianBytes: [UInt8] {
        (0..<(bitWidth / 8)).map { UInt8(truncatingIfNeeded: self >> ($0 * 8)) }
    }

    /// Reads the value back from its bytes, most significant first. Bytes past
    /// the value's width are ignored, and a short run reads as though the
    /// missing high bytes were zero.
    init(bigEndianBytes bytes: some Sequence<UInt8>) {
        self = bytes.prefix(Self.bitWidth / 8).reduce(into: Self.zero) { value, byte in
            value = (value << 8) | Self(truncatingIfNeeded: byte)
        }
    }

    /// Reads the value back from its bytes, least significant first.
    init(littleEndianBytes bytes: some Sequence<UInt8>) {
        self = bytes.prefix(Self.bitWidth / 8).reversed().reduce(into: Self.zero) { value, byte in
            value = (value << 8) | Self(truncatingIfNeeded: byte)
        }
    }
}

extension Sequence<UInt8> {
    /// The bytes as lowercase hexadecimal, which is how the protocol writes
    /// identifiers and how checksums are compared.
    var hexadecimalString: String {
        map { byte in
            let digits = String(byte, radix: 16)
            return byte < 0x10 ? "0" + digits : digits
        }
        .joined()
    }
}
