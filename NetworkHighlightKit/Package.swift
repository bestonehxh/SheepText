// swift-tools-version: 6.0
import PackageDescription

// Network-device highlighting shared between SheepText (editor) and SheepTerm
// (terminal). Foundation only: no AppKit, no SwiftUI, no colours — the host
// app maps a `NetworkRule` onto its own token palette.
let package = Package(
    name: "NetworkHighlightKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetworkHighlightKit", targets: ["NetworkHighlightKit"])
    ],
    targets: [
        .target(
            name: "NetworkHighlightKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "NetworkHighlightKitTests",
            dependencies: ["NetworkHighlightKit"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
