public import Foundation
import MemberwiseInit

public enum WatchApplicationKind: String, Codable, Equatable, Sendable {
    case watchapp
    case watchface
}

/// Something a watch application says it uses, as its package and the store's
/// row both spell it.
///
/// A declaration and nothing more. It does not mean the phone has been given
/// the matching permission, or that this app can serve it — which is why the
/// screen that shows these says so rather than drawing them as switches.
///
/// `configurable` is not one of these. It is already the settings button, and
/// unlike the three below it asks nothing of the phone; the official app
/// leaves it out of its own list for the same reason.
public enum WatchApplicationCapability: Equatable, Hashable, Sendable {
    case health
    case location
    case timeline
    /// A code neither this app nor the reference knows. Kept rather than
    /// dropped: a package saying it wants something unrecognised is worth
    /// seeing, and the store adds codes on its own schedule.
    case other(String)

    public init(code: String) {
        switch code {
        case "health": self = .health
        case "location": self = .location
        case "timeline": self = .timeline
        default: self = .other(code)
        }
    }

    public var code: String {
        switch self {
        case .health: "health"
        case .location: "location"
        case .timeline: "timeline"
        case .other(let code): code
        }
    }

    /// The declared capabilities of a package or a store row, in the order
    /// above so that two applications list them the same way, and without the
    /// codes that are not capabilities.
    public static func declared(in codes: [String]) -> [Self] {
        let known: [Self] = [.health, .location, .timeline]
        let declared = codes.map(Self.init(code:))
        return known.filter(declared.contains)
            + declared.compactMap { if case .other = $0 { $0 } else { nil } }
                .filter { $0 != .other("configurable") }
    }
}

@MemberwiseInit(.public)
public struct WatchApplication: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var shortName: String
    public var longName: String
    public var companyName: String
    public var versionCode: Double?
    public var versionLabel: String
    public var capabilities: [String]
    public var targetPlatforms: [String]
    public var kind: WatchApplicationKind
    public var appKeys: [String: UInt32] = [:]
    public var hasCompanionJavaScript: Bool = false

    public var displayName: String {
        longName.isEmpty ? shortName : longName
    }

    public var isConfigurable: Bool {
        capabilities.contains("configurable") && hasCompanionJavaScript
    }

    public var declaredCapabilities: [WatchApplicationCapability] {
        WatchApplicationCapability.declared(in: capabilities)
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
        kind = try container.decode(WatchApplicationKind.self, forKey: .kind)
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
    public static func decodeAppInfo(from data: Data) throws -> WatchApplication {
        let raw = try JSONDecoder().decode(RawAppInfo.self, from: data)
        guard let id = UUID(uuidString: raw.uuid) else {
            throw PBWApplicationError.invalidUUID
        }
        return WatchApplication(
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
