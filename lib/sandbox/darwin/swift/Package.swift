// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "wrapix-runner",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "wrapix-runner",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedFramework("Containerization"),
                .linkedFramework("Virtualization"),
            ]
        ),
    ]
)
