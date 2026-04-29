// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetWatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NetWatch",
            path: "Sources/NetWatch",
            resources: [.process("Resources")]
        )
    ]
)
