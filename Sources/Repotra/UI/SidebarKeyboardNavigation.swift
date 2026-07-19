import Foundation

struct SidebarNavigationItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case folder(isExpanded: Bool)
        case note(isQuickNote: Bool)
    }

    let path: String
    let parentPath: String?
    let kind: Kind

    var id: String { path }
    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    var isExpandedFolder: Bool {
        if case let .folder(isExpanded) = kind { return isExpanded }
        return false
    }

    var isQuickNote: Bool {
        if case let .note(isQuickNote) = kind { return isQuickNote }
        return false
    }

    static func visibleTree(
        _ nodes: [NoteNode],
        expandedFolders: Set<String>,
        parentPath: String? = nil
    ) -> [SidebarNavigationItem] {
        nodes.flatMap { node -> [SidebarNavigationItem] in
            if node.isDirectory {
                let expanded = expandedFolders.contains(node.relativePath)
                let folder = SidebarNavigationItem(
                    path: node.relativePath,
                    parentPath: parentPath,
                    kind: .folder(isExpanded: expanded)
                )
                guard expanded else { return [folder] }
                return [folder] + visibleTree(
                    node.children ?? [],
                    expandedFolders: expandedFolders,
                    parentPath: node.relativePath
                )
            }
            return [SidebarNavigationItem(
                path: node.relativePath,
                parentPath: parentPath,
                kind: .note(isQuickNote: false)
            )]
        }
    }

    static func flatNotes(_ paths: [String], quickNotePaths: Set<String> = []) -> [SidebarNavigationItem] {
        paths.map { path in
            SidebarNavigationItem(
                path: path,
                parentPath: nil,
                kind: .note(isQuickNote: quickNotePaths.contains(path))
            )
        }
    }
}

enum SidebarNavigationCommand: Equatable, Sendable {
    case up
    case down
    case left
    case right
    case home
    case end
    case enter(now: TimeInterval, doublePressInterval: TimeInterval, isRepeat: Bool)
}

enum SidebarNavigationAction: Equatable, Sendable {
    case none
    case openNote(path: String, isQuickNote: Bool)
    case toggleFolder(path: String)
    case expandFolder(path: String)
    case collapseFolder(path: String)
    case rename(path: String, isFolder: Bool)
}

struct SidebarKeyboardController: Equatable, Sendable {
    private(set) var cursorID: String?
    private(set) var cursorIndexHint = 0
    private var lastEnterID: String?
    private var lastEnterTime: TimeInterval?

    mutating func reconcile(items: [SidebarNavigationItem], preferredID: String? = nil) {
        guard !items.isEmpty else {
            cursorID = nil
            cursorIndexHint = 0
            clearEnterSequence()
            return
        }
        if let cursorID, let index = items.firstIndex(where: { $0.id == cursorID }) {
            cursorIndexHint = index
            return
        }
        if let preferredID, let index = items.firstIndex(where: { $0.id == preferredID }) {
            setCursor(items[index].id, index: index)
            return
        }
        let index = min(max(cursorIndexHint, 0), items.count - 1)
        setCursor(items[index].id, index: index)
    }

    mutating func select(id: String, in items: [SidebarNavigationItem]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        setCursor(id, index: index)
    }

    mutating func reset(items: [SidebarNavigationItem], preferredID: String? = nil) {
        cursorID = nil
        cursorIndexHint = 0
        clearEnterSequence()
        reconcile(items: items, preferredID: preferredID)
    }

    mutating func remap(from oldID: String, to newID: String) {
        if cursorID == oldID { cursorID = newID }
        if lastEnterID == oldID { lastEnterID = newID }
    }

    mutating func clearEnterSequence() {
        lastEnterID = nil
        lastEnterTime = nil
    }

    mutating func handle(
        _ command: SidebarNavigationCommand,
        items: [SidebarNavigationItem]
    ) -> SidebarNavigationAction {
        reconcile(items: items)
        guard !items.isEmpty, let currentIndex else { return .none }

        switch command {
        case .up:
            move(to: max(0, currentIndex - 1), items: items)
        case .down:
            move(to: min(items.count - 1, currentIndex + 1), items: items)
        case .home:
            move(to: 0, items: items)
        case .end:
            move(to: items.count - 1, items: items)
        case .right:
            let current = items[currentIndex]
            guard current.isFolder else { return .none }
            if !current.isExpandedFolder {
                clearEnterSequence()
                return .expandFolder(path: current.path)
            }
            if currentIndex + 1 < items.count, items[currentIndex + 1].parentPath == current.path {
                move(to: currentIndex + 1, items: items)
            }
        case .left:
            let current = items[currentIndex]
            if current.isExpandedFolder {
                clearEnterSequence()
                return .collapseFolder(path: current.path)
            }
            if let parentPath = current.parentPath,
               let parentIndex = items.firstIndex(where: { $0.id == parentPath }) {
                move(to: parentIndex, items: items)
            }
        case let .enter(now, interval, isRepeat):
            guard !isRepeat else { return .none }
            let current = items[currentIndex]
            if lastEnterID == current.id,
               let lastEnterTime,
               now - lastEnterTime >= 0,
               now - lastEnterTime <= interval {
                clearEnterSequence()
                return .rename(path: current.path, isFolder: current.isFolder)
            }
            lastEnterID = current.id
            lastEnterTime = now
            if current.isFolder { return .toggleFolder(path: current.path) }
            return .openNote(path: current.path, isQuickNote: current.isQuickNote)
        }
        return .none
    }

    private var currentIndex: Int? { cursorID.map { _ in cursorIndexHint } }

    private mutating func move(to index: Int, items: [SidebarNavigationItem]) {
        guard items.indices.contains(index) else { return }
        setCursor(items[index].id, index: index)
    }

    private mutating func setCursor(_ id: String, index: Int) {
        if cursorID != id { clearEnterSequence() }
        cursorID = id
        cursorIndexHint = index
    }
}
