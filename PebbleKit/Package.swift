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
    .package(url: "https://github.com/gohanlon/swift-memberwise-init-macro.git", from: "0.6.0"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
  ],
  targets: [
    .target(
      name: "UI",
      dependencies: [
        .target(name: "API"),
      ]
    ),
    .target(
      name: "API",
      dependencies: [
        .product(name: "MemberwiseInit", package: "swift-memberwise-init-macro"),
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
