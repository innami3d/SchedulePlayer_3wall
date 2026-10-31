// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GeoBoxPlayer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "GeoBoxPlayer", targets: ["GeoBoxPlayer"])],
    targets: [
        .target(name: "PlayerCore"),
        .executableTarget(name: "GeoBoxPlayer", dependencies: ["PlayerCore"]),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"])
    ],
    swiftLanguageModes: [.v5]
)
