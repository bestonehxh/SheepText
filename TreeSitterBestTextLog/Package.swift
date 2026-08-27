// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "TreeSitterBestTextLog",
    products: [
        .library(name: "TreeSitterBestTextLog", targets: ["TreeSitterBestTextLog"]),
    ],
    targets: [
        .target(
            name: "TreeSitterBestTextLog",
            dependencies: [],
            path: ".",
            sources: [
                "src/parser.c",
            ],
            resources: [
                .copy("queries")
            ],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
