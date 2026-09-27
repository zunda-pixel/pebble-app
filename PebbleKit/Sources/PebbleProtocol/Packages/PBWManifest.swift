public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct PBWSDKVersion: Codable, Equatable, Sendable {
    public var major: Int?
    public var minor: Int?
}

@MemberwiseInit(.public)
public struct PBWBlob: Codable, Equatable, Sendable {
    public var crc: UInt32?
    public var name: String
    public var sdkVersion: PBWSDKVersion?
    public var size: Int
    public var timestamp: Int?

    private enum CodingKeys: String, CodingKey {
        case crc
        case name
        case sdkVersion = "sdk_version"
        case size
        case timestamp
    }
}

@MemberwiseInit(.public)
public struct PBWManifest: Codable, Equatable, Sendable {
    public var application: PBWBlob
    public var resources: PBWBlob?
    public var worker: PBWBlob?
    public var generatedAt: Int?
    public var generatedBy: String?
    public var manifestVersion: Int?
    public var type: String?
}

@MemberwiseInit(.public)
public struct PBWInstallationObject: Equatable, Sendable {
    public var blob: PBWBlob
    public var objectType: PutBytesObjectType
}

@MemberwiseInit(.public)
public struct PBWInstallationPlan: Equatable, Sendable {
    public var variant: WatchPlatform
    public var objects: [PBWInstallationObject]
}

public enum PBWManifestDecoder {
    public static func decode(from data: Data) throws -> PBWManifest {
        let manifest = try JSONDecoder().decode(PBWManifest.self, from: data)
        try validate(manifest.application)
        if let resources = manifest.resources {
            try validate(resources)
        }
        if let worker = manifest.worker {
            try validate(worker)
        }
        return manifest
    }

    public static func installationPlan(
        for model: WatchModel,
        manifestsByVariant: [WatchPlatform: Data]
    ) throws -> PBWInstallationPlan {
        for variant in model.compatiblePlatforms {
            guard let data = manifestsByVariant[variant] else {
                continue
            }
            let manifest = try decode(from: data)
            var objects = [PBWInstallationObject(
                blob: manifest.application,
                objectType: .appExecutable
            )]
            if let resources = manifest.resources {
                objects.append(PBWInstallationObject(blob: resources, objectType: .appResource))
            }
            if let worker = manifest.worker {
                objects.append(PBWInstallationObject(blob: worker, objectType: .worker))
            }
            return PBWInstallationPlan(variant: variant, objects: objects)
        }
        throw PBWManifestError.noCompatibleVariant
    }

    private static func validate(_ blob: PBWBlob) throws {
        guard !blob.name.isEmpty, blob.size >= 0 else {
            throw PBWManifestError.invalidBlob
        }
    }
}

public enum PBWManifestError: Error, Equatable, Sendable {
    case invalidBlob
    case noCompatibleVariant
}
