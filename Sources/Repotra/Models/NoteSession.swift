import Foundation
import Observation

@MainActor
@Observable
final class NoteSession {
    let editorDocumentID = UUID()
    private(set) var relativePath: String
    var content: String
    private(set) var fingerprint: String
    private(set) var isDirty = false
    private(set) var isSaving = false
    var conflict: ExternalConflict?
    var lastError: String?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var title: String {
        ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    init(snapshot: NoteSnapshot, store: LibraryStore) {
        relativePath = snapshot.relativePath
        content = snapshot.content
        fingerprint = snapshot.fingerprint
        self.store = store
    }

    deinit { saveTask?.cancel() }

    func updateContent(_ value: String) {
        guard value != content else { return }
        content = value
        isDirty = true
        if conflict == nil {
            scheduleSave()
        }
    }

    func updatePath(_ path: String) {
        relativePath = path
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow(overwrite: Bool = false) async {
        saveTask?.cancel()
        guard isDirty || overwrite else { return }
        let value = content
        let expected = fingerprint
        isSaving = true
        defer { isSaving = false }
        do {
            let outcome = try await store.saveNote(
                at: relativePath,
                content: value,
                expectedFingerprint: expected,
                overwrite: overwrite
            )
            switch outcome {
            case let .saved(snapshot):
                fingerprint = snapshot.fingerprint
                conflict = nil
                lastError = nil
                isDirty = content != value
                if isDirty {
                    scheduleSave()
                }
            case let .conflict(snapshot):
                conflict = ExternalConflict(kind: .modified, diskSnapshot: snapshot)
            case .missing:
                conflict = ExternalConflict(kind: .deleted, diskSnapshot: nil)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func checkForExternalChanges() async {
        do {
            let snapshot = try await store.readNote(at: relativePath)
            guard snapshot.fingerprint != fingerprint else { return }
            if isDirty {
                conflict = ExternalConflict(kind: .modified, diskSnapshot: snapshot)
            } else {
                content = snapshot.content
                fingerprint = snapshot.fingerprint
                conflict = nil
            }
        } catch {
            conflict = ExternalConflict(kind: .deleted, diskSnapshot: nil)
        }
    }

    func reloadExternalVersion() {
        guard let snapshot = conflict?.diskSnapshot else { return }
        content = snapshot.content
        fingerprint = snapshot.fingerprint
        isDirty = false
        conflict = nil
        lastError = nil
    }

    func overwriteExternalVersion() async {
        isDirty = true
        await saveNow(overwrite: true)
    }

    func saveLocalCopy() async -> String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        let base = title + " (Local Copy)"
        do {
            let newPath = try await store.createNote(in: parent.isEmpty ? nil : parent, title: base)
            let blank = try await store.readNote(at: newPath)
            _ = try await store.saveNote(
                at: newPath,
                content: content,
                expectedFingerprint: blank.fingerprint,
                overwrite: false
            )
            reloadExternalVersion()
            return newPath
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
