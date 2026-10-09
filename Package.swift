// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Mogu", platforms: [.macOS(.v13)], products: [.library(name: "MoguCore", targets: ["MoguCore"])], targets: [.target(name: "MoguCore"), .testTarget(name: "MoguCoreTests", dependencies: ["MoguCore"])])
