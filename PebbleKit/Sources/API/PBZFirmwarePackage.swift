public import Foundation
import MemberwiseInit
import ZIPFoundation

@MemberwiseInit(.public)
public struct PBZBlob: Codable, Equatable, Sendable {
    public var name: String
    public var size: Int
    public var crc: UInt32
}

@MemberwiseInit(.public)
public struct PBZFirmwareManifest: Codable, Equatable, Sendable {
    public var manifestVersion: Int
    public var firmware: PBZFirmwareBlob
    public var resources: PBZBlob?
}

@MemberwiseInit(.public)
public struct PBZFirmwareBlob: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var hardwareRevision: String
    public var size: Int
    public var crc: UInt32
    public var versionTag: String?
    public var slot: Int?

    private enum CodingKeys: String, CodingKey {
        case name, type, size, crc, versionTag, slot
        case hardwareRevision = "hwrev"
    }
}

@MemberwiseInit(.public)
public struct PBZFirmwarePackage: Equatable, Sendable {
    public var manifest: PBZFirmwareManifest
    public var firmware: Data
    public var resources: Data?
}

public enum PBZFirmwareImporter {
    public static func load(from url: URL, for model: PebbleWatchModel) throws -> PBZFirmwarePackage {
        let archive = try Archive(url: url, accessMode: .read)
        let manifestEntries = archive.filter { $0.path.hasSuffix("manifest.json") }
        for entry in manifestEntries {
            let manifest = try JSONDecoder().decode(
                PBZFirmwareManifest.self,
                from: data(entry: entry, archive: archive)
            )
            guard manifest.firmware.hardwareRevision.caseInsensitiveCompare(model.rawValue) == .orderedSame else {
                continue
            }
            guard ["normal", "recovery"].contains(manifest.firmware.type),
                  manifest.firmware.size > 0,
                  manifest.firmware.crc > 0 else {
                throw PBZFirmwareError.unsafeManifest
            }
            let directory = (entry.path as NSString).deletingLastPathComponent
            let firmware = try data(path: joined(directory, manifest.firmware.name), archive: archive)
            try validate(firmware, blob: PBZBlob(
                name: manifest.firmware.name,
                size: manifest.firmware.size,
                crc: manifest.firmware.crc
            ))
            let resources = try manifest.resources.map {
                let value = try data(path: joined(directory, $0.name), archive: archive)
                try validate(value, blob: $0)
                return value
            }
            return PBZFirmwarePackage(manifest: manifest, firmware: firmware, resources: resources)
        }
        throw PBZFirmwareError.incompatibleHardware
    }

    private static func joined(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : "\(directory)/\(name)"
    }

    private static func data(path: String, archive: Archive) throws -> Data {
        guard let entry = archive[path] else { throw PBZFirmwareError.missingEntry(path) }
        return try data(entry: entry, archive: archive)
    }

    private static func data(entry: Entry, archive: Archive) throws -> Data {
        guard entry.uncompressedSize <= 64 * 1_024 * 1_024 else { throw PBZFirmwareError.entryTooLarge }
        var result = Data()
        _ = try archive.extract(entry) { result.append($0) }
        return result
    }

    private static func validate(_ data: Data, blob: PBZBlob) throws {
        guard data.count == blob.size else { throw PBZFirmwareError.sizeMismatch(blob.name) }
        guard PebbleCRC32.calculate([UInt8](data)) == blob.crc else {
            throw PBZFirmwareError.crcMismatch(blob.name)
        }
    }
}

public enum PBZFirmwareError: Error, Equatable, Sendable {
    case unsafeManifest
    case incompatibleHardware
    case missingEntry(String)
    case entryTooLarge
    case sizeMismatch(String)
    case crcMismatch(String)
}
