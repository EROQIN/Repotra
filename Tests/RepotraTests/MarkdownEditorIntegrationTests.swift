import Foundation
@testable import Repotra
import Testing

@MainActor
@Suite("Markdown editor integration")
struct MarkdownEditorIntegrationTests {
    @Test("formatting commands are isolated per editor")
    func commandIsolation() {
        let first = MarkdownCommandCenter()
        let second = MarkdownCommandCenter()
        #expect(first.bus.applyBoldRequest != second.bus.applyBoldRequest)

        first.perform(.bold)
        #expect(first.bus.applyBoldRequest != nil)
    }

    @Test("editor document identity survives a rename")
    func stableDocumentIdentity() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let path = try await store.createNote(in: nil, title: "Before")
        let session = NoteSession(snapshot: try await store.readNote(at: path), store: store)
        let identity = session.editorDocumentID
        session.updatePath("After.md")
        #expect(session.editorDocumentID == identity)
    }
}
