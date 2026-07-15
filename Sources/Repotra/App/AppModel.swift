import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var libraryURL: URL?
    private(set) var tree: [NoteNode] = []
    private(set) var sessions: [String: NoteSession] = [:]
    var selectedPath: String?
    var titleEditRequestPath: String?
    var searchQuery = ""
    private(set) var searchResults: [SearchResult] = []
    private(set) var isLoading = false
    private(set) var isLibraryPickerPresented = false
    var errorMessage: String?

    @ObservationIgnored private var store: LibraryStore?
    @ObservationIgnored private var metadataStore: MetadataStore?
    @ObservationIgnored private var searchIndex: SearchIndex?
    @ObservationIgnored private let watcher = DirectoryWatcher()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var hasPresentedInitialLibraryPicker = false
    @ObservationIgnored let stickyWindows = StickyWindowCoordinator()
    @ObservationIgnored let quickCapture = QuickCaptureCoordinator()
    @ObservationIgnored private var opensQuickCaptureAfterLibrarySelection = false

    var selectedSession: NoteSession? {
        guard let selectedPath else { return nil }
        return sessions[selectedPath]
    }

    var selectedNode: NoteNode? {
        guard let selectedPath else { return nil }
        return findNode(path: selectedPath, in: tree)
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return
        }
        if let path = UserDefaults.standard.string(forKey: "Repotra.LastLibraryPath") {
            let url = URL(filePath: path, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                await openLibrary(url)
            }
        }
    }

    func openLibrary(_ url: URL) async {
        isLoading = true
        defer { isLoading = false }
        await saveAllSessions()
        quickCapture.closeForLibrarySwitch()
        stickyWindows.closeWindowsForLibrarySwitch()
        watcher.stop()
        sessions.removeAll()
        selectedPath = nil
        searchResults = []

        let store = LibraryStore(rootURL: url)
        let metadataStore = MetadataStore(rootURL: url)
        let searchIndex = SearchIndex()
        do {
            let snapshot = try await store.bootstrap()
            _ = try await metadataStore.bootstrap()
            try await searchIndex.rebuild(rootURL: url)
            self.store = store
            self.metadataStore = metadataStore
            self.searchIndex = searchIndex
            libraryURL = url.standardizedFileURL
            tree = snapshot.roots
            UserDefaults.standard.set(url.path, forKey: "Repotra.LastLibraryPath")
            startWatching(url: url)
            await restoreStickyWindows()
            if opensQuickCaptureAfterLibrarySelection {
                opensQuickCaptureAfterLibrarySelection = false
                await showQuickCapture()
            }
        } catch {
            errorMessage = error.localizedDescription
            libraryURL = nil
            tree = []
        }
    }

    func presentLibraryPicker() {
        isLibraryPickerPresented = true
    }

    func dismissLibraryPicker() {
        isLibraryPickerPresented = false
        opensQuickCaptureAfterLibrarySelection = false
    }

    func requestQuickCapture() {
        if libraryURL == nil {
            opensQuickCaptureAfterLibrarySelection = true
            presentLibraryPicker()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        Task { await showQuickCapture() }
    }

    func selectLibrary(_ url: URL) async {
        isLibraryPickerPresented = false
        await openLibrary(url)
    }

    func presentInitialLibraryPicker() {
        guard !hasPresentedInitialLibraryPicker else { return }
        hasPresentedInitialLibraryPicker = true
        presentLibraryPicker()
    }

    func select(path: String) async {
        selectedPath = path
        _ = await session(for: path)
    }

    func session(for path: String) async -> NoteSession? {
        if let session = sessions[path] {
            return session
        }
        guard let store else { return nil }
        do {
            let snapshot = try await store.readNote(at: path)
            let session = NoteSession(snapshot: snapshot, store: store)
            sessions[path] = session
            return session
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func setSearchQuery(_ value: String) {
        searchQuery = value
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, let searchIndex else { return }
            searchResults = await searchIndex.query(value)
        }
    }

    func createNote(in directory: String? = nil) async {
        guard let store else { return }
        do {
            let parent = directory ?? selectedDirectoryPath()
            let path = try await store.createNote(in: parent, title: "Untitled")
            await reloadLibraryIndex()
            await select(path: path)
            titleEditRequestPath = path
        } catch { errorMessage = error.localizedDescription }
    }

    func createFolder(in directory: String? = nil) async {
        guard let store else { return }
        do {
            _ = try await store.createFolder(in: directory ?? selectedDirectoryPath(), title: "New Folder")
            await reloadLibraryIndex()
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func rename(path: String, to newName: String) async -> Bool {
        guard let store, let metadataStore else { return false }
        if let validationError = filenameValidationError(newName) {
            errorMessage = validationError
            return false
        }
        let affectedSessions = sessions.filter { key, _ in key == path || key.hasPrefix(path + "/") }.map(\.value)
        for session in affectedSessions {
            await session.saveNow()
        }
        guard affectedSessions.allSatisfy({ $0.conflict == nil }) else {
            errorMessage = "请先处理外部文件冲突，再重命名。"
            return false
        }
        do {
            let newPath = try await store.renameItem(at: path, to: newName)
            try await metadataStore.moveRecord(from: path, to: newPath)
            remapSessions(from: path, to: newPath)
            if selectedPath == path || selectedPath?.hasPrefix(path + "/") == true {
                selectedPath = newPath + String((selectedPath ?? path).dropFirst(path.count))
            }
            await reloadLibraryIndex()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func filenameValidationError(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "文件名不能为空。" }
        guard trimmed.lowercased() != ".repotra" else { return ".repotra 是保留名称。" }
        let invalid = CharacterSet(charactersIn: "/:\0").union(.newlines)
        guard trimmed.rangeOfCharacter(from: invalid) == nil else {
            return "文件名不能包含 /、: 或换行。"
        }
        return nil
    }

    func revealSelectedNote() {
        guard let libraryURL, let selectedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([libraryURL.appending(path: selectedPath)])
    }

    func move(path: String, into directory: String) async {
        guard let store, let metadataStore else { return }
        do {
            let newPath = try await store.moveItem(at: path, into: directory)
            try await metadataStore.moveRecord(from: path, to: newPath)
            remapSessions(from: path, to: newPath)
            if selectedPath == path || selectedPath?.hasPrefix(path + "/") == true {
                selectedPath = newPath + String((selectedPath ?? path).dropFirst(path.count))
            }
            await reloadLibraryIndex()
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(path: String) async {
        guard let store, let metadataStore else { return }
        let affectedSessions = sessions.filter { key, _ in key == path || key.hasPrefix(path + "/") }.map(\.value)
        for session in affectedSessions {
            await session.saveNow()
        }
        guard affectedSessions.allSatisfy({ $0.conflict == nil }) else {
            errorMessage = "请先处理外部文件冲突，再移到废纸篓。"
            return
        }
        let pinned = stickyWindows.pinnedPaths.filter { $0 == path || $0.hasPrefix(path + "/") }
        pinned.forEach { stickyWindows.unpin(path: $0) }
        do {
            try await store.trashItem(at: path)
            try await metadataStore.removeRecords(under: path)
            sessions = sessions.filter { key, _ in key != path && !key.hasPrefix(path + "/") }
            if selectedPath == path || selectedPath?.hasPrefix(path + "/") == true {
                selectedPath = nil
            }
            await reloadLibraryIndex()
        } catch { errorMessage = error.localizedDescription }
    }

    func pinSelectedNote() async {
        guard let path = selectedPath, let session = await session(for: path) else { return }
        await pin(session: session)
    }

    func togglePinnedSelectedNote() async {
        guard let path = selectedPath else { return }
        if stickyWindows.pinnedPaths.contains(path) {
            stickyWindows.unpin(path: path)
        } else {
            await pinSelectedNote()
        }
    }

    func importImage(from url: URL) async -> String? {
        guard let store else { return nil }
        do {
            return try await store.importImage(from: url)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func importImage(data: Data) async -> String? {
        guard let store else { return nil }
        do {
            return try await store.importImage(data: data)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func resolveConflictBySavingCopy(_ session: NoteSession) async {
        if let path = await session.saveLocalCopy() {
            await reloadLibraryIndex()
            await select(path: path)
        }
    }

    func reloadLibraryIndex() async {
        guard let store, let searchIndex, let libraryURL else { return }
        do {
            tree = try await store.snapshot().roots
            try await searchIndex.rebuild(rootURL: libraryURL)
            if !searchQuery.isEmpty {
                searchResults = await searchIndex.query(searchQuery)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveAllSessions() async {
        for session in sessions.values {
            await session.saveNow()
        }
    }

    func prepareForTermination() async {
        stickyWindows.prepareForTermination()
        await saveAllSessions()
    }

    private func showQuickCapture() async {
        guard let session = await quickNoteSession(), let libraryURL else { return }
        quickCapture.show(
            session: session,
            rootURL: libraryURL,
            importImageFile: { [weak self] url in await self?.importImage(from: url) },
            importImageData: { [weak self] data in await self?.importImage(data: data) }
        )
    }

    private func quickNoteSession() async -> NoteSession? {
        guard let store, let metadataStore else { return nil }
        do {
            let path: String
            if let configured = await metadataStore.quickNotePath(), await store.noteExists(at: configured) {
                path = configured
            } else if await store.noteExists(at: "快速笔记.md") {
                path = "快速笔记.md"
                try await metadataStore.setQuickNotePath(path)
            } else {
                path = try await store.createNote(in: nil, title: "快速笔记")
                try await metadataStore.setQuickNotePath(path)
                await reloadLibraryIndex()
            }
            return await session(for: path)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func pin(session: NoteSession, existingRecord: StickyRecord? = nil) async {
        guard let libraryURL, let metadataStore else { return }
        stickyWindows.pin(
            session: session,
            rootURL: libraryURL,
            metadataStore: metadataStore,
            existingRecord: existingRecord,
            importImageFile: { [weak self] url in await self?.importImage(from: url) },
            importImageData: { [weak self] data in await self?.importImage(data: data) }
        )
    }

    private func restoreStickyWindows() async {
        guard let metadataStore, let store else { return }
        let records = await metadataStore.records()
        for (path, record) in records.sorted(by: { $0.key < $1.key }) {
            if await store.noteExists(at: path), let session = await session(for: path) {
                await pin(session: session, existingRecord: record)
            } else {
                try? await metadataStore.remove(notePath: path)
            }
        }
    }

    private func startWatching(url: URL) {
        watcher.start(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleExternalRefresh()
            }
        }
    }

    private func scheduleExternalRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            for session in sessions.values {
                await session.checkForExternalChanges()
            }
            await reloadLibraryIndex()
        }
    }

    private func remapSessions(from oldPath: String, to newPath: String) {
        let affected = sessions.filter { key, _ in key == oldPath || key.hasPrefix(oldPath + "/") }
        for (oldKey, session) in affected {
            let nextKey = newPath + String(oldKey.dropFirst(oldPath.count))
            sessions.removeValue(forKey: oldKey)
            session.updatePath(nextKey)
            sessions[nextKey] = session
            stickyWindows.moveSession(from: oldKey, to: nextKey)
        }
    }

    private func selectedDirectoryPath() -> String? {
        guard let selectedPath else { return nil }
        if selectedNode?.isDirectory == true {
            return selectedPath
        }
        let parent = (selectedPath as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    private func findNode(path: String, in nodes: [NoteNode]) -> NoteNode? {
        for node in nodes {
            if node.relativePath == path {
                return node
            }
            if let children = node.children, let found = findNode(path: path, in: children) {
                return found
            }
        }
        return nil
    }
}
