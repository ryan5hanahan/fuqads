// swift-tools-version: 6.0
import PackageDescription

// S1 spike: does SafariConverterLib convert the default filter lists within
// the 150k rules/shard budget and < 30 s? Answers PLAN Phase 0 S1.
let package = Package(
    name: "S1Converter",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", exact: "4.3.1")
    ],
    targets: [
        .executableTarget(
            name: "S1Converter",
            dependencies: [
                .product(name: "ContentBlockerConverter", package: "SafariConverterLib")
            ]
        )
    ]
)
