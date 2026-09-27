public import PebbleProtocol
public import Foundation

/// What the phone asks the watch for, handed on to the session that asks it:
/// the BlobDB writes, the transfers and a firmware install, the app order, and
/// the three longer answers.
extension CoreBluetoothWatchClient {
    public func reorderApplications(_ applicationIDs: [UUID]) async throws {
        try await session.reorderApplications(applicationIDs)
    }

    public func write(_ record: BlobDBRecord) async throws {
        try await session.write(record)
    }

    public func remove(_ key: BlobDBKey) async throws {
        try await session.remove(key)
    }

    public func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {
        try await session.installApplicationObject(bytes, objectType: objectType, appBankID: appBankID)
    }

    public func installFile(_ bytes: [UInt8], filename: String) async throws {
        try await session.installFile(bytes, filename: filename)
    }

    public func installFirmware(_ package: PBZFirmwarePackage) async throws {
        try await session.installFirmware(package)
    }

    public func pull(_ request: WatchPullRequest) async throws -> WatchPullAnswer {
        try await session.pull(request)
    }
}
