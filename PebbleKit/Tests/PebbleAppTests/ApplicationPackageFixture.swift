import Foundation
import ZIPFoundation
@testable import PebbleProtocol

/// A `.pbw` holding one application built for the Pebble Time 2, which is the
/// watch these tests connect to.
///
/// Shared rather than private to one suite: two suites now import a package,
/// and a second copy of the byte layout below would be a second thing to get
/// right when the importer changes.
func makeApplicationPackage(
    in directory: URL,
    applicationID: UUID,
    versionLabel: String
) throws -> URL {
    let url = directory.appending(path: "\(UUID().uuidString).pbw")
    let archive = try Archive(url: url, accessMode: .create)

    func add(_ path: String, _ data: Data) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }

    try add("appinfo.json", Data("""
    {
      "uuid": "\(applicationID.uuidString.lowercased())",
      "shortName": "Orbit",
      "longName": "Orbit",
      "companyName": "Pebble",
      "versionLabel": "\(versionLabel)",
      "targetPlatforms": ["emery"],
      "watchapp": { "watchface": false }
    }
    """.utf8))

    // The executable carries the identifier the importer checks the package
    // against, so its header has to name this application.
    var executable = [UInt8](repeating: 0, count: PBWBinaryHeaderDecoder.size)
    executable.replaceSubrange(0..<8, with: [0x50, 0x42, 0x4C, 0x41, 0x50, 0x50, 0, 0])
    executable.replaceSubrange(8..<14, with: [1, 0, 4, 2, 3, 7])
    let identifier = applicationID.uuid
    executable.replaceSubrange(104..<120, with: [
        identifier.0, identifier.1, identifier.2, identifier.3,
        identifier.4, identifier.5, identifier.6, identifier.7,
        identifier.8, identifier.9, identifier.10, identifier.11,
        identifier.12, identifier.13, identifier.14, identifier.15,
    ])
    try add("emery/pebble-app.bin", Data(executable))
    try add("emery/manifest.json", Data("""
    {
      "application": { "name": "pebble-app.bin", "size": \(executable.count) }
    }
    """.utf8))
    return url
}
