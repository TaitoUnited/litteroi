// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "litteroi",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LitteroiCore", targets: ["LitteroiCore"]),
        .library(name: "LitteroiMeetings", targets: ["LitteroiMeetings"]),
        .library(name: "LitteroiWatch", targets: ["LitteroiWatch"]),
        .executable(name: "litteroi-cli", targets: ["LitteroiCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "LitteroiCore",
            dependencies: [
                "CSpeexDSP",
                "LitteroiMeetings",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ]
        ),
        .executableTarget(
            name: "LitteroiCLI",
            dependencies: [
                "LitteroiCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "CSpeexDSP",
            exclude: ["COPYING"],
            cSettings: [
                .define("FLOATING_POINT"),
                .define("USE_SMALLFT"),
                .define("EXPORT", to: ""),
            ]
        ),
        .target(name: "LitteroiMeetings"),
        .target(name: "LitteroiWatch"),
        .testTarget(name: "LitteroiCoreTests", dependencies: ["LitteroiCore"]),
        .testTarget(name: "LitteroiWatchTests", dependencies: ["LitteroiWatch"]),
    ],
    swiftLanguageModes: [.v5]
)
