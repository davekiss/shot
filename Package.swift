// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "shot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "shot", path: "Sources/shot"),
        .testTarget(name: "shotTests", dependencies: ["shot"], path: "Tests/shotTests"),
    ]
)
