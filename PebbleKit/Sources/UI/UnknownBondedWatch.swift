/// A watch this phone is bonded to that the app has no record of. It cannot be
/// scanned for — a bonded Pebble does not advertise — so it is noticed only
/// when it subscribes to the phone's protocol service.
public struct UnknownBondedWatch: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
