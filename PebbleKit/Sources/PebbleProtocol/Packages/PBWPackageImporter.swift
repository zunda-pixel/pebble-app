public import Foundation
import MemberwiseInit
import ZIPFoundation

@MemberwiseInit(.public)
public struct PBWPackageObject: Equatable, Sendable {
    public var installationObject: PBWInstallationObject
    public var data: Data
}

@MemberwiseInit(.public)
public struct PBWPackage: Equatable, Sendable {
    public var application: WatchApplication
    public var variant: WatchPlatform
    public var binaryHeader: PBWBinaryHeader
    public var objects: [PBWPackageObject]

    public var appMetadata: ApplicationMetadata {
        binaryHeader.appMetadata(name: application.displayName)
    }
}

public enum PBWPackageImporter {
    private static var maximumEntrySize: UInt64 { 32 * 1_024 * 1_024 }

    public static func application(from url: URL) throws -> WatchApplication {
        let archive = try Archive(url: url, accessMode: .read)
        var application = try PBWApplicationDecoder.decodeAppInfo(
            from: data(for: "appinfo.json", in: archive)
        )
        application.hasCompanionJavaScript = archive["pebble-js-app.js"] != nil
        return application
    }

    public static func companionJavaScript(from url: URL) throws -> String? {
        let archive = try Archive(url: url, accessMode: .read)
        guard archive["pebble-js-app.js"] != nil else { return nil }
        let source = try data(for: "pebble-js-app.js", in: archive)
        guard let script = String(data: source, encoding: .utf8) else {
            throw PBWPackageImportError.invalidCompanionJavaScript
        }
        return script
    }

    public static func load(from url: URL, for model: WatchModel) throws -> PBWPackage {
        let archive = try Archive(url: url, accessMode: .read)
        let appInfoData = try data(for: "appinfo.json", in: archive)
        let application = try PBWApplicationDecoder.decodeAppInfo(from: appInfoData)

        var manifestsByVariant: [WatchPlatform: Data] = [:]
        for variant in model.compatiblePlatforms {
            if let manifestData = try optionalData(
                for: platformPath(variant: variant, filename: "manifest.json"),
                fallbackToRootForAplite: variant == .aplite,
                in: archive
            ) {
                manifestsByVariant[variant] = manifestData
            }
        }
        let plan = try PBWManifestDecoder.installationPlan(
            for: model,
            manifestsByVariant: manifestsByVariant
        )
        var objects: [PBWPackageObject] = []
        for installationObject in plan.objects {
            let blobData = try requiredPlatformData(
                variant: plan.variant,
                filename: installationObject.blob.name,
                in: archive
            )
            guard blobData.count == installationObject.blob.size else {
                throw PBWPackageImportError.sizeMismatch(filename: installationObject.blob.name)
            }
            objects.append(PBWPackageObject(
                installationObject: installationObject,
                data: blobData
            ))
        }
        guard let executable = objects.first(where: {
            $0.installationObject.objectType == .appExecutable
        }) else {
            throw PBWPackageImportError.missingExecutable
        }
        let binaryHeader = try PBWBinaryHeaderDecoder.decode(from: executable.data)
        guard binaryHeader.applicationID == application.id else {
            throw PBWPackageImportError.applicationIDMismatch
        }
        return PBWPackage(
            application: application,
            variant: plan.variant,
            binaryHeader: binaryHeader,
            objects: objects
        )
    }

    private static func requiredPlatformData(
        variant: WatchPlatform,
        filename: String,
        in archive: Archive
    ) throws -> Data {
        guard let data = try optionalData(
            for: platformPath(variant: variant, filename: filename),
            fallbackToRootForAplite: variant == .aplite,
            in: archive
        ) else {
            throw PBWPackageImportError.missingEntry(filename)
        }
        return data
    }

    private static func platformPath(variant: WatchPlatform, filename: String) -> String {
        "\(variant.rawValue)/\(filename)"
    }

    private static func optionalData(
        for path: String,
        fallbackToRootForAplite: Bool,
        in archive: Archive
    ) throws -> Data? {
        if archive[path] != nil {
            return try data(for: path, in: archive)
        }
        if fallbackToRootForAplite, archive[path.split(separator: "/").last.map(String.init) ?? path] != nil {
            return try data(
                for: path.split(separator: "/").last.map(String.init) ?? path,
                in: archive
            )
        }
        return nil
    }

    private static func data(for path: String, in archive: Archive) throws -> Data {
        guard let entry = archive[path] else {
            throw PBWPackageImportError.missingEntry(path)
        }
        guard entry.uncompressedSize <= maximumEntrySize else {
            throw PBWPackageImportError.entryTooLarge(path)
        }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            result.append(chunk)
        }
        return result
    }
}

public enum PBWPackageImportError: Error, Equatable, Sendable {
    case missingEntry(String)
    case entryTooLarge(String)
    case sizeMismatch(filename: String)
    case missingExecutable
    case applicationIDMismatch
    case invalidCompanionJavaScript
}
