import Foundation
@testable import Repotra
import Testing

@Suite("MetadataStore")
struct MetadataStoreTests {
    @Test("persists stickies and migrates paths")
    func stickyPersistence() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = MetadataStore(rootURL: library.url)
        let configuration = try await store.bootstrap()
        #expect(configuration.schemaVersion == 1)
        #expect(configuration.quickNotePath == nil)

        try await store.setQuickNotePath("快速笔记.md")
        #expect(await store.quickNotePath() == "快速笔记.md")

        var record = StickyRecord(notePath: "folder/note.md")
        record.alwaysOnTop = true
        record.appearance.background.kind = .gradient
        try await store.save(record)
        try await store.moveRecord(from: "folder", to: "archive")

        let records = await store.records()
        #expect(records["folder/note.md"] == nil)
        #expect(records["archive/note.md"]?.alwaysOnTop == true)
        #expect(records["archive/note.md"]?.appearance.background.kind == .gradient)

        let reloaded = MetadataStore(rootURL: library.url)
        _ = try await reloaded.bootstrap()
        #expect(await reloaded.record(for: "archive/note.md") != nil)
        #expect(await reloaded.quickNotePath() == "快速笔记.md")
    }
}
