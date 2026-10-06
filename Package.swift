// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harbor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Harbor", targets: ["Harbor"])],
    targets: [
        .target(name: "HarborCore"),
        .executableTarget(name: "Harbor", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborCoreTests", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborAppTests", dependencies: ["Harbor", "HarborCore"])
    ],
    swiftLanguageModes: [.v5]
)
