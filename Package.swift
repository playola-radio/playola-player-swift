// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PlayolaPlayer",
  platforms: [.iOS(.v18), .macOS(.v14), .tvOS(.v18)],
  products: [
    .library(name: "PlayolaPlayer", targets: ["PlayolaPlayer"]),
    .library(name: "PlayolaCore", targets: ["PlayolaCore"]),
  ],
  dependencies: [],
  targets: [
    .target(
      name: "PlayolaCore",
      resources: [.copy("MockData")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
      name: "PlayolaPlayer",
      dependencies: ["PlayolaCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "PlayolaCoreTests",
      dependencies: ["PlayolaCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "PlayolaPlayerTests",
      dependencies: ["PlayolaPlayer"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
