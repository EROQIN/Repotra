import AppKit
import SwiftUI

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @State private var expandedFolders: Set<String> = []
    @State private var folderRenameTarget: NoteNode?
    @State private var folderRenameText = ""
    @State private var showsLibraryActions = false
    @State private var keyboardController = SidebarKeyboardController()
    @State private var isRestoringSidebarFocus = false
    @State private var isSidebarRenameActive = false
    @State private var sidebarHasKeyboardFocus = false
    @State private var sidebarFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            libraryHeader
            searchField
            primaryNavigation
            Divider().opacity(0.35).padding(.horizontal, 12)
            content
            bottomBar
        }
        .background(.ultraThinMaterial)
        .sheet(item: $folderRenameTarget, onDismiss: restoreSidebarFocus) { node in
            folderRenameSheet(node)
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.libraryURL?.lastPathComponent ?? "资料库")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("本地资料库").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { showsLibraryActions.toggle() } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RepotraHoverButtonStyle())
            .accessibilityLabel("资料库操作")
            .accessibilityIdentifier("library-actions")
            .help("资料库操作")
            .popover(isPresented: $showsLibraryActions, arrowEdge: .bottom) {
                libraryActionsPopover
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var libraryActionsPopover: some View {
        VStack(spacing: 2) {
            Button {
                showsLibraryActions = false
                model.presentLibraryPicker()
            } label: {
                sidebarActionLabel("切换资料库…", symbol: "folder")
            }
            Button {
                showsLibraryActions = false
                Task { await model.createFolder() }
            } label: {
                sidebarActionLabel("新建文件夹", symbol: "folder.badge.plus")
            }
            Divider().padding(.vertical, 3)
            SettingsLink {
                sidebarActionLabel("设置", symbol: "gearshape")
            }
            .simultaneousGesture(TapGesture().onEnded { showsLibraryActions = false })
        }
        .buttonStyle(RepotraHoverButtonStyle())
        .padding(6)
        .frame(width: 210)
    }

    private func sidebarActionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("搜索笔记", text: Binding(
                get: { model.searchQuery },
                set: { model.setSearchQuery($0) }
            ))
            .textFieldStyle(.plain)
            if !model.searchQuery.isEmpty {
                Button { model.setSearchQuery("") } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(RepotraHoverButtonStyle()).foregroundStyle(.tertiary)
            } else {
                Text("⌘F").font(.caption2).foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var primaryNavigation: some View {
        VStack(spacing: 2) {
            sectionRow(.quickNotes, "快速笔记", icon: "note.text", trailingAction: {
                Task {
                    if let id = await model.createQuickNoteSession() { await model.showQuickCapture(sessionID: id) }
                }
            })
            sectionRow(.recent, "最近编辑", icon: "clock")
            sectionRow(.all, "全部笔记", icon: "doc.on.doc")
            sectionRow(.favorites, "收藏", icon: "star")
            sectionRow(.library, "资料库", icon: "folder")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        ScrollViewReader { proxy in
            Group {
                if !model.searchQuery.isEmpty {
                    searchContent
                } else {
                    switch model.selectedSection {
                    case .quickNotes:
                        quickNotesContent
                    case .library:
                        ScrollView {
                            LazyVStack(spacing: 1) { treeRows(model.tree, level: 0) }
                                .padding(.horizontal, 7).padding(.vertical, 6)
                        }
                    case .recent:
                        flatList(paths: model.recentSnapshotPaths, emptyTitle: "还没有最近笔记")
                    case .all:
                        flatNodes(model.allNotes, emptyTitle: "资料库中还没有笔记")
                    case .favorites:
                        flatList(paths: model.favoritePaths, emptyTitle: "收藏的笔记会显示在这里")
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                SidebarKeyInputView(
                    focusRequest: sidebarFocusRequest,
                    onFocusChange: handleSidebarFocusChange,
                    onKeyDown: { event in handleKeyEvent(event, proxy: proxy) }
                )
                .frame(width: 1, height: 1)
            }
            .onAppear { reconcileKeyboardCursor(proxy: proxy) }
            .onChange(of: visibleNavigationItems.map(\.id)) { _, _ in
                reconcileKeyboardCursor(proxy: proxy)
            }
        }
    }

    private var visibleNavigationItems: [SidebarNavigationItem] {
        if !model.searchQuery.isEmpty {
            let quickPaths = Set(model.quickNoteSessions.map(\.relativePath))
            return SidebarNavigationItem.flatNotes(
                model.searchResults.map(\.relativePath),
                quickNotePaths: quickPaths
            )
        }
        switch model.selectedSection {
        case .quickNotes:
            let paths = model.quickNoteSessions.map(\.relativePath)
            return SidebarNavigationItem.flatNotes(paths, quickNotePaths: Set(paths))
        case .library:
            return SidebarNavigationItem.visibleTree(model.tree, expandedFolders: expandedFolders)
        case .recent:
            return SidebarNavigationItem.flatNotes(existingNotePaths(from: model.recentSnapshotPaths))
        case .all:
            return SidebarNavigationItem.flatNotes(model.allNotes.map(\.relativePath))
        case .favorites:
            return SidebarNavigationItem.flatNotes(existingNotePaths(from: model.favoritePaths))
        }
    }

    private var preferredKeyboardPath: String? {
        let visible = Set(visibleNavigationItems.map(\.id))
        if let selectedPath = model.selectedPath, visible.contains(selectedPath) { return selectedPath }
        if let quickPath = model.activeQuickNoteRecord?.relativePath, visible.contains(quickPath) { return quickPath }
        return nil
    }

    private func existingNotePaths(from paths: [String]) -> [String] {
        let existing = Set(model.allNotes.map(\.relativePath))
        return paths.filter(existing.contains)
    }

    private func isKeyboardSelected(_ path: String) -> Bool {
        sidebarHasKeyboardFocus && keyboardController.cursorID == path
    }

    private func reconcileKeyboardCursor(proxy: ScrollViewProxy) {
        keyboardController.reconcile(items: visibleNavigationItems, preferredID: preferredKeyboardPath)
        scrollToKeyboardCursor(proxy: proxy)
    }

    private func activateKeyboardCursor(_ path: String) {
        Task { @MainActor in
            requestSidebarFocus(preservingEnterSequence: false)
            keyboardController.select(id: path, in: visibleNavigationItems)
        }
    }

    private func openNormalNoteFromSidebar(_ path: String) {
        Task {
            keyboardController.select(id: path, in: visibleNavigationItems)
            isRestoringSidebarFocus = true
            await model.select(path: path)
            keyboardController.select(id: path, in: visibleNavigationItems)
            requestSidebarFocus(preservingEnterSequence: true)
        }
    }

    private func enterSection(_ section: AppModel.LibrarySection) {
        model.enterSection(section)
        keyboardController.reset(items: visibleNavigationItems, preferredID: preferredKeyboardPath)
        Task { @MainActor in requestSidebarFocus(preservingEnterSequence: false) }
    }

    private func handleKeyEvent(_ event: NSEvent, proxy: ScrollViewProxy) -> Bool {
        var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifiers.remove(.numericPad)
        modifiers.remove(.function)
        guard modifiers.isEmpty else { return false }
        let command: SidebarNavigationCommand
        switch event.keyCode {
        case 126: command = .up
        case 125: command = .down
        case 123: command = .left
        case 124: command = .right
        case 115: command = .home
        case 119: command = .end
        case 36, 76:
            command = .enter(
                now: event.timestamp,
                doublePressInterval: NSEvent.doubleClickInterval,
                isRepeat: event.isARepeat
            )
        default:
            return false
        }

        let previousCursor = keyboardController.cursorID
        let action = keyboardController.handle(command, items: visibleNavigationItems)
        performKeyboardAction(action)
        if previousCursor != keyboardController.cursorID {
            scrollToKeyboardCursor(proxy: proxy)
        }
        return true
    }

    private func performKeyboardAction(_ action: SidebarNavigationAction) {
        switch action {
        case .none:
            break
        case let .openNote(path, isQuickNote):
            if isQuickNote,
               let id = model.quickNoteSessions.first(where: { $0.relativePath == path })?.id {
                Task {
                    isRestoringSidebarFocus = true
                    await model.showQuickCapture(sessionID: id, activatesEditor: false)
                    requestSidebarFocus(preservingEnterSequence: true)
                }
            } else {
                Task {
                    isRestoringSidebarFocus = true
                    await model.select(path: path)
                    requestSidebarFocus(preservingEnterSequence: true)
                }
            }
        case let .toggleFolder(path):
            toggleFolder(path)
        case let .expandFolder(path):
            expandedFolders.insert(path)
        case let .collapseFolder(path):
            expandedFolders.remove(path)
        case let .rename(path, isFolder):
            if isFolder, let node = findNode(path: path, in: model.tree) {
                beginFolderRename(node)
            } else {
                model.sidebarTitleEditRequestPath = path
            }
        }
    }

    private func scrollToKeyboardCursor(proxy: ScrollViewProxy) {
        guard let cursorID = keyboardController.cursorID else { return }
        Task { @MainActor in proxy.scrollTo(cursorID) }
    }

    private func findNode(path: String, in nodes: [NoteNode]) -> NoteNode? {
        for node in nodes {
            if node.relativePath == path { return node }
            if let found = findNode(path: path, in: node.children ?? []) { return found }
        }
        return nil
    }

    private func noteRenameBegan(_ path: String) {
        keyboardController.select(id: path, in: visibleNavigationItems)
        keyboardController.clearEnterSequence()
        isSidebarRenameActive = true
        sidebarHasKeyboardFocus = false
    }

    private func noteRenameEnded(from oldPath: String, to newPath: String) {
        isSidebarRenameActive = false
        keyboardController.remap(from: oldPath, to: newPath)
        Task { @MainActor in
            keyboardController.reconcile(items: visibleNavigationItems, preferredID: newPath)
            requestSidebarFocus(preservingEnterSequence: false)
        }
    }

    private func treeRows(_ nodes: [NoteNode], level: Int) -> AnyView {
        AnyView(ForEach(nodes) { node in
            if node.isDirectory {
                FolderTreeRow(
                    node: node,
                    level: level,
                    expanded: expandedFolders.contains(node.relativePath),
                    isKeyboardSelected: isKeyboardSelected(node.relativePath),
                    onToggle: {
                        activateKeyboardCursor(node.relativePath)
                        toggleFolder(node.relativePath)
                    },
                    onRename: { beginFolderRename(node) },
                    onExpand: { expandedFolders.insert(node.relativePath) },
                    onDrop: { url in await model.move(droppedNoteURL: url, into: node.relativePath) }
                )
                .contextMenu { folderContextMenu(node) }
                .id(node.relativePath)
                if expandedFolders.contains(node.relativePath) {
                    treeRows(node.children ?? [], level: level + 1)
                }
            } else {
                NoteListRow(
                    path: node.relativePath,
                    title: node.title,
                    characterCount: model.characterCount(for: node.relativePath),
                    level: level,
                    isSelected: model.selectedPath == node.relativePath,
                    isFavorite: model.favoritePaths.contains(node.relativePath),
                    isQuickNote: false,
                    isKeyboardSelected: isKeyboardSelected(node.relativePath),
                    onSelect: { openNormalNoteFromSidebar(node.relativePath) },
                    onRenameBegan: { noteRenameBegan(node.relativePath) },
                    onRenameEnded: { noteRenameEnded(from: node.relativePath, to: $0) }
                )
                .contextMenu { noteContextMenu(path: node.relativePath) }
                .id(node.relativePath)
            }
        })
    }

    private var quickNotesContent: some View {
        Group {
            if model.quickNoteSessions.isEmpty {
                emptyMessage("新建一个快速笔记会话")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.quickNoteSessions) { record in
                            NoteListRow(
                                path: record.relativePath,
                                title: title(for: record.relativePath),
                                characterCount: model.characterCount(for: record.relativePath),
                                level: 0,
                                isSelected: model.activeQuickNoteSessionID == record.id,
                                isFavorite: false,
                                isQuickNote: true,
                                isKeyboardSelected: isKeyboardSelected(record.relativePath),
                                onSelect: {
                                    activateKeyboardCursor(record.relativePath)
                                    Task { await model.showQuickCapture(sessionID: record.id) }
                                },
                                onRenameBegan: { noteRenameBegan(record.relativePath) },
                                onRenameEnded: { noteRenameEnded(from: record.relativePath, to: $0) }
                            )
                            .contextMenu {
                                Button("重命名") { model.sidebarTitleEditRequestPath = record.relativePath }
                                Button("删除会话", role: .destructive) {
                                    Task { await model.deleteQuickNoteSession(id: record.id) }
                                }
                            }
                            .id(record.relativePath)
                        }
                    }
                    .padding(.horizontal, 7).padding(.vertical, 6)
                }
            }
        }
    }

    private var searchContent: some View {
        Group {
            if model.searchResults.isEmpty {
                VStack(spacing: 8) {
                    BrandSpotImage(name: "no-search-results").frame(width: 72, height: 72)
                    Text("没有匹配结果").font(.callout.weight(.medium))
                    Text("试试更短的关键词").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.searchResults) { result in
                            NoteListRow(
                                path: result.relativePath,
                                title: result.title,
                                subtitle: result.snippet,
                                characterCount: model.characterCount(for: result.relativePath),
                                level: 0,
                                isSelected: model.selectedPath == result.relativePath,
                                isFavorite: model.favoritePaths.contains(result.relativePath),
                                isQuickNote: model.isQuickNotePath(result.relativePath),
                                isKeyboardSelected: isKeyboardSelected(result.relativePath),
                                onSelect: {
                                    if model.isQuickNotePath(result.relativePath) {
                                        activateKeyboardCursor(result.relativePath)
                                        Task { await model.select(path: result.relativePath) }
                                    } else {
                                        openNormalNoteFromSidebar(result.relativePath)
                                    }
                                },
                                onRenameBegan: { noteRenameBegan(result.relativePath) },
                                onRenameEnded: { noteRenameEnded(from: result.relativePath, to: $0) }
                            )
                            .contextMenu { noteContextMenu(path: result.relativePath) }
                            .id(result.relativePath)
                        }
                    }
                    .padding(7)
                }
            }
        }
    }

    private func flatList(paths: [String], emptyTitle: String) -> some View {
        flatNodes(paths.compactMap { path in model.allNotes.first { $0.relativePath == path } }, emptyTitle: emptyTitle)
    }

    private func flatNodes(_ nodes: [NoteNode], emptyTitle: String) -> some View {
        Group {
            if nodes.isEmpty { emptyMessage(emptyTitle) }
            else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(nodes) { node in
                            NoteListRow(
                                path: node.relativePath,
                                title: node.title,
                                characterCount: model.characterCount(for: node.relativePath),
                                level: 0,
                                isSelected: model.selectedPath == node.relativePath,
                                isFavorite: model.favoritePaths.contains(node.relativePath),
                                isQuickNote: false,
                                isKeyboardSelected: isKeyboardSelected(node.relativePath),
                                onSelect: { openNormalNoteFromSidebar(node.relativePath) },
                                onRenameBegan: { noteRenameBegan(node.relativePath) },
                                onRenameEnded: { noteRenameEnded(from: node.relativePath, to: $0) }
                            )
                            .contextMenu { noteContextMenu(path: node.relativePath) }
                            .id(node.relativePath)
                        }
                    }
                    .padding(7)
                }
            }
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionRow(
        _ section: AppModel.LibrarySection,
        _ title: String,
        icon: String,
        trailingAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 0) {
            Button { enterSection(section) } label: {
                Label(title, systemImage: icon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 9).frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let trailingAction {
                Button(action: trailingAction) { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(RepotraHoverButtonStyle()).help("新建快速笔记")
            }
        }
        .padding(.trailing, trailingAction == nil ? 9 : 3)
        .repotraHoverFeedback(isSelected: model.selectedSection == section, cornerRadius: 7)
        .onTapGesture { enterSection(section) }
        .accessibilityIdentifier("navigation-\(section.rawValue)")
    }

    @ViewBuilder
    private func noteContextMenu(path: String) -> some View {
        if !model.isQuickNotePath(path) {
            Button(model.favoritePaths.contains(path) ? "取消收藏" : "收藏") {
                Task { await model.select(path: path); model.toggleFavorite() }
            }
        }
        Button("重命名") { model.sidebarTitleEditRequestPath = path }
        if let id = model.quickNoteSessions.first(where: { $0.relativePath == path })?.id {
            Button("删除会话", role: .destructive) { Task { await model.deleteQuickNoteSession(id: id) } }
        } else {
            Button("移到废纸篓", role: .destructive) { Task { await model.delete(path: path) } }
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ node: NoteNode) -> some View {
        Button("新建笔记") { Task { await model.createNote(in: node.relativePath) } }
        Button("新建文件夹") { Task { await model.createFolder(in: node.relativePath) } }
        Divider()
        Button("重命名…") { beginFolderRename(node) }
        Button("移到废纸篓", role: .destructive) { Task { await model.delete(path: node.relativePath) } }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button { Task { await model.createNote() } } label: {
                Label("新建笔记", systemImage: "square.and.pencil")
                    .padding(.horizontal, 5).frame(height: 28)
            }
            Button { Task { await model.createFolder() } } label: {
                Image(systemName: "folder.badge.plus").frame(width: 28, height: 28)
            }
                .help("新建文件夹")
            Spacer()
            SettingsLink { Image(systemName: "gearshape").frame(width: 28, height: 28) }.help("设置")
        }
        .buttonStyle(RepotraHoverButtonStyle()).font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 42)
        .overlay(alignment: .top) { Divider().opacity(0.35) }
    }

    private func toggleFolder(_ path: String) {
        if expandedFolders.contains(path) { expandedFolders.remove(path) }
        else { expandedFolders.insert(path) }
    }

    private func beginFolderRename(_ node: NoteNode) {
        keyboardController.select(id: node.relativePath, in: visibleNavigationItems)
        keyboardController.clearEnterSequence()
        isSidebarRenameActive = true
        folderRenameText = node.name
        folderRenameTarget = node
        sidebarHasKeyboardFocus = false
    }

    private func restoreSidebarFocus() {
        isSidebarRenameActive = false
        requestSidebarFocus(preservingEnterSequence: false)
    }

    private func requestSidebarFocus(preservingEnterSequence: Bool) {
        guard !isSidebarRenameActive else { return }
        if !preservingEnterSequence { keyboardController.clearEnterSequence() }
        isRestoringSidebarFocus = preservingEnterSequence
        sidebarFocusRequest &+= 1
    }

    private func handleSidebarFocusChange(_ focused: Bool) {
        sidebarHasKeyboardFocus = focused
        if focused {
            isRestoringSidebarFocus = false
        } else if !isRestoringSidebarFocus {
            keyboardController.clearEnterSequence()
        }
    }

    private func title(for path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func folderRenameSheet(_ node: NoteNode) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名文件夹").font(.headline)
            TextField("名称", text: $folderRenameText).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("folder-rename-field")
                .onSubmit { commitFolderRename(node) }
                .onExitCommand { folderRenameTarget = nil }
            HStack {
                Spacer()
                Button("取消") { folderRenameTarget = nil }
                Button("重命名") { commitFolderRename(node) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 380)
    }

    private func commitFolderRename(_ node: NoteNode) {
        let value = folderRenameText
        folderRenameTarget = nil
        Task {
            guard let newPath = await model.renamePath(path: node.relativePath, to: value) else {
                requestSidebarFocus(preservingEnterSequence: false)
                return
            }
            keyboardController.remap(from: node.relativePath, to: newPath)
            remapExpandedFolders(from: node.relativePath, to: newPath)
            keyboardController.reconcile(items: visibleNavigationItems, preferredID: newPath)
            requestSidebarFocus(preservingEnterSequence: false)
        }
    }

    private func remapExpandedFolders(from oldPath: String, to newPath: String) {
        expandedFolders = Set(expandedFolders.map { path in
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { return path }
            return newPath + path.dropFirst(oldPath.count)
        })
    }
}

