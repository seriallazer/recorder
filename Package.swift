// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Recorder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Recorder", targets: ["RecorderApp"]),
        .library(name: "RecorderCore", targets: ["RecorderCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .target(
            name: "RecorderCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RecorderApp",
            dependencies: ["RecorderCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RecorderCoreTests",
            dependencies: ["RecorderCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
