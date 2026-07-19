import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Repotra Markdown extensions")
struct RepotraExtensionTests {
    @Test("leading YAML front matter is one source-preserving block")
    func frontMatterBlock() {
        let source = "---\ntitle: Note\ntags: [one, two]\n---\n\n# Heading\n"
        let blocks = BlockParser.parse(source)
        #expect(blocks.first?.kind == .frontMatter)
        #expect((source as NSString).substring(with: blocks.first!.range) == "---\ntitle: Note\ntags: [one, two]\n---\n")
        #expect(blocks.map(\.range.length).reduce(0, +) == (source as NSString).length)
    }

    @Test("unclosed leading delimiter remains a thematic break")
    func unclosedFrontMatter() {
        let blocks = BlockParser.parse("---\nbody")
        #expect(blocks.first?.kind == .thematicBreak)
    }

    @Test("footnotes and TOC only add display attributes")
    func extensionStylingPreservesSource() {
        let source = "[TOC]\n\nText[^one]\n\n[^one]: Definition\n"
        let attributes = MarkdownASTStyler.styleAttributes(
            text: source,
            fontName: "SF Pro",
            fontSize: 16
        )
        #expect(!attributes.isEmpty)
        #expect(source == "[TOC]\n\nText[^one]\n\n[^one]: Definition\n")
    }

    @Test("code block copy labels use the language or TEXT")
    func codeBlockDisplayLanguage() {
        let plain = CodeBlockSelection(id: 0, rect: .zero, language: nil, code: "hello")
        let swift = CodeBlockSelection(id: 1, rect: .zero, language: "swift", code: "let value = 1")
        #expect(plain.displayLanguage == "TEXT")
        #expect(swift.displayLanguage == "SWIFT")
    }
}
