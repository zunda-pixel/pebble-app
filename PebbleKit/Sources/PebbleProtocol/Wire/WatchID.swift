/// How this phone names one watch.
///
/// Not a `UUID`, though CoreBluetooth's is one: the identifier is whatever the
/// transport that found the watch calls it — a per-host peripheral identifier
/// from CoreBluetooth, `"qemu-emery"` from the emulator, `"mock-flint"` from
/// the mock. It is only ever compared and stored, never parsed.
///
/// It was a bare `String` under three names — `deviceID` in thirty-four places,
/// `watchID` in thirteen, and a plain `id` elsewhere — and the compiler had
/// nothing to say when one of them was handed an application's identifier or a
/// bundle identifier instead.
public struct WatchID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Without this `JSONEncoder` writes `[WatchID: [UUID]]` as an array of
/// alternating keys and values, because a dictionary whose key is not a string
/// or an integer has no object form. `application-sync.json` and the two
/// dictionaries in `TimelinePinStore` are keyed by watch, so every reader's
/// record of what their watches hold would have been silently orphaned the
/// first time it was written in the new shape and read in the old.
extension WatchID: CodingKeyRepresentable {
    public var codingKey: any CodingKey {
        Key(stringValue: rawValue)
    }

    public init?<Value: CodingKey>(codingKey: Value) {
        self.init(rawValue: codingKey.stringValue)
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}
