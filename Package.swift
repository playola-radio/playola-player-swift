// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "PlayolaPlayer",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "PlayolaPlayer", targets: ["PlayolaPlayer"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "PlayolaPlayer",
      resources: [.copy("MockData")]
    ),
    .testTarget(
      name: "PlayolaPlayerTests",
      dependencies: ["PlayolaPlayer"]
    ),
  ]
)