private struct FolderTreeRow: View {
    let node: NoteNode
    let level: Int
    let expanded: Bool
    let isKeyboardSelected: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onExpand: () -> Void
    let onDrop: (URL) async -> Bool
    @State private var isTargeted = false
    @State private var hovering = false
    @State private var expandTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption).foregroundStyle(.tertiary).frame(width: 11)
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(node.title).lineLimit(1)
            Spacer()
        }
        .padding(.leading, CGFloat(level) * 14 + 7).padding(.trailing, 7)
        .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
        .background(
            isTargeted
                ? Color.accentColor.opacity(0.24)
                : (isKeyboardSelected
                    ? Color.accentColor.opacity(0.18)
                    : (hovering ? .primary.opacity(0.05) : .clear)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded(onRename)
                .exclusively(before: TapGesture(count: 1).onEnded(onToggle))
        )
        .onHover { hovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task {
                if await onDrop(url) { onExpand() }
            }
            return true
        } isTargeted: { isTargeted = $0 }
        .onChange(of: isTargeted) { _, targeted in
            expandTask?.cancel()
            guard targeted, !expanded else { return }
            expandTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                onExpand()
            }
        }
        .onDisappear {
            expandTask?.cancel()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isKeyboardSelected ? "键盘选中" : "")
        .accessibilityAction(named: "重命名") { onRename() }
        .accessibilityIdentifier("folder-row-\(node.relativePath)")
    }
}

