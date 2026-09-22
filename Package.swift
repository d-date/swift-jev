// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "swift-jev",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
    .tvOS(.v16),
    .watchOS(.v9),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "Jev", targets: ["Jev"]),
    .executable(name: "jev", targets: ["JevCLI"]),
  ],
  targets: [
    .target(name: "Jev"),
    .executableTarget(name: "JevCLI", dependencies: ["Jev"]),
    .testTarget(name: "JevCLITests", dependencies: ["JevCLI"]),
    .testTarget(
      name: "JevTests",
      dependencies: ["Jev"]
    ),
    .testTarget(
      name: "JevIntegrationTests",
      dependencies: ["Jev"]
    ),
  ]
)
