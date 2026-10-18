// swift-tools-version: 6.0

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
    name: "swift-sse",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SSE", targets: ["SSE"]),
        .library(name: "SSELLM", targets: ["SSELLM"]),
    ],
    targets: [
        .target(
            name: "SSE",
            swiftSettings: strictSettings
        ),
        .target(
            name: "SSELLM",
            dependencies: ["SSE"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "assemble-text",
            dependencies: ["SSE", "SSELLM"],
            path: "examples/assemble-text",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "sse-tail",
            dependencies: ["SSE"],
            path: "examples/sse-tail",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "sse-benchmark",
            dependencies: ["SSE", "SSELLM"],
            path: "Benchmarks/sse-benchmark",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SSETests",
            dependencies: ["SSE"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SSELLMTests",
            dependencies: ["SSE", "SSELLM"],
            swiftSettings: strictSettings
        ),
    ]
)
