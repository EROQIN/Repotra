import Foundation
@testable import Repotra
import Testing

@MainActor
@Suite("NoteSession")
struct NoteSessionTests {
    @Test("external modification never gets silently overwritten")
    func externalConflict() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let path = try await store.createNote(in: nil, title: "Conflict")
        let snapshot = try await store.readNote(at: path)
        let session = NoteSession(snapshot: snapshot, store: store)
        session.updateContent("local draft")
        try Data("external edit".utf8).write(to: library.url.appending(path: path), options: .atomic)
        await session.saveNow()
        #expect(session.conflict?.kind == .modified)
        #expect(session.isDirty)
        #expect(try String(decoding: Data(contentsOf: library.url.appending(path: path)), as: UTF8.self) == "external edit")
    }

    @Test("main and sticky views can share one session")
    func sharedSession() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let path = try await store.createNote(in: nil, title: "Shared")
        let snapshot = try await store.readNote(at: path)
        let session = NoteSession(snapshot: snapshot, store: store)
        let sameReference = session
        session.updateContent("from main")
        #expect(sameReference.content == "from main")
        sameReference.updateContent("from sticky")
        #expect(session.content == "from sticky")
    }

    @Test("outline refreshes after the debounce without reopening the note")
    func liveOutline() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let path = try await store.createNote(in: nil, title: "Outline")
        let session = NoteSession(snapshot: try await store.readNote(at: path), store: store)
        #expect(session.outline.isEmpty)
        session.updateContent("# 实时标题\n\n正文")
        // The product debounce is 80 ms, but a fixed 120 ms assertion is
        // vulnerable to main-actor scheduling delays when the full engine suite
        // has just run. Poll with a bounded timeout so this verifies the outcome
        // instead of the test machine's exact scheduling latency.
        for _ in 0..<20 where session.outline.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.outline.map(\.title) == ["实时标题"])
    }
}
