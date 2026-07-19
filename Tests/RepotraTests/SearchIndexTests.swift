import Foundation
@testable import Repotra
import Testing

@Suite("SearchIndex")
struct SearchIndexTests {
    @Test("ranks title matches and returns snippets")
    func search() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        try Data("meeting notes about launch".utf8).write(to: library.url.appending(path: "Launch.md"))
        try Data("the launch appears in body".utf8).write(to: library.url.appending(path: "Other.md"))
        let index = SearchIndex()
        try await index.rebuild(rootURL: library.url)
        let results = await index.query("launch")
        #expect(results.count == 2)
        #expect(results.first?.relativePath == "Launch.md")
        #expect(results.first?.snippet.contains("launch") == true)
    }

    @Test("caches modification dates and Unicode character counts")
    func metrics() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let content = "# 你好\n👨‍👩‍👧‍👦"
        try Data(content.utf8).write(to: library.url.appending(path: "Unicode.md"))
        let index = SearchIndex()
        try await index.rebuild(rootURL: library.url)
        let metrics = await index.metrics()["Unicode.md"]
        #expect(metrics?.characterCount == content.count)
        #expect(metrics?.modifiedAt != .distantPast)
    }
}
