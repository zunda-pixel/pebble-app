import MemberwiseInit

@MemberwiseInit(.public)
public struct PutBytesTransferProgress: Equatable, Sendable {
    public var bytesSent: Int
    public var totalBytes: Int
}

public enum PutBytesTransferAction: Equatable, Sendable {
    case send(PebbleProtocolFrame)
    case progress(PutBytesTransferProgress)
    case finished
}

public struct PutBytesTransferSession: Sendable {
    public var bytes: [UInt8]
    public var objectType: PutBytesObjectType
    public var appBankID: UInt32
    public var chunkSize: Int

    /// The name the watch files the object under. Only a `file` object has one,
    /// and it is what tells the firmware that a language pack is a language
    /// pack rather than any other file.
    public var filename: String?

    private var state: State = .ready
    private var crc: UInt32
    private var usesApplicationInitialization: Bool
    private var sendsInstall: Bool
    public private(set) var completedCookie: UInt32?

    public init(
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
        // A named file has to be installed as well as committed; the firmware
        // only moves it into place when the install command arrives.
        self.sendsInstall = self.usesApplicationInitialization || filename != nil
    }

    public mutating func start() throws -> PutBytesTransferAction {
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

    public mutating func receive(_ response: PutBytesResponse) throws -> [PutBytesTransferAction] {
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
            // The watch does not echo the transfer cookie in the install
            // acknowledgement, so only the ACK itself is meaningful here.
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

public enum PebbleCRC32 {
    public static func calculate(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        let alignedCount = bytes.count - bytes.count % 4
        var offset = 0
        while offset < alignedCount {
            let word = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            value = accumulate(word, into: value)
            offset += 4
        }
        if offset < bytes.count {
            // A trailing partial word is zero-padded on the left and then read
            // back little-endian, which reverses the remaining bytes. Packing
            // them in place instead produces a CRC the watch rejects.
            var word: UInt32 = 0
            for (index, byte) in bytes[offset...].reversed().enumerated() {
                word |= UInt32(byte) << (UInt32(index) * 8)
            }
            value = accumulate(word, into: value)
        }
        return value
    }

    private static func accumulate(_ word: UInt32, into value: UInt32) -> UInt32 {
        var value = value ^ word
        for _ in 0..<32 {
            value = value & 0x80000000 != 0
                ? value << 1 ^ 0x04C11DB7
                : value << 1
        }
        return value
    }
}
