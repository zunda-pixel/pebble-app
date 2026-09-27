import Foundation

/// The watch sends and expects a UUID as its sixteen bytes in string order —
/// `uuid_t`'s order — in every endpoint and every BlobDB key.
extension UUID {
    var bytes: [UInt8] {
        let value = uuid
        return [
            value.0, value.1, value.2, value.3, value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11, value.12, value.13, value.14, value.15,
        ]
    }

    /// Nil for anything other than exactly sixteen bytes.
    init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 16 else { return nil }
        let value = Array(bytes)
        self.init(uuid: (
            value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]
        ))
    }
}
