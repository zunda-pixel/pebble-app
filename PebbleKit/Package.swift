// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .defaultIsolation(nil),
  .strictMemorySafety(),
  .treatAllWarnings(as: .error),
]

let package = Package(
  name: "PebbleKit",
  defaultLocalization: "en",
  platforms: [
    .macOS(.v27),
    .iOS(.v27),
  ],
  products: [
    .library(
      name: "PebbleKit",
      targets: ["PebbleApp"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    .package(url: "https://github.com/fumoboy007/swift-retry.git", from: "0.2.4"),
    .package(url: "https://github.com/mtj0928/swift-async-operations.git", from: "0.5.0"),
    .package(url: "https://github.com/square/Valet.git", from: "5.0.0"),
    .package(url: "https://github.com/sindresorhus/Defaults.git", from: "9.0.0"),
    .package(url: "https://github.com/gohanlon/swift-memberwise-init-macro.git", from: "0.6.0"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    // Speex, which no Apple framework decodes and the watch gives no
    // alternative to. See the note on `PebbleAudio` below.
    .package(url: "https://github.com/sbooth/CSpeex.git", from: "1.2.1"),
  ],
  targets: [
    // What the watch says, and what the phone says back: frames, PPoG, the
    // endpoint codecs, the package formats, and the values they carry. Nothing
    // here reaches for an Apple framework, so it holds on any platform and a
    // test of it needs no Bluetooth.
    .target(
      name: "PebbleProtocol",
      dependencies: [
        .product(name: "Algorithms", package: "swift-algorithms"),
        .product(name: "DequeModule", package: "swift-collections"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
        .product(name: "DMRetry", package: "swift-retry"),
        .product(name: "MemberwiseInit", package: "swift-memberwise-init-macro"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ],
      swiftSettings: swiftSettings
    ),
    // What the watch's microphone sent, turned back into samples.
    //
    // libspeex comes from sbooth/CSpeex, which packages the 1.2.1 release.
    // That release predates four upstream fixes, and two of them are on paths
    // every session here takes: a division by zero in the wideband decoder the
    // watch records with, and undefined behaviour in the bit reader. See issue
    // #41 before raising the lower bound or reading a crash report.
    .target(
      name: "PebbleAudio",
      dependencies: [
        .target(name: "PebbleProtocol"),
        .product(name: "speex", package: "CSpeex"),
      ],
      swiftSettings: swiftSettings
    ),
    // How those bytes reach a watch: CoreBluetooth in both roles, the emulator's
    // socket, and the mock a test or a preview stands in.
    .target(
      name: "PebbleTransport",
      dependencies: [
        .target(name: "PebbleProtocol"),
        .product(name: "DequeModule", package: "swift-collections"),
      ],
      swiftSettings: swiftSettings
    ),
    // The app: the model, the screens, and the phone's own frameworks.
    .target(
      name: "PebbleApp",
      dependencies: [
        .target(name: "PebbleAudio"),
        .target(name: "PebbleProtocol"),
        .target(name: "PebbleTransport"),
        .product(name: "Algorithms", package: "swift-algorithms"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "AsyncOperations", package: "swift-async-operations"),
        .product(name: "Defaults", package: "Defaults"),
        .product(name: "DMRetry", package: "swift-retry"),
        .product(name: "Valet", package: "Valet"),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "PebbleProtocolTests",
      dependencies: [
        "PebbleAudio",
        "PebbleProtocol",
        "PebbleTransport",
        .product(name: "HTTPTypes", package: "swift-http-types"),
        // The encoder, so a test can make the frames a watch would have sent.
        .product(name: "speex", package: "CSpeex"),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "PebbleAppTests",
      dependencies: [
        "PebbleApp",
        "PebbleProtocol",
        "PebbleTransport",
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
