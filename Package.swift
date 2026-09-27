// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZenMarky",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZenMarky", targets: ["ZenMarky"])],
    targets: [
        .executableTarget(name: "ZenMarky", resources: [.copy("Resources")]),
        .testTarget(name: "ZenMarkyTests", dependencies: ["ZenMarky"])
    ]
)
