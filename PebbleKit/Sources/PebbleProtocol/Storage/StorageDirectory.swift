public import Foundation

/// Where the app keeps its own files.
///
/// One value passed down rather than a default inside each store, because each
/// store defaulting to the real Application Support directory meant every
/// `AppModel` in a process shared the same files. In the app there is one
/// model, so that was invisible; in the test suite, which Swift Testing runs
/// concurrently, two tests read and wrote the same queue — one test's queued
/// notification arrived at another's watch — and a full run overwrote the
/// reader's own notification history (#59).
public struct StorageDirectory: Hashable, Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var applicationSupport: StorageDirectory {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return StorageDirectory(url: base.appending(path: "Pebble", directoryHint: .isDirectory))
    }

    /// A directory of its own, for a test or a preview that must not touch what
    /// the reader has.
    public static func temporary() -> StorageDirectory {
        StorageDirectory(
            url: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        )
    }

    public func file(_ name: String) -> URL {
        url.appending(path: name, directoryHint: .notDirectory)
    }
}
