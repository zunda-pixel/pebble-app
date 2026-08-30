public import Foundation

/// A watch this phone is bonded to that the app has no record of, after being
/// forgotten or after the app was reinstalled while the bond survived.
///
/// It cannot be scanned for — a bonded Pebble stops advertising — so the only
/// way it becomes visible is by reconnecting and subscribing to the phone's
/// protocol service on its own. All that is known before connecting is the
/// identifier and the name the system holds for it; what it is comes from the
/// watch once a link is open.
public struct UnknownBondedWatch: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
