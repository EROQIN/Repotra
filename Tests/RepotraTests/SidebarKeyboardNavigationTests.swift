@testable import Repotra
import Testing

@Suite("Sidebar keyboard navigation")
struct SidebarKeyboardNavigationTests {
    @Test("visible tree follows expansion state in depth-first order")
    func visibleTreeOrder() {
        let tree = [
            NoteNode(
                relativePath: "Folder",
                name: "Folder",
                isDirectory: true,
                children: [
                    NoteNode(relativePath: "Folder/A.md", name: "A.md", isDirectory: false),
                    NoteNode(
                        relativePath: "Folder/Nested",
                        name: "Nested",
                        isDirectory: true,
                        children: [
                            NoteNode(
                                relativePath: "Folder/Nested/B.md",
                                name: "B.md",
                                isDirectory: false
                            ),
                        ]
                    ),
                ]
            ),
            NoteNode(relativePath: "Root.md", name: "Root.md", isDirectory: false),
        ]

        #expect(SidebarNavigationItem.visibleTree(tree, expandedFolders: []).map(\.path) == [
            "Folder", "Root.md",
        ])
        let expanded = SidebarNavigationItem.visibleTree(
            tree,
            expandedFolders: ["Folder", "Folder/Nested"]
        )
        #expect(expanded.map(\.path) == [
            "Folder", "Folder/A.md", "Folder/Nested", "Folder/Nested/B.md", "Root.md",
        ])
        #expect(expanded[1].parentPath == "Folder")
        #expect(expanded[3].parentPath == "Folder/Nested")
    }

    @Test("arrows navigate visible rows without opening them")
    func arrowNavigation() {
        let items = navigationItems()
        var controller = SidebarKeyboardController()
        controller.reset(items: items, preferredID: "Folder")

        #expect(controller.handle(.down, items: items) == .none)
        #expect(controller.cursorID == "Folder/A.md")
        #expect(controller.handle(.end, items: items) == .none)
        #expect(controller.cursorID == "Root.md")
        #expect(controller.handle(.home, items: items) == .none)
        #expect(controller.cursorID == "Folder")
        #expect(controller.handle(.right, items: items) == .none)
        #expect(controller.cursorID == "Folder/A.md")
        #expect(controller.handle(.left, items: items) == .none)
        #expect(controller.cursorID == "Folder")
        #expect(controller.handle(.left, items: items) == .collapseFolder(path: "Folder"))
    }

    @Test("right expands a collapsed folder and left finds its parent")
    func folderNavigationActions() {
        let collapsed = [
            SidebarNavigationItem(path: "Folder", parentPath: nil, kind: .folder(isExpanded: false)),
            SidebarNavigationItem(path: "Root.md", parentPath: nil, kind: .note(isQuickNote: false)),
        ]
        var controller = SidebarKeyboardController()
        controller.reset(items: collapsed, preferredID: "Folder")
        #expect(controller.handle(.right, items: collapsed) == .expandFolder(path: "Folder"))

        let expanded = navigationItems()
        controller.reconcile(items: expanded)
        _ = controller.handle(.right, items: expanded)
        #expect(controller.cursorID == "Folder/A.md")
        #expect(controller.handle(.left, items: expanded) == .none)
        #expect(controller.cursorID == "Folder")
    }

    @Test("double Enter renames while repeats and expired presses do not")
    func doubleEnter() {
        let note = [
            SidebarNavigationItem(path: "A.md", parentPath: nil, kind: .note(isQuickNote: false)),
        ]
        var controller = SidebarKeyboardController()
        controller.reset(items: note, preferredID: "A.md")

        #expect(controller.handle(
            .enter(now: 1, doublePressInterval: 0.5, isRepeat: false),
            items: note
        ) == .openNote(path: "A.md", isQuickNote: false))
        #expect(controller.handle(
            .enter(now: 1.1, doublePressInterval: 0.5, isRepeat: true),
            items: note
        ) == .none)
        #expect(controller.handle(
            .enter(now: 1.2, doublePressInterval: 0.5, isRepeat: false),
            items: note
        ) == .rename(path: "A.md", isFolder: false))

        #expect(controller.handle(
            .enter(now: 2, doublePressInterval: 0.5, isRepeat: false),
            items: note
        ) == .openNote(path: "A.md", isQuickNote: false))
        #expect(controller.handle(
            .enter(now: 3, doublePressInterval: 0.5, isRepeat: false),
            items: note
        ) == .openNote(path: "A.md", isQuickNote: false))
    }

    @Test("moving the cursor clears the Enter sequence and remapping preserves selection")
    func sequenceResetAndRemap() {
        let items = [
            SidebarNavigationItem(path: "A.md", parentPath: nil, kind: .note(isQuickNote: false)),
            SidebarNavigationItem(path: "B.md", parentPath: nil, kind: .note(isQuickNote: false)),
        ]
        var controller = SidebarKeyboardController()
        controller.reset(items: items, preferredID: "A.md")
        _ = controller.handle(.enter(now: 1, doublePressInterval: 0.5, isRepeat: false), items: items)
        _ = controller.handle(.down, items: items)
        _ = controller.handle(.up, items: items)
        #expect(controller.handle(
            .enter(now: 1.2, doublePressInterval: 0.5, isRepeat: false),
            items: items
        ) == .openNote(path: "A.md", isQuickNote: false))

        controller.remap(from: "A.md", to: "Renamed.md")
        #expect(controller.cursorID == "Renamed.md")
    }

    @Test("Enter distinguishes folders and quick-note sessions")
    func enterActionsByKind() {
        let folder = [
            SidebarNavigationItem(path: "Folder", parentPath: nil, kind: .folder(isExpanded: false)),
        ]
        var controller = SidebarKeyboardController()
        controller.reset(items: folder, preferredID: "Folder")
        #expect(controller.handle(
            .enter(now: 1, doublePressInterval: 0.5, isRepeat: false),
            items: folder
        ) == .toggleFolder(path: "Folder"))
        #expect(controller.handle(
            .enter(now: 1.2, doublePressInterval: 0.5, isRepeat: false),
            items: folder
        ) == .rename(path: "Folder", isFolder: true))

        let quickNote = [
            SidebarNavigationItem(
                path: "快速笔记/会话.md",
                parentPath: nil,
                kind: .note(isQuickNote: true)
            ),
        ]
        controller.reset(items: quickNote, preferredID: "快速笔记/会话.md")
        #expect(controller.handle(
            .enter(now: 2, doublePressInterval: 0.5, isRepeat: false),
            items: quickNote
        ) == .openNote(path: "快速笔记/会话.md", isQuickNote: true))
    }

    private func navigationItems() -> [SidebarNavigationItem] {
        [
            SidebarNavigationItem(path: "Folder", parentPath: nil, kind: .folder(isExpanded: true)),
            SidebarNavigationItem(
                path: "Folder/A.md",
                parentPath: "Folder",
                kind: .note(isQuickNote: false)
            ),
            SidebarNavigationItem(path: "Root.md", parentPath: nil, kind: .note(isQuickNote: false)),
        ]
    }
}
