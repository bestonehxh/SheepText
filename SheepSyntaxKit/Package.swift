// swift-tools-version: 6.0
import PackageDescription

// SheepText's own syntax highlighter. Pure Swift, no C, no third-party code,
// no Foundation in the core: it reads UTF-16 code units and writes runs of
// `SyntaxScope`. The host app maps a scope onto its own palette.
//
// It replaced tree-sitter (runtime, Swift wrapper and 22 grammar packages).
// See README.md next to this file for the design.
let package = Package(
    name: "SheepSyntaxKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SheepSyntaxKit", targets: ["SheepSyntaxKit"])
    ],
    dependencies: [
        // network_config's literal values come from the scanner SheepTerm
        // shares. Used as is; nothing here changes it.
        .package(path: "../NetworkHighlightKit")
    ],
    targets: [
        .target(
            name: "SheepSyntaxKit",
            dependencies: ["NetworkHighlightKit"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SheepSyntaxKitTests",
            dependencies: ["SheepSyntaxKit"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
