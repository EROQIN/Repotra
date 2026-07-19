import Foundation
@testable import Repotra
import Testing

@MainActor
@Suite("AppModel navigation and quick sessions")
struct AppModelTests {
    @Test("legacy quick note migrates into the dedicated section")
    func quickNoteMigration() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        try Data("legacy".utf8).write(to: library.url.appending(path: "快速笔记.md"))
        try Data("normal".utf8).write(to: library.url.appending(path: "Normal.md"))

        let model = AppModel()
        await model.openLibrary(library.url)

        #expect(model.quickNotesDirectoryPath != nil)
        #expect(model.quickNoteSessions.count == 1)
        #expect(model.quickNoteSessions[0].relativePath.hasPrefix((model.quickNotesDirectoryPath ?? "") + "/"))
        #expect(model.allNotes.map(\.relativePath) == ["Normal.md"])
        #expect(FileManager.default.fileExists(atPath: library.url.appending(path: model.quickNoteSessions[0].relativePath).path))
    }

    @Test("recent section is a frozen modification-time snapshot")
    func frozenRecentSnapshot() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let older = library.url.appending(path: "Older.md")
        let newer = library.url.appending(path: "Newer.md")
        try Data("old".utf8).write(to: older)
        try Data("new".utf8).write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newer.path)

        let model = AppModel()
        await model.openLibrary(library.url)
        model.enterSection(.recent)
        #expect(model.recentSnapshotPaths == ["Newer.md", "Older.md"])

        await model.select(path: "Older.md")
        #expect(model.recentSnapshotPaths == ["Newer.md", "Older.md"])
    }

    @Test("renaming to the current title succeeds without an error")
    func sameNameRename() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        try Data("body".utf8).write(to: library.url.appending(path: "Original.md"))
        let model = AppModel()
        await model.openLibrary(library.url)
        await model.select(path: "Original.md")

        #expect(await model.rename(path: "Original.md", to: "Original"))
        #expect(await model.rename(path: "Original.md", to: "Original.md"))
        #expect((await model.renameNote(path: "Original.md", to: "Original")).succeeded)
        #expect((await model.renameNote(path: "Original.md", to: "Original.md")).succeeded)
        #expect(model.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: library.url.appending(path: "Original.md").path))
    }

    @Test("moving the open note saves it and remaps the active session")
    func movingOpenNotePreservesSession() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        try Data("before".utf8).write(to: library.url.appending(path: "Draft.md"))
        try FileManager.default.createDirectory(
            at: library.url.appending(path: "Archive", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )

        let model = AppModel()
        await model.openLibrary(library.url)
        await model.select(path: "Draft.md")
        let session = try #require(model.selectedSession)
        session.updateContent("after")

        #expect(await model.move(path: "Draft.md", into: "Archive"))
        #expect(model.selectedPath == "Archive/Draft.md")
        #expect(model.selectedSession === session)
        #expect(session.relativePath == "Archive/Draft.md")
        #expect(try String(contentsOf: library.url.appending(path: "Archive/Draft.md"), encoding: .utf8) == "after")
        #expect(!FileManager.default.fileExists(atPath: library.url.appending(path: "Draft.md").path))
    }

    @Test("drop URLs must identify Markdown notes inside the current library")
    func droppedNoteURLValidation() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        try Data("body".utf8).write(to: library.url.appending(path: "Inside.md"))
        try FileManager.default.createDirectory(
            at: library.url.appending(path: "Archive", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )

        let model = AppModel()
        await model.openLibrary(library.url)
        let outside = FileManager.default.temporaryDirectory.appending(path: "Outside-\(UUID().uuidString).md")
        try Data().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        #expect(!(await model.move(droppedNoteURL: outside, into: "Archive")))
        #expect(model.errorMessage == "只能移动当前资料库中的 Markdown 笔记。")
        #expect(await model.move(droppedNoteURL: library.url.appending(path: "Inside.md"), into: "Archive"))
        #expect(FileManager.default.fileExists(atPath: library.url.appending(path: "Archive/Inside.md").path))
    }

    @Test("structured note rename keeps both files and preserves the source session")
    func noteRenameConflictKeepsBoth() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        try Data("source".utf8).write(to: library.url.appending(path: "Draft.md"))
        try Data("existing".utf8).write(to: library.url.appending(path: "Final.md"))

        let model = AppModel()
        await model.openLibrary(library.url)
        await model.select(path: "Draft.md")
        let sourceSession = try #require(model.selectedSession)
        sourceSession.updateContent("saved source")

        let firstAttempt = await model.renameNote(path: "Draft.md", to: "Final")
        guard case let .conflict(conflict) = firstAttempt else {
            Issue.record("Expected a rename conflict")
            return
        }
        #expect(conflict.targetPath == "Final.md")
        #expect(model.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: library.url.appending(path: "Draft.md").path))
        #expect(try String(contentsOf: library.url.appending(path: "Final.md"), encoding: .utf8) == "existing")

        let resolved = await model.renameNote(path: "Draft.md", to: "Final", resolution: .keepBoth)
        guard case let .renamed(newPath) = resolved else {
            Issue.record("Expected keep-both resolution to succeed")
            return
        }
        #expect(newPath == "Final 2.md")
        #expect(model.selectedSession === sourceSession)
        #expect(sourceSession.relativePath == "Final 2.md")
        #expect(try String(contentsOf: library.url.appending(path: "Final 2.md"), encoding: .utf8) == "saved source")
        #expect(try String(contentsOf: library.url.appending(path: "Final.md"), encoding: .utf8) == "existing")
    }

    @Test("replacing a quick-note conflict preserves the source session ID")
    func quickNoteRenameConflictReplacesTargetRecord() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let model = AppModel()
        await model.openLibrary(library.url)
        let source = try #require(model.quickNoteSessions.first)
        let targetID = try #require(await model.createQuickNoteSession())
        let uniqueTargetTitle = "Replace-\(UUID().uuidString)"
        let initialRename = await model.renameQuickNoteSession(id: targetID, to: uniqueTargetTitle)
        #expect(initialRename.succeeded)
        let target = try #require(model.quickNoteSessions.first(where: { $0.id == targetID }))
        let trashURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".Trash/\((target.relativePath as NSString).lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: trashURL) }

        let firstAttempt = await model.renameQuickNoteSession(id: source.id, to: uniqueTargetTitle)
        guard case .conflict = firstAttempt else {
            Issue.record("Expected a quick-note rename conflict")
            return
        }
        let replaced = await model.renameQuickNoteSession(
            id: source.id,
            to: uniqueTargetTitle,
            resolution: .replace
        )
        #expect(replaced.succeeded)
        #expect(model.quickNoteSessions.count == 1)
        #expect(model.quickNoteSessions.first?.id == source.id)
        #expect(model.quickNoteSessions.first?.relativePath == target.relativePath)
        #expect(model.activeQuickNoteSessionID == source.id)
        #expect(FileManager.default.fileExists(atPath: library.url.appending(path: target.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: trashURL.path))
    }
}
