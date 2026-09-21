public import PebbleProtocol
public import Foundation
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// What an arriving link is waiting on: nothing here moves bytes by itself —
/// a package sits as `pendingPackage` until the reader looks at what it is
/// and says install, and it survives there through launch and connection,
/// so a link opened before the watch was ready is not lost.
@MainActor
@Observable
public final class DeepLinksModel {
    public internal(set) var pendingPackage: PendingDeepLinkPackage?
    /// A store row a link asked for, resolved through the feed.
    public internal(set) var storeApplication: CatalogApplication?
    /// A tab a link asked for; the root view consumes it and puts it back to nil.
    public internal(set) var requestedSection: AppSection?
    public internal(set) var isPreparing = false
    public internal(set) var feedback: FeatureFeedback?
}

/// A package a link offered, fetched and read but not yet sent anywhere. The
/// title and version are what the package itself says it is — the reader
/// confirms against that, not against the URL's promise.
public struct PendingDeepLinkPackage: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: PebbleDeepLink.PackageKind
    public var fileName: String
    /// The app's own copy in its temporary directory: what was inspected is
    /// what will be installed, and a file that changes under the sheet cannot
    /// swap itself in.
    public var localURL: URL
    public var title: String?
    public var subtitle: String?
    public var byteCount: Int
}
