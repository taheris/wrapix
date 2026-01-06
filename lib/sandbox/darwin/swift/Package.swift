// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wrapix-runner",
    platforms: [.macOS(.v15)],
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
