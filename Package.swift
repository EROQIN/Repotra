// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Repotra",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Repotra", targets: ["Repotra"]),
    ],
    dependencies: [
        .package(path: "Vendor/MarkdownEngine"),
    ],
    targets: [
        .executableTarget(
            name: "Repotra",
            dependencies: [
                .product(name: "MarkdownEngine", package: "MarkdownEngine"),
                .product(name: "MarkdownEngineCodeBlocks", package: "MarkdownEngine"),
            ]
        ),
        .testTarget(
            name: "RepotraTests",
            dependencies: ["Repotra"]
        ),
    ]
)
