import Foundation
@testable import Repotra
import Testing

@Suite("MetadataStore")
struct MetadataStoreTests {
    @Test("new stickies default to screenshot-style always on top")
    func newStickyDefaultsToAlwaysOnTop() {
        #expect(StickyRecord(notePath: "note.md").alwaysOnTop)
    }

    @Test("persists stickies and migrates paths")
    func stickyPersistence() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = MetadataStore(rootURL: library.url)
        let configuration = try await store.bootstrap()
        #expect(configuration.schemaVersion == 3)
        #expect(configuration.quickNotePath == nil)

        try await store.setQuickNotePath("快速笔记.md")
        #expect(await store.quickNotePath() == "快速笔记.md")

        let quickSession = QuickNoteSessionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            relativePath: "快速笔记/第一条.md",
            createdAt: Date(timeIntervalSince1970: 123)
        )
        try await store.saveQuickNoteState(
            directoryPath: "快速笔记",
            sessions: [quickSession],
            activeSessionID: quickSession.id
        )

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
        let quickState = await reloaded.quickNoteState()
        #expect(quickState.legacyPath == nil)
        #expect(quickState.directoryPath == "快速笔记")
        #expect(quickState.sessions == [quickSession])
        #expect(quickState.activeSessionID == quickSession.id)
    }

    @Test("migrates schema v1 and persists navigation state")
    func navigationMigration() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let metadata = library.url.appending(path: ".repotra")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let legacy = """
        {"schemaVersion":1,"libraryID":"00000000-0000-0000-0000-000000000001","quickNotePath":"quick.md"}
        """
        try Data(legacy.utf8).write(to: metadata.appending(path: "library.json"))

        let store = MetadataStore(rootURL: library.url)
        let migrated = try await store.bootstrap()
        #expect(migrated.schemaVersion == 3)
        #expect(migrated.quickNotePath == "quick.md")

        let display = LibraryDisplayState(showsSidebar: false, showsInspector: true, selectedSection: "favorites")
        try await store.saveNavigationState(favorites: ["a.md"], recents: ["b.md"], display: display)
        let reloaded = MetadataStore(rootURL: library.url)
        _ = try await reloaded.bootstrap()
        let state = await reloaded.navigationState()
        #expect(state.favorites == ["a.md"])
        #expect(state.recents == ["b.md"])
        #expect(state.display == display)
    }

    @Test("migrates schema v2 without losing navigation fields")
    func schemaV2Migration() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let metadata = library.url.appending(path: ".repotra")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let legacy = """
        {"schemaVersion":2,"libraryID":"00000000-0000-0000-0000-000000000002","quickNotePath":"capture.md","favoritePaths":["fav.md"],"recentPaths":["recent.md"],"displayState":{"showsSidebar":false,"showsInspector":false,"selectedSection":"recent"}}
        """
        try Data(legacy.utf8).write(to: metadata.appending(path: "library.json"))

        let store = MetadataStore(rootURL: library.url)
        let migrated = try await store.bootstrap()
        #expect(migrated.schemaVersion == 3)
        #expect(migrated.quickNotePath == "capture.md")
        #expect(migrated.favoritePaths == ["fav.md"])
        #expect(migrated.recentPaths == ["recent.md"])
        #expect(migrated.displayState.selectedSection == "recent")
        #expect(migrated.quickNoteSessions.isEmpty)
    }
}
