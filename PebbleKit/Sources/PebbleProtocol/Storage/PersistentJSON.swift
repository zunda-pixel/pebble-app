import Foundation

enum PersistentJSON {
    static var maximumFileSize: Int { 64 * 1_024 * 1_024 }

    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try validateFileSize(at: url)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    /// Written so that a person diagnosing a fault can read the file: these are
    /// the only account of what the app believed, and the one that gets sent in
    /// when something has gone wrong.
    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func loadRecovering<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try validateFileSize(at: url)
        } catch {
            try quarantine(url)
            return nil
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch is DecodingError {
            try quarantine(url)
            return nil
        }
    }

    static func quarantine(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backupURL = url
            .deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).corrupt-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: backupURL)
    }

    static func validateFileSize(at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileSize else { throw CocoaError(.fileReadTooLarge) }
    }
}

