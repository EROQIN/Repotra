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
}
