import MemberwiseInit

@MemberwiseInit(.public)
public struct PutBytesTransferProgress: Equatable, Sendable {
    public var bytesSent: Int
    public var totalBytes: Int
}

package enum PutBytesTransferAction: Equatable, Sendable {
    case send(PebbleProtocolFrame)
    case progress(PutBytesTransferProgress)
    case finished
}

package struct PutBytesTransferSession: Sendable {
    package var bytes: [UInt8]
    package var objectType: PutBytesObjectType
    package var appBankID: UInt32
    package var chunkSize: Int

    /// Only a `file` object has one, and it is what tells the firmware that a
    /// language pack is a language pack rather than an unknown blob.
    package var filename: String?

    private var state: State = .ready
    private var crc: UInt32
    private var usesApplicationInitialization: Bool
    private var sendsInstall: Bool
    package private(set) var completedCookie: UInt32?

    package init(
        bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32,
        filename: String? = nil,
        chunkSize: Int = 2_000
    ) {
        self.bytes = bytes
        self.objectType = objectType
        self.appBankID = appBankID
        self.filename = filename
        self.chunkSize = chunkSize
        self.crc = PebbleCRC32.calculate(bytes)
        self.usesApplicationInitialization = [.appResource, .appExecutable, .worker].contains(objectType)
        // The firmware only moves a named file into place when the install command
        // arrives.
        self.sendsInstall = self.usesApplicationInitialization || filename != nil
    }

    package mutating func start() throws -> PutBytesTransferAction {
        guard state == .ready else {
            throw PutBytesTransferError.invalidState
        }
        guard chunkSize > 0, let size = UInt32(exactly: bytes.count) else {
            throw PutBytesTransferError.invalidConfiguration
        }
        state = .awaitingInitialization
        if let filename {
            return .send(try PutBytesCodec.fileInitializationFrame(
                objectSize: size,
                filename: filename,
                bank: UInt8(truncatingIfNeeded: appBankID)
            ))
        }
        return .send(usesApplicationInitialization
            ? PutBytesCodec.appInitializationFrame(objectSize: size, objectType: objectType, appBankID: appBankID)
            : PutBytesCodec.systemInitializationFrame(objectSize: size, objectType: objectType, bank: UInt8(truncatingIfNeeded: appBankID)))
    }

    package mutating func receive(_ response: PutBytesResponse) throws -> [PutBytesTransferAction] {
        guard response.result == .acknowledgement else {
            state = .failed
            throw PutBytesTransferError.negativeAcknowledgement
        }

        switch state {
        case .awaitingInitialization:
            if bytes.isEmpty {
                state = .awaitingCommit(cookie: response.cookie)
                return [.send(PutBytesCodec.commitFrame(cookie: response.cookie, crc: crc))]
            }
            return try sendNextChunk(cookie: response.cookie, offset: 0)
        case .sending(let cookie, let offset):
            guard response.cookie == cookie else {
                throw PutBytesTransferError.unexpectedCookie
            }
            let progress = PutBytesTransferProgress(bytesSent: offset, totalBytes: bytes.count)
            if offset < bytes.count {
                return [.progress(progress)] + (try sendNextChunk(cookie: cookie, offset: offset))
            }
            state = .awaitingCommit(cookie: cookie)
            return [
                .progress(progress),
                .send(PutBytesCodec.commitFrame(cookie: cookie, crc: crc)),
            ]
        case .awaitingCommit(let cookie):
            guard response.cookie == cookie else {
                throw PutBytesTransferError.unexpectedCookie
            }
            if sendsInstall {
                state = .awaitingInstall(cookie: cookie)
                return [.send(PutBytesCodec.installFrame(cookie: cookie))]
            }
            state = .finished
            completedCookie = cookie
            return [.finished]
        case .awaitingInstall(let cookie):
            // The watch does not echo the transfer cookie in the install acknowledgement.
            state = .finished
            completedCookie = cookie
            return [.finished]
        case .ready, .finished, .failed:
            throw PutBytesTransferError.invalidState
        }
    }

    private mutating func sendNextChunk(cookie: UInt32, offset: Int) throws -> [PutBytesTransferAction] {
        let end = min(offset + chunkSize, bytes.count)
        state = .sending(cookie: cookie, offset: end)
        return [.send(try PutBytesCodec.putFrame(cookie: cookie, bytes: Array(bytes[offset..<end])))]
    }

    private enum State: Equatable, Sendable {
        case ready
        case awaitingInitialization
        case sending(cookie: UInt32, offset: Int)
        case awaitingCommit(cookie: UInt32)
        case awaitingInstall(cookie: UInt32)
        case finished
        case failed
    }
}

public enum PutBytesTransferError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidState
    case negativeAcknowledgement
    case unexpectedCookie
}
