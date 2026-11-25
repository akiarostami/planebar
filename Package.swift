// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Planebar",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PlanebarCore"),
        .executableTarget(name: "Planebar", dependencies: ["PlanebarCore"]),
        .testTarget(name: "PlanebarCoreTests", dependencies: ["PlanebarCore"]),
    ],
    swiftLanguageModes: [.v5]
)
