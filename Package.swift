// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Repotra",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Repotra", targets: ["Repotra"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.8.0")),
    ],
    targets: [
        .executableTarget(
            name: "Repotra",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(
            name: "RepotraTests",
            dependencies: ["Repotra"]
        ),
    ]
)
