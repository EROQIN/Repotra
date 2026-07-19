import Foundation
@testable import Repotra
import Testing

@Suite("LibraryStore")
struct LibraryStoreTests {
    @Test("creates, saves, detects conflicts, and renames notes")
    func noteLifecycle() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()

        let path = try await store.createNote(in: nil, title: "Daily/Unsafe")
        #expect(path == "Daily-Unsafe.md")
        let blank = try await store.readNote(at: path)
        let first = try await store.saveNote(
            at: path,
            content: "# Hello\n",
            expectedFingerprint: blank.fingerprint
        )
        guard case let .saved(saved) = first else {
            Issue.record("Expected successful save")
            return
        }
        #expect(saved.content == "# Hello\n")

        try Data("external".utf8).write(to: library.url.appending(path: path), options: .atomic)
        let conflict = try await store.saveNote(
            at: path,
            content: "local",
            expectedFingerprint: saved.fingerprint
        )
        guard case let .conflict(disk) = conflict else {
            Issue.record("Expected a conflict")
            return
        }
        #expect(disk.content == "external")

        let renamed = try await store.renameItem(at: path, to: "Renamed")
        #expect(renamed == "Renamed.md")
        #expect(await store.noteExists(at: renamed))

        let unchanged = try await store.renameItem(at: renamed, to: "Renamed")
        #expect(unchanged == renamed)
        let unchangedWithExtension = try await store.renameItem(at: renamed, to: "Renamed.md")
        #expect(unchangedWithExtension == renamed)
    }

    @Test("renaming a folder to its current name is a no-op")
    func sameFolderNameIsNoOp() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let folder = try await store.createFolder(in: nil, title: "Projects")
        let unchanged = try await store.renameItem(at: folder, to: "Projects")
        #expect(unchanged == folder)
        #expect(await store.directoryExists(at: folder))
    }

    @Test("imports image data with a relative path")
    func imageImport() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let path = try await store.importImage(data: Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(path.hasPrefix("assets/"))
        #expect(path.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: library.url.appending(path: path).path))
    }

    @Test("rejects paths outside the library")
    func pathTraversal() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        await #expect(throws: LibraryError.self) {
            _ = try await store.readNote(at: "../secret.md")
        }
    }

    @Test("moves a note into a folder and treats the same folder as a no-op")
    func moveNoteIntoFolder() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let note = try await store.createNote(in: nil, title: "Move Me")
        let folder = try await store.createFolder(in: nil, title: "Archive")

        let moved = try await store.moveItem(at: note, into: folder)
        #expect(moved == "Archive/Move Me.md")
        #expect(await store.noteExists(at: moved))
        #expect(!(await store.noteExists(at: note)))

        let unchanged = try await store.moveItem(at: moved, into: folder)
        #expect(unchanged == moved)
    }

    @Test("reports a useful error when the destination already contains the note")
    func moveNoteRejectsDuplicateDestination() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let note = try await store.createNote(in: nil, title: "Duplicate")
        let folder = try await store.createFolder(in: nil, title: "Archive")
        _ = try await store.createNote(in: folder, title: "Duplicate")

        await #expect(throws: LibraryError.self) {
            _ = try await store.moveItem(at: note, into: folder)
        }
        #expect(await store.noteExists(at: note))
        #expect(await store.noteExists(at: "Archive/Duplicate.md"))
    }

    @Test("rename conflicts are non-mutating and keeping both uses an incrementing name")
    func renameConflictCanKeepBoth() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let source = try await store.createNote(in: nil, title: "草稿 📝")
        let existing = try await store.createNote(in: nil, title: "归档")
        _ = try await store.createNote(in: nil, title: "归档 2")
        try Data("source".utf8).write(to: library.url.appending(path: source))
        try Data("existing".utf8).write(to: library.url.appending(path: existing))

        let conflict = try await store.renameNoteItem(at: source, to: "归档.md", resolution: nil)
        guard case let .conflict(existingPath) = conflict else {
            Issue.record("Expected a structured rename conflict")
            return
        }
        #expect(existingPath == "归档.md")
        #expect(await store.noteExists(at: source))
        #expect(try String(contentsOf: library.url.appending(path: existing), encoding: .utf8) == "existing")

        let kept = try await store.renameNoteItem(at: source, to: "归档", resolution: .keepBoth)
        guard case let .renamed(result) = kept else {
            Issue.record("Expected keep-both rename to succeed")
            return
        }
        #expect(result.newPath == "归档 3.md")
        #expect(result.replacedPath == nil)
        #expect(try String(contentsOf: library.url.appending(path: result.newPath), encoding: .utf8) == "source")
        #expect(try String(contentsOf: library.url.appending(path: existing), encoding: .utf8) == "existing")
    }

    @Test("replacing a rename conflict keeps the source and moves the old target to Trash")
    func renameConflictCanReplace() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let store = LibraryStore(rootURL: library.url)
        _ = try await store.bootstrap()
        let source = try await store.createNote(in: nil, title: "Current")
        let target = try await store.createNote(in: nil, title: "Target")
        try Data("current body".utf8).write(to: library.url.appending(path: source))
        try Data("old target body".utf8).write(to: library.url.appending(path: target))

        let outcome = try await store.renameNoteItem(at: source, to: "Target", resolution: .replace)
        guard case let .renamed(result) = outcome else {
            Issue.record("Expected replacement rename to succeed")
            return
        }
        defer {
            if let recoveryURL = result.recoveryURL {
                try? FileManager.default.removeItem(at: recoveryURL)
            }
        }
        #expect(result.newPath == "Target.md")
        #expect(result.replacedPath == "Target.md")
        #expect(try String(contentsOf: library.url.appending(path: "Target.md"), encoding: .utf8) == "current body")
        #expect(!FileManager.default.fileExists(atPath: library.url.appending(path: "Current.md").path))
        let recoveryURL = try #require(result.recoveryURL)
        #expect(try String(contentsOf: recoveryURL, encoding: .utf8) == "old target body")
    }
}
