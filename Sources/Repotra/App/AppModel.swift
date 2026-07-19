import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum LibrarySection: String, CaseIterable, Identifiable {
        case quickNotes, library, recent, all, favorites
        var id: String { rawValue }
    }
    private(set) var libraryURL: URL?
    private(set) var tree: [NoteNode] = []
    private(set) var sessions: [String: NoteSession] = [:]
    var selectedPath: String?
    var titleEditRequestPath: String?
    var sidebarTitleEditRequestPath: String?
    var searchQuery = ""
    private(set) var favoritePaths: [String] = []
    private(set) var recentPaths: [String] = []
    private(set) var recentSnapshotPaths: [String] = []
    private(set) var noteMetrics: [String: NoteMetrics] = [:]
    private(set) var quickNoteSessions: [QuickNoteSessionRecord] = []
    private(set) var activeQuickNoteSessionID: UUID?
    private(set) var quickNotesDirectoryPath: String?
    var selectedSection: LibrarySection = .library
    var showsSidebar = true
    var showsInspector = true
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
    @ObservationIgnored let floatingNote = FloatingNoteCoordinator()
    @ObservationIgnored private var opensQuickCaptureAfterLibrarySelection = false
    @ObservationIgnored private var selectionHistory: [String] = []
    @ObservationIgnored private var selectionHistoryIndex = -1
    @ObservationIgnored private var isNavigatingHistory = false

    var selectedSession: NoteSession? {
        guard let selectedPath else { return nil }
        return sessions[selectedPath]
    }

    var selectedNode: NoteNode? {
        guard let selectedPath else { return nil }
        return findNode(path: selectedPath, in: tree)
    }

    var canGoBack: Bool { selectionHistoryIndex > 0 }
    var canGoForward: Bool { selectionHistoryIndex >= 0 && selectionHistoryIndex < selectionHistory.count - 1 }
    var isSelectedFavorite: Bool { selectedPath.map(favoritePaths.contains) ?? false }

    var allNotes: [NoteNode] { flattenedNotes(in: tree) }

    var activeQuickNoteRecord: QuickNoteSessionRecord? {
        quickNoteSessions.first { $0.id == activeQuickNoteSessionID } ?? quickNoteSessions.first
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") {
            if let marker = arguments.firstIndex(of: "--ui-testing-library"),
               arguments.indices.contains(marker + 1)
            {
                let url = URL(filePath: arguments[marker + 1], directoryHint: .isDirectory)
                await openLibrary(url)
                if arguments.contains("--show-quick-note") {
                    await showQuickCapture()
                }
            }
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
        await quickCapture.closeForLibrarySwitch()
        await floatingNote.closeForLibrarySwitch()
        stickyWindows.closeWindowsForLibrarySwitch()
        watcher.stop()
        sessions.removeAll()
        selectedPath = nil
        searchResults = []
        quickNoteSessions = []
        activeQuickNoteSessionID = nil
        quickNotesDirectoryPath = nil
        noteMetrics = [:]
        recentSnapshotPaths = []

        let store = LibraryStore(rootURL: url)
        let metadataStore = MetadataStore(rootURL: url)
        let searchIndex = SearchIndex()
        do {
            _ = try await store.bootstrap()
            _ = try await metadataStore.bootstrap()
            let quickState = try await migrateQuickNotes(store: store, metadataStore: metadataStore)
            let navigation = await metadataStore.navigationState()
            try await searchIndex.rebuild(rootURL: url)
            self.store = store
            self.metadataStore = metadataStore
            self.searchIndex = searchIndex
            libraryURL = url.standardizedFileURL
            quickNotesDirectoryPath = quickState.directoryPath
            quickNoteSessions = quickState.sessions
            activeQuickNoteSessionID = quickState.activeSessionID
            tree = try await store.snapshot(excludingRootPaths: [quickState.directoryPath]).roots
            noteMetrics = await searchIndex.metrics()
            favoritePaths = navigation.favorites
            recentPaths = navigation.recents
            showsSidebar = navigation.display.showsSidebar
            showsInspector = navigation.display.showsInspector
            selectedSection = LibrarySection(rawValue: navigation.display.selectedSection) ?? .library
            if selectedSection == .recent { refreshRecentSnapshot() }
            UserDefaults.standard.set(url.path, forKey: "Repotra.LastLibraryPath")
            startWatching(url: url)
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
        Task { await showQuickCapture(togglesVisibility: true) }
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
        if isQuickNotePath(path) {
            await showQuickCapture(sessionID: quickNoteSessions.first { $0.relativePath == path }?.id)
            return
        }
        guard findNode(path: path, in: tree)?.isDirectory != true else { return }
        selectedPath = path
        recordSelection(path)
        _ = await session(for: path)
    }

    func enterSection(_ section: LibrarySection) {
        selectedSection = section
        if section == .recent { refreshRecentSnapshot() }
        updateDisplayState()
    }

    func characterCount(for path: String) -> Int {
        sessions[path]?.content.count ?? noteMetrics[path]?.characterCount ?? 0
    }

    func isQuickNotePath(_ path: String) -> Bool {
        quickNoteSessions.contains { $0.relativePath == path }
    }

    func goBack() async {
        guard canGoBack else { return }
        selectionHistoryIndex -= 1
        await navigateHistory(to: selectionHistory[selectionHistoryIndex])
    }

    func goForward() async {
        guard canGoForward else { return }
        selectionHistoryIndex += 1
        await navigateHistory(to: selectionHistory[selectionHistoryIndex])
    }

    func toggleFavorite() {
        guard let path = selectedPath else { return }
        if let index = favoritePaths.firstIndex(of: path) {
            favoritePaths.remove(at: index)
        } else {
            favoritePaths.insert(path, at: 0)
        }
        persistNavigationState()
    }

    func updateDisplayState() {
        persistNavigationState()
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
        await renamePath(path: path, to: newName) != nil
    }

    @discardableResult
    func renamePath(path: String, to newName: String) async -> String? {
        guard let store, let metadataStore else { return nil }
        let currentName = (path as NSString).lastPathComponent
        let targetName = PathUtilities.renameTargetName(
            currentName: currentName,
            proposedName: newName
        )
        if targetName == currentName {
            errorMessage = nil
            return path
        }
        if let validationError = filenameValidationError(newName) {
            errorMessage = validationError
            return nil
        }
        let affectedSessions = sessions.filter { key, _ in key == path || key.hasPrefix(path + "/") }.map(\.value)
        for session in affectedSessions {
            await session.saveNow()
        }
        guard affectedSessions.allSatisfy({ $0.conflict == nil }) else {
            errorMessage = "请先处理外部文件冲突，再重命名。"
            return nil
        }
        do {
            let newPath = try await store.renameItem(at: path, to: newName)
            try await metadataStore.moveRecord(from: path, to: newPath)
            remapSessions(from: path, to: newPath)
            remapNavigationReferences(from: path, to: newPath)
            if selectedPath == path || selectedPath?.hasPrefix(path + "/") == true {
                selectedPath = newPath + String((selectedPath ?? path).dropFirst(path.count))
            }
            await reloadLibraryIndex()
            return newPath
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameNote(
        path: String,
        to newName: String,
        resolution: RenameConflictResolution? = nil
    ) async -> NoteRenameOutcome {
        guard let store, let metadataStore else {
            return .failed(LibraryError.noLibrary.localizedDescription)
        }
        let currentName = (path as NSString).lastPathComponent
        let targetName = PathUtilities.renameTargetName(currentName: currentName, proposedName: newName)
        if targetName == currentName {
            errorMessage = nil
            return .renamed(path)
        }
        if let validationError = filenameValidationError(newName) {
            return .failed(validationError)
        }

        let parent = (path as NSString).deletingLastPathComponent
        let requestedTargetPath = parent.isEmpty ? targetName : "\(parent)/\(targetName)"
        var sessionsToSave = sessions.filter { $0.key == path }.map(\.value)
        if resolution == .replace, let targetSession = sessions[requestedTargetPath] {
            sessionsToSave.append(targetSession)
        }
        for session in sessionsToSave {
            await session.saveNow()
        }
        guard sessionsToSave.allSatisfy({ $0.conflict == nil && $0.lastError == nil }) else {
            return .failed("笔记尚未安全保存，请处理保存失败或外部文件冲突后再重命名。")
        }

        do {
            let storeOutcome = try await store.renameNoteItem(
                at: path,
                to: newName,
                resolution: resolution
            )
            switch storeOutcome {
            case let .conflict(existingPath):
                errorMessage = nil
                return .conflict(NoteRenameConflict(
                    sourcePath: path,
                    targetPath: existingPath,
                    proposedName: newName
                ))
            case let .renamed(result):
                if let replacedPath = result.replacedPath {
                    await closePresentations(forReplacedPath: replacedPath)
                    try await metadataStore.removeRecords(under: replacedPath)
                    removeRuntimeReferences(under: replacedPath, replacingWith: result.newPath)
                }
                try await metadataStore.moveRecord(from: path, to: result.newPath)
                remapSessions(from: path, to: result.newPath)
                remapNavigationReferences(from: path, to: result.newPath)
                if selectedPath == path || selectedPath?.hasPrefix(path + "/") == true {
                    selectedPath = result.newPath + String((selectedPath ?? path).dropFirst(path.count))
                }
                await persistQuickNoteState()
                await reloadLibraryIndex()
                errorMessage = nil
                return .renamed(result.newPath)
            }
        } catch {
            await reloadLibraryIndex()
            return .failed(error.localizedDescription)
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

    @discardableResult
    func move(droppedNoteURL url: URL, into directory: String) async -> Bool {
        guard let libraryURL else {
            errorMessage = LibraryError.noLibrary.localizedDescription
            return false
        }
        let root = libraryURL.standardizedFileURL.resolvingSymlinksInPath()
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard source.path.hasPrefix(rootPath), source.pathExtension.lowercased() == "md" else {
            errorMessage = "只能移动当前资料库中的 Markdown 笔记。"
            return false
        }
        let relativePath = String(source.path.dropFirst(rootPath.count))
        return await move(path: relativePath, into: directory)
    }

    @discardableResult
    func move(path: String, into directory: String) async -> Bool {
        guard let store, let metadataStore else {
            errorMessage = LibraryError.noLibrary.localizedDescription
            return false
        }
        guard !path.isEmpty, !isQuickNotePath(path) else {
            errorMessage = "快速笔记由会话分区管理，不能拖入资料库文件夹。"
            return false
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != directory else {
            errorMessage = nil
            return false
        }
        let affectedSessions = sessions.filter { key, _ in key == path || key.hasPrefix(path + "/") }.map(\.value)
        for session in affectedSessions {
            await session.saveNow()
        }
        guard affectedSessions.allSatisfy({ $0.conflict == nil && $0.lastError == nil }) else {
            errorMessage = "笔记尚未安全保存，请处理保存失败或外部文件冲突后再移动。"
            return false
        }
        do {
            let newPath = try await store.moveItem(at: path, into: directory)
            try await metadataStore.moveRecord(from: path, to: newPath)
            remapSessions(from: path, to: newPath)
            remapNavigationReferences(from: path, to: newPath)
            if selectedPath == path || selectedPath?.hasPrefix(path + "/") == true {
                selectedPath = newPath + String((selectedPath ?? path).dropFirst(path.count))
            }
            await reloadLibraryIndex()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            await reloadLibraryIndex()
            return false
        }
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
            favoritePaths.removeAll { $0 == path || $0.hasPrefix(path + "/") }
            recentPaths.removeAll { $0 == path || $0.hasPrefix(path + "/") }
            selectionHistory.removeAll { $0 == path || $0.hasPrefix(path + "/") }
            selectionHistoryIndex = min(selectionHistoryIndex, selectionHistory.count - 1)
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
            let excluded = quickNotesDirectoryPath.map { Set([$0]) } ?? []
            tree = try await store.snapshot(excludingRootPaths: excluded).roots
            try await searchIndex.rebuild(rootURL: libraryURL)
            noteMetrics = await searchIndex.metrics()
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
        await quickCapture.persistNow()
        await floatingNote.persistNow()
        await saveAllSessions()
    }

    func showQuickCapture(
        sessionID: UUID? = nil,
        togglesVisibility: Bool = false,
        activatesEditor: Bool = true
    ) async {
        guard let record = await ensureQuickNoteSession(preferredID: sessionID),
              let session = await session(for: record.relativePath), let libraryURL else { return }
        activeQuickNoteSessionID = record.id
        await persistQuickNoteState()
        let presentation = QuickCapturePresentation(
            sessions: quickNoteSessions,
            activeSessionID: record.id,
            sessionProvider: { [weak self] id in
                guard let self, let target = self.quickNoteSessions.first(where: { $0.id == id }) else { return nil }
                self.activeQuickNoteSessionID = id
                await self.persistQuickNoteState()
                return await self.session(for: target.relativePath)
            },
            createSession: { [weak self] in await self?.createQuickNoteSession() },
            renameSession: { [weak self] id, name, resolution in
                await self?.renameQuickNoteSession(id: id, to: name, resolution: resolution)
                    ?? .failed("找不到快速笔记会话。")
            },
            deleteSession: { [weak self] id in await self?.deleteQuickNoteSession(id: id) }
            , recordsProvider: { [weak self] in
                guard let self else { return ([], nil) }
                return (self.quickNoteSessions, self.activeQuickNoteSessionID)
            }
        )
        let operation: () async -> Void = { [weak self] in
            guard let self else { return }
            if togglesVisibility {
                await self.quickCapture.toggle(
                    session: session,
                    presentation: presentation,
                    rootURL: libraryURL,
                    importImageFile: { [weak self] url in await self?.importImage(from: url) },
                    importImageData: { [weak self] data in await self?.importImage(data: data) }
                )
            } else {
                await self.quickCapture.show(
                    session: session,
                    presentation: presentation,
                    rootURL: libraryURL,
                    activatesEditor: activatesEditor,
                    importImageFile: { [weak self] url in await self?.importImage(from: url) },
                    importImageData: { [weak self] data in await self?.importImage(data: data) }
                )
            }
        }
        await operation()
    }

    func toggleFloatingSelectedNote() async {
        guard let session = selectedSession, let libraryURL else { return }
        await floatingNote.toggle(
            session: session,
            rootURL: libraryURL,
            importImageFile: { [weak self] url in await self?.importImage(from: url) },
            importImageData: { [weak self] data in await self?.importImage(data: data) }
        )
    }

    @discardableResult
    func createQuickNoteSession() async -> UUID? {
        guard let store, let directory = quickNotesDirectoryPath else { return nil }
        do {
            let path = try await store.createNote(in: directory, title: "未命名速记")
            let record = QuickNoteSessionRecord(relativePath: path)
            quickNoteSessions.append(record)
            quickNoteSessions.sort { $0.createdAt < $1.createdAt }
            activeQuickNoteSessionID = record.id
            try await persistQuickNoteStateThrowing()
            await reloadLibraryIndex()
            return record.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameQuickNoteSession(
        id: UUID,
        to name: String,
        resolution: RenameConflictResolution? = nil
    ) async -> NoteRenameOutcome {
        guard let record = quickNoteSessions.first(where: { $0.id == id }) else {
            return .failed("找不到快速笔记会话。")
        }
        return await renameNote(path: record.relativePath, to: name, resolution: resolution)
    }

    func deleteQuickNoteSession(id: UUID) async {
        guard let record = quickNoteSessions.first(where: { $0.id == id }),
              let store, let metadataStore else { return }
        await sessions[record.relativePath]?.saveNow()
        do {
            try await store.trashItem(at: record.relativePath)
            try await metadataStore.removeRecords(under: record.relativePath)
            sessions.removeValue(forKey: record.relativePath)
            quickNoteSessions.removeAll { $0.id == id }
            if activeQuickNoteSessionID == id { activeQuickNoteSessionID = quickNoteSessions.first?.id }
            try await persistQuickNoteStateThrowing()
            await reloadLibraryIndex()
            if quickNoteSessions.isEmpty { quickCapture.hide() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func ensureQuickNoteSession(preferredID: UUID?) async -> QuickNoteSessionRecord? {
        if let preferredID, let record = quickNoteSessions.first(where: { $0.id == preferredID }) { return record }
        if let activeQuickNoteRecord { return activeQuickNoteRecord }
        guard let created = await createQuickNoteSession() else { return nil }
        return quickNoteSessions.first { $0.id == created }
    }

    private func persistQuickNoteState() async {
        do { try await persistQuickNoteStateThrowing() }
        catch { errorMessage = error.localizedDescription }
    }

    private func persistQuickNoteStateThrowing() async throws {
        guard let metadataStore, let directory = quickNotesDirectoryPath else { return }
        try await metadataStore.saveQuickNoteState(
            directoryPath: directory,
            sessions: quickNoteSessions,
            activeSessionID: activeQuickNoteSessionID
        )
    }

    private func migrateQuickNotes(
        store: LibraryStore,
        metadataStore: MetadataStore
    ) async throws -> (directoryPath: String, sessions: [QuickNoteSessionRecord], activeSessionID: UUID?) {
        let state = await metadataStore.quickNoteState()
        let directory: String
        if let configured = state.directoryPath, await store.directoryExists(at: configured) {
            directory = configured
        } else if await store.directoryExists(at: "快速笔记") {
            directory = "快速笔记"
        } else {
            directory = try await store.createFolder(in: nil, title: "快速笔记")
        }

        var records: [QuickNoteSessionRecord] = []
        for record in state.sessions where record.relativePath.hasPrefix(directory + "/") {
            if await store.noteExists(at: record.relativePath) { records.append(record) }
        }
        var legacyPath = state.legacyPath
        if legacyPath == nil, await store.noteExists(at: "快速笔记.md") { legacyPath = "快速笔记.md" }
        if records.isEmpty, let legacyPath, await store.noteExists(at: legacyPath) {
            let migratedPath: String
            if legacyPath.hasPrefix(directory + "/") {
                migratedPath = legacyPath
            } else if let moved = try? await store.moveItem(at: legacyPath, into: directory) {
                migratedPath = moved
            } else {
                let renamed = try await store.renameItem(at: legacyPath, to: "迁移的快速笔记")
                migratedPath = try await store.moveItem(at: renamed, into: directory)
            }
            records = [QuickNoteSessionRecord(relativePath: migratedPath)]
        }
        if records.isEmpty {
            let path = try await store.createNote(in: directory, title: "未命名速记")
            records = [QuickNoteSessionRecord(relativePath: path)]
        }
        records.sort { $0.createdAt < $1.createdAt }
        let active = records.contains(where: { $0.id == state.activeSessionID })
            ? state.activeSessionID
            : records.first?.id
        try await metadataStore.saveQuickNoteState(
            directoryPath: directory,
            sessions: records,
            activeSessionID: active
        )
        return (directory, records, active)
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

    private func closePresentations(forReplacedPath path: String) async {
        await quickCapture.closeIfPresenting(path: path)
        await floatingNote.closeIfPresenting(path: path)
        stickyWindows.unpin(path: path)
    }

    private func removeRuntimeReferences(under path: String, replacingWith replacementPath: String) {
        sessions.removeValue(forKey: path)
        favoritePaths.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        recentPaths.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        recentSnapshotPaths.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        selectionHistory.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        selectionHistoryIndex = min(selectionHistoryIndex, selectionHistory.count - 1)

        let removedQuickIDs = Set(quickNoteSessions.filter {
            $0.relativePath == path || $0.relativePath.hasPrefix(path + "/")
        }.map(\.id))
        quickNoteSessions.removeAll {
            $0.relativePath == path || $0.relativePath.hasPrefix(path + "/")
        }
        if let activeQuickNoteSessionID, removedQuickIDs.contains(activeQuickNoteSessionID) {
            self.activeQuickNoteSessionID = nil
        }
        if selectedPath == path || selectedPath?.hasPrefix(path + "/") == true {
            selectedPath = replacementPath
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

    private func flattenedNotes(in nodes: [NoteNode]) -> [NoteNode] {
        nodes.flatMap { node -> [NoteNode] in
            (node.isDirectory ? [] : [node]) + flattenedNotes(in: node.children ?? [])
        }
    }

    private func recordSelection(_ path: String) {
        guard !isNavigatingHistory else { return }
        if selectionHistoryIndex >= 0, selectionHistory[selectionHistoryIndex] == path { return }
        if selectionHistoryIndex < selectionHistory.count - 1 {
            selectionHistory.removeSubrange((selectionHistoryIndex + 1) ..< selectionHistory.count)
        }
        selectionHistory.append(path)
        selectionHistoryIndex = selectionHistory.count - 1
    }

    private func navigateHistory(to path: String) async {
        isNavigatingHistory = true
        selectedPath = path
        _ = await session(for: path)
        isNavigatingHistory = false
    }

    private func remapNavigationReferences(from oldPath: String, to newPath: String) {
        func remap(_ path: String) -> String {
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { return path }
            return newPath + String(path.dropFirst(oldPath.count))
        }
        favoritePaths = favoritePaths.map(remap)
        recentPaths = recentPaths.map(remap)
        recentSnapshotPaths = recentSnapshotPaths.map(remap)
        quickNoteSessions = quickNoteSessions.map { record in
            var updated = record
            updated.relativePath = remap(record.relativePath)
            return updated
        }
        if activeQuickNoteSessionID == nil {
            activeQuickNoteSessionID = quickNoteSessions.first(where: { $0.relativePath == newPath })?.id
                ?? quickNoteSessions.first?.id
        }
        selectionHistory = selectionHistory.map(remap)
        persistNavigationState()
    }

    private func persistNavigationState() {
        guard let metadataStore else { return }
        let display = LibraryDisplayState(
            showsSidebar: showsSidebar,
            showsInspector: showsInspector,
            selectedSection: selectedSection.rawValue
        )
        Task {
            try? await metadataStore.saveNavigationState(
                favorites: favoritePaths,
                recents: recentPaths,
                display: display
            )
        }
    }

    private func refreshRecentSnapshot() {
        recentSnapshotPaths = allNotes.map(\.relativePath).sorted { lhs, rhs in
            let left = sessions[lhs]?.modifiedAt ?? noteMetrics[lhs]?.modifiedAt ?? .distantPast
            let right = sessions[rhs]?.modifiedAt ?? noteMetrics[rhs]?.modifiedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        recentSnapshotPaths = Array(recentSnapshotPaths.prefix(30))
    }
}
