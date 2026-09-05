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
    public var appKeys: [String: UInt32] = [:]
    public var hasCompanionJavaScript: Bool = false

    public var displayName: String {
        longName.isEmpty ? shortName : longName
    }

    public var isConfigurable: Bool {
        capabilities.contains("configurable") && hasCompanionJavaScript
    }

    private enum CodingKeys: String, CodingKey {
        case id, shortName, longName, companyName, versionCode, versionLabel
        case capabilities, targetPlatforms, kind, appKeys, hasCompanionJavaScript
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        shortName = try container.decode(String.self, forKey: .shortName)
        longName = try container.decode(String.self, forKey: .longName)
        companyName = try container.decode(String.self, forKey: .companyName)
        versionCode = try container.decodeIfPresent(Double.self, forKey: .versionCode)
        versionLabel = try container.decode(String.self, forKey: .versionLabel)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        targetPlatforms = try container.decode([String].self, forKey: .targetPlatforms)
        kind = try container.decode(PebbleApplicationKind.self, forKey: .kind)
        appKeys = try container.decodeIfPresent([String: UInt32].self, forKey: .appKeys) ?? [:]
        hasCompanionJavaScript = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCompanionJavaScript
        ) ?? false
    }

    public func bestVariant(for model: WatchModel) -> String? {
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
            kind: raw.watchapp?.watchface == true ? .watchface : .watchapp,
            appKeys: raw.appKeys ?? [:]
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
    var appKeys: [String: UInt32]?
}

private struct RawWatchapp: Decodable {
    var watchface: Bool?
}

public extension WatchModel {
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
