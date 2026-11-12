// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "SoundPing",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "SoundPingKit", targets: ["SoundPingKit"]),
    .executable(name: "soundping", targets: ["soundping"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
  ],
  targets: [
    .target(name: "SoundPingKit"),
    .executableTarget(
      name: "soundping",
      dependencies: [
        "SoundPingKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(name: "SoundPingKitTests", dependencies: ["SoundPingKit"]),
    .testTarget(name: "soundpingTests", dependencies: ["soundping", "SoundPingKit"]),
  ]
)
