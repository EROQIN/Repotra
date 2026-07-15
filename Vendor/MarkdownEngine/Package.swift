// swift-tools-version: 5.9
import PackageDescription

// MarkdownEngine — a TextKit-2 backed Markdown editor view for macOS.
//
// Embedders import `MarkdownEngine` and supply their own adapters that
// conform to the engine's service protocols (`WikiLinkResolver`,
// `EmbeddedImageProvider`, `SyntaxHighlighter`, `LatexRenderer`). The engine
// itself has zero external dependencies.
//
// Users who want turnkey adapters for the two highest-friction protocols
// (code-block styling/highlighting, LaTeX rendering) can additionally
// depend on the `MarkdownEngineCodeBlocks` product, which ships a pre-built
// bridge backed by HighlighterSwift. Repotra intentionally excludes the
// upstream LaTeX product from its vendored package.
let package = Package(
    name: "MarkdownEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"]),
        .library(name: "MarkdownEngineCodeBlocks", targets: ["MarkdownEngineCodeBlocks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/smittytone/HighlighterSwift", exact: "3.1.0"),
    ],
    targets: [
        .target(name: "MarkdownEngine"),
        .target(
            name: "MarkdownEngineCodeBlocks",
            dependencies: [
                "MarkdownEngine",
                .product(name: "Highlighter", package: "HighlighterSwift"),
            ]
        ),
        .testTarget(
            name: "MarkdownEngineTests",
            dependencies: ["MarkdownEngine"]
        )
    ]
)
