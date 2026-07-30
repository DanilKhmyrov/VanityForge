// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VanityForge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VanityForge",
            path: "Sources/VanityForge",
            resources: [
                .copy("Resources/Icons")
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
