/// Something that gathers one of the watch's longer answers as it arrives in
/// pieces, and hands back the whole once the last piece lands.
public protocol WatchPullCollector: Sendable {
    associatedtype Value: Sendable

    /// The finished value, or `nil` while more is still coming.
    mutating func accept(_ frame: PebbleProtocolFrame) throws -> Value?
}
