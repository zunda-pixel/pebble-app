public import Foundation
import MemberwiseInit

public enum PebbleApplicationKind: String, Codable, Equatable, Sendable {
    case watchapp
    case watchface
}

@MemberwiseInit(.public)
public struct PebbleApplication: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var shortName: String
    public var longName: String
    public var companyName: String
    public var versionCode: Double?
    public var versionLabel: String
    public var capabilities: [String]
    public var targetPlatforms: [String]
    public var kind: PebbleApplicationKind

    public var displayName: String {
        longName.isEmpty ? shortName : longName
    }

    public func bestVariant(for model: PebbleWatchModel) -> String? {
        model.compatibleApplicationVariants.first { targetPlatforms.contains($0) }
    }
}

public enum PBWApplicationDecoder {
    public static func decodeAppInfo(from data: Data) throws -> PebbleApplication {
        let raw = try JSONDecoder().decode(RawAppInfo.self, from: data)
        guard let id = UUID(uuidString: raw.uuid) else {
            throw PBWApplicationError.invalidUUID
        }
        return PebbleApplication(
            id: id,
            shortName: raw.shortName,
            longName: raw.longName ?? "",
            companyName: raw.companyName ?? "",
            versionCode: raw.versionCode,
            versionLabel: raw.versionLabel,
            capabilities: raw.capabilities ?? [],
            targetPlatforms: raw.targetPlatforms ?? ["aplite"],
            kind: raw.watchapp?.watchface == true ? .watchface : .watchapp
        )
    }
}

public enum PBWApplicationError: Error, Equatable, Sendable {
    case invalidUUID
}

private struct RawAppInfo: Decodable {
    var uuid: String
    var shortName: String
    var longName: String?
    var companyName: String?
    var versionCode: Double?
    var versionLabel: String
    var capabilities: [String]?
    var targetPlatforms: [String]?
    var watchapp: RawWatchapp?
}

private struct RawWatchapp: Decodable {
    var watchface: Bool?
}

public extension PebbleWatchModel {
    var compatibleApplicationVariants: [String] {
        switch self {
        case .pebble2Duo:
            ["flint", "diorite", "aplite"]
        case .pebbleTime2:
            ["emery", "basalt", "diorite", "aplite"]
        case .pebbleRound2:
            ["gabbro", "chalk"]
        }
    }
}