private struct NoteListRow: View {
    @Environment(AppModel.self) private var model
    let path: String
    let title: String
    var subtitle: String? = nil
    let characterCount: Int
    let level: Int
    let isSelected: Bool
    let isFavorite: Bool
    let isQuickNote: Bool
    let isKeyboardSelected: Bool
    let onSelect: () -> Void
    let onRenameBegan: () -> Void
    let onRenameEnded: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var error: String?
    @State private var conflict: NoteRenameConflict?
    @State private var isRenaming = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: isQuickNote ? "note.text" : "doc.text").foregroundStyle(.tertiary)
                if editing {
                    TextField("笔记名", text: $draft)
                        .textFieldStyle(.plain).focused($focused)
                        .onSubmit { commit() }.onExitCommand { cancel() }
                } else {
                    Text(title).lineLimit(1)
                }
                Spacer(minLength: 5)
                Text("\(characterCount) ch").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                if isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary) }
            }
            if let subtitle, !editing {
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    .padding(.leading, 22)
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.red).padding(.leading, 22) }
        }
        .padding(.leading, CGFloat(level) * 14 + 7).padding(.trailing, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isKeyboardSelected
                ? Color.accentColor.opacity(0.20)
                : (isSelected
                    ? Color.accentColor.opacity(0.14)
                    : (hovering ? .primary.opacity(0.05) : .clear)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded { begin() }
                .exclusively(before: TapGesture(count: 1).onEnded {
                    if !editing { onSelect() }
                })
        )
        .onHover { hovering = $0 }
        .onChange(of: focused) { _, value in
            if !value, editing, conflict == nil, !isRenaming { commit() }
        }
        .onChange(of: model.sidebarTitleEditRequestPath) { _, value in
            guard value == path else { return }
            model.sidebarTitleEditRequestPath = nil
            begin()
        }
        .noteDraggable(
            url: model.libraryURL?.appending(path: path),
            title: title,
            enabled: !editing && !isQuickNote
        )
        .noteRenameConflictDialog(
            conflict: $conflict,
            onResolve: { resolution in
                conflict = nil
                commit(resolution: resolution)
            },
            onCancel: {
                conflict = nil
                Task { @MainActor in focused = true }
            }
        )
        .onChange(of: conflict) { oldValue, newValue in
            if oldValue != nil, newValue == nil, editing, !isRenaming {
                Task { @MainActor in focused = true }
            }
        }
        .accessibilityValue(isKeyboardSelected ? "键盘选中" : "")
        .accessibilityIdentifier("note-row-\(path)")
    }

    private func begin() {
        draft = title; error = nil; conflict = nil; editing = true
        onRenameBegan()
        Task { @MainActor in focused = true }
    }

    private func cancel(notifiesParent: Bool = true) {
        editing = false
        focused = false
        error = nil
        conflict = nil
        isRenaming = false
        if notifiesParent { onRenameEnded(path) }
    }

    private func commit(resolution: RenameConflictResolution? = nil) {
        guard editing, !isRenaming else { return }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validation = model.filenameValidationError(value) {
            error = validation; focused = true; return
        }
        guard value != title || resolution != nil else { cancel(); return }
        isRenaming = true
        Task {
            let outcome: NoteRenameOutcome
            if let id = model.quickNoteSessions.first(where: { $0.relativePath == path })?.id {
                outcome = await model.renameQuickNoteSession(
                    id: id,
                    to: value,
                    resolution: resolution
                )
            } else {
                outcome = await model.renameNote(path: path, to: value, resolution: resolution)
            }
            isRenaming = false
            switch outcome {
            case let .renamed(newPath):
                cancel(notifiesParent: false)
                onRenameEnded(newPath)
            case let .conflict(value):
                conflict = value
                focused = false
            case let .failed(message):
                error = message
                focused = true
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func noteDraggable(url: URL?, title: String, enabled: Bool) -> some View {
        if enabled, let url {
            draggable(url) {
                Label(title, systemImage: "doc.text")
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            }
        } else {
            self
        }
    }
}
