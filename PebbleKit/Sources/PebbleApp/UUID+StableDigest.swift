import CryptoKit
import Foundation

extension UUID {
    /// The first sixteen bytes of the SHA-256 of `name`: the same name is the
    /// same identifier on every reading and across launches, with no table to
    /// keep.
    ///
    /// `stampingVersion8` marks it a custom RFC 9562 UUID, so it can never
    /// collide with the random version-4 ones the rest of the app mints. It is
    /// not the default because the calendar and Reminders identifiers were
    /// minted without it, and stamping them now would give every record
    /// already on a watch a new name and orphan the old one there.
    init(stableDigestOf name: String, stampingVersion8: Bool = false) {
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        if stampingVersion8 {
            bytes[6] = (bytes[6] & 0x0F) | 0x80
            bytes[8] = (bytes[8] & 0x3F) | 0x80
        }
        self.init(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
