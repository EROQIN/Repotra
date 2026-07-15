import CoreFoundation
import Foundation
@testable import Repotra
import Testing

@Suite("Performance acceptance")
struct PerformanceTests {
    @Test("search returns first results within 200 ms for 5,000 notes")
    func searchFiveThousandNotes() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        for index in 0 ..< 5000 {
            let text = index == 4999 ? "needle launch plan" : "ordinary note \(index)"
            try Data(text.utf8).write(to: library.url.appending(path: "Note-\(index).md"))
        }
        let index = SearchIndex()
        try await index.rebuild(rootURL: library.url)
        let start = CFAbsoluteTimeGetCurrent()
        let results = await index.query("needle")
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        #expect(results.first?.relativePath == "Note-4999.md")
        #expect(elapsed < 0.2, "Search took \(elapsed) seconds")
    }

    @MainActor
    @Test("500 KB Markdown document renders within a bounded opening time")
    func largeDocumentOpening() {
        let paragraph = "## Heading\n\nA paragraph with **bold**, *emphasis*, and [link](https://example.com).\n\n"
        let source = String(repeating: paragraph, count: 6000)
        #expect(source.utf8.count > 500_000)
        let start = CFAbsoluteTimeGetCurrent()
        let rendered = MarkdownRenderEngine().render(source: source, activeLocation: 0, rootURL: nil)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        #expect(rendered.segments.count > 5000)
        #expect(elapsed < 3.0, "Initial render took \(elapsed) seconds")
    }
}
