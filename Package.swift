// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "CloudSaveKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(
            name: "CloudSaveKit",
            targets: ["CloudSaveKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/thatfactory/applogger", from: "1.1.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CloudSaveKit",
            dependencies: [
                .product(
                    name: "AppLogger",
                    package: "applogger"
                ),
            ]
        ),
        .testTarget(
            name: "CloudSaveKitTests",
            dependencies: ["CloudSaveKit"]
        ),
    ]
)
