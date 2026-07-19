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
    @Test("500 KB Markdown document updates without source rewriting")
    func largeDocumentOpening() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let path = try await store.createNote(in: nil, title: "Large")
        let session = NoteSession(snapshot: try await store.readNote(at: path), store: store)
        let paragraph = "## Heading\n\nA paragraph with **bold**, *emphasis*, and [link](https://example.com).\n\n"
        let source = String(repeating: paragraph, count: 6000)
        #expect(source.utf8.count > 500_000)
        let start = CFAbsoluteTimeGetCurrent()
        session.updateContent(source)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        #expect(session.content == source)
        #expect(elapsed < 0.1, "Source update took \(elapsed) seconds")
    }
}
