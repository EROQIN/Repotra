import Foundation
@testable import Repotra
import Testing

@MainActor
@Suite("Markdown editor integration")
struct MarkdownEditorIntegrationTests {
    @Test("slash palette stays below the caret when space is available")
    func slashPaletteBelowCaret() {
        let placement = SlashPalettePlacement.resolve(
            containerSize: CGSize(width: 500, height: 500),
            anchor: CGRect(x: 100, y: 100, width: 1, height: 20)
        )
        #expect(!placement.opensAbove)
        #expect(placement.origin == CGPoint(x: 100, y: 126))
        #expect(placement.width == 230)
        #expect(placement.maxHeight == 356)
    }

    @Test("slash palette flips above a caret near the bottom")
    func slashPaletteAboveCaret() {
        let placement = SlashPalettePlacement.resolve(
            containerSize: CGSize(width: 500, height: 500),
            anchor: CGRect(x: 120, y: 430, width: 1, height: 20)
        )
        #expect(placement.opensAbove)
        #expect(placement.origin == CGPoint(x: 120, y: 68))
        #expect(placement.maxHeight == 356)
    }

    @Test("slash palette clamps horizontally and scrolls in a small viewport")
    func slashPaletteSmallViewport() {
        let placement = SlashPalettePlacement.resolve(
            containerSize: CGSize(width: 180, height: 120),
            anchor: CGRect(x: 170, y: 50, width: 1, height: 20)
        )
        #expect(placement.origin == CGPoint(x: 8, y: 8))
        #expect(placement.width == 164)
        #expect(placement.maxHeight == 104)
    }

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
