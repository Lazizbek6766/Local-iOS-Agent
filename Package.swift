// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalIOSAgent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LocalIOSAgent", targets: ["LocalIOSAgent"])
    ],
    targets: [
        .executableTarget(
            name: "LocalIOSAgent",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LocalIOSAgentTests",
            dependencies: ["LocalIOSAgent"]
        )
    ]
)
