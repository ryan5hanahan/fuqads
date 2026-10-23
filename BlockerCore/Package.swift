// swift-tools-version: 6.0
import PackageDescription

// BlockerCore: filter-list storage, ABP→Safari compilation with sharding,
// content-blocker reload, and the per-site policy model (SPEC §4, §6).
let package = Package(
    name: "BlockerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlockerCore", targets: ["BlockerCore"]),
        .executable(name: "blocker-cli", targets: ["BlockerCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", exact: "4.3.1"),
        .package(url: "https://github.com/ameshkov/swift-psl", "1.1.0"..<"2.0.0"),
    ],
    targets: [
        .target(
            name: "BlockerCore",
            dependencies: [
                .product(name: "ContentBlockerConverter", package: "SafariConverterLib"),
                .product(name: "PublicSuffixList", package: "swift-psl"),
            ]
        ),
        .executableTarget(
            name: "BlockerCLI",
            dependencies: ["BlockerCore"]
        ),
        .testTarget(
            name: "BlockerCoreTests",
            dependencies: ["BlockerCore"]
        ),
    ]
)
