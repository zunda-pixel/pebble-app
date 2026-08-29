// swift-tools-version: 6.4

import PackageDescription

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
      targets: ["UI"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-http-api-proposal.git", branch: "main"),
    .package(url: "https://github.com/square/Valet.git", from: "5.0.0"),
    .package(url: "https://github.com/sindresorhus/Defaults.git", from: "9.0.0"),
    .package(url: "https://github.com/gohanlon/swift-memberwise-init-macro.git", from: "0.6.0"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    .package(url: "https://github.com/vapor/multipart-kit.git", exact: "5.0.0-alpha.5"),
    .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    .package(url: "https://github.com/zunda-pixel/swift-currency.git", from: "0.0.1"),
  ],
  targets: [
    .target(
      name: "UI",
      dependencies: [
        .target(name: "API"),
        .product(name: "Valet", package: "Valet"),
        .product(name: "Defaults", package: "Defaults"),
        .product(name: "DefaultsMacros", package: "Defaults"),
        .product(name: "MultipartKit", package: "multipart-kit"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .target(
      name: "API",
      dependencies: [
        .product(name: "HTTPClient", package: "swift-http-api-proposal"),
        .product(name: "MemberwiseInit", package: "swift-memberwise-init-macro"),
        .product(name: "Currency", package: "swift-currency"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ],
      swiftSettings: [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .defaultIsolation(nil),
        .strictMemorySafety(),
      ],
    ),
    .testTarget(
      name: "APITests",
      dependencies: ["API"],
      swiftSettings: [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .defaultIsolation(nil),
        .strictMemorySafety(),
      ],
    ),
    .testTarget(
      name: "UITests",
      dependencies: [
        "UI",
        "API",
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ],
      swiftSettings: [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .defaultIsolation(nil),
        .strictMemorySafety(),
      ],
    ),
  ],
  swiftLanguageModes: [.v6]
)
