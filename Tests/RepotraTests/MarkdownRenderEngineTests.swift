import AppKit
@testable import Repotra
import Testing

@MainActor
@Suite("MarkdownRenderEngine")
struct MarkdownRenderEngineTests {
    @Test("active block stays source while inactive block renders")
    func fusionRendering() {
        let source = "# Heading\n\n**Bold** and [link](https://example.com)\n"
        let engine = MarkdownRenderEngine()
        let rendered = engine.render(source: source, activeLocation: 0, rootURL: nil)
        #expect(rendered.segments.count == 2)
        #expect(rendered.segments[0].isActive)
        #expect(rendered.attributedString.string.hasPrefix("# Heading"))
        #expect(rendered.attributedString.string.contains("Bold and link"))
        #expect(source == "# Heading\n\n**Bold** and [link](https://example.com)\n")
    }

    @Test("GFM table has a rendered inactive representation")
    func tableRendering() {
        let source = "Intro\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
        let rendered = MarkdownRenderEngine().render(source: source, activeLocation: 0, rootURL: nil)
        #expect(rendered.attributedString.string.contains("A\t│\tB"))
        #expect(!rendered.attributedString.string.contains("|---|"))
    }
}
