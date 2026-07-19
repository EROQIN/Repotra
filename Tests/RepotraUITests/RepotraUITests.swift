import XCTest

final class RepotraUITests: XCTestCase {
    func testPersonalizationSettingsExposeGlobalThemeAndEditorControls() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "--ui-testing"]
        app.launch()

        app.typeKey(",", modifierFlags: .command)
        let personalizationTab = app.buttons["个性化"]
        XCTAssertTrue(personalizationTab.waitForExistence(timeout: 3))
        personalizationTab.click()

        XCTAssertTrue(app.descendants(matching: .any)["appearance-interface-theme"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["appearance-accent"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["appearance-editor-font"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["appearance-editor-font-size"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["appearance-editor-reading-width"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["appearance-editor-canvas"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["appearance-background-kind"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["appearance-background-auto-text"].exists)
        XCTAssertTrue(app.buttons["appearance-reset"].exists)

        app.buttons["appearance-reset"].click()
    }

    func testWelcomeScreenCanChooseLibrary() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["选择资料库…"].waitForExistence(timeout: 3))
    }

    func testLibraryChooserOpensAsynchronouslyAndCanReopenAfterCancel() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "--ui-testing"]
        app.launch()

        let chooseButton = app.buttons["选择资料库…"]
        XCTAssertTrue(chooseButton.waitForExistence(timeout: 3))
        chooseButton.click()

        let cancelButton = app.buttons["取消"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3))
        cancelButton.click()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cancelButton)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)

        chooseButton.click()
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3))
        cancelButton.click()
    }

    func testQuickNoteSettingsAndToggleDoNotWriteAnEmptyCapture() throws {
        let libraryURL = FileManager.default.temporaryDirectory
            .appending(path: "RepotraUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing",
            "--ui-testing-library", libraryURL.path,
            "--show-quick-note",
        ]
        app.launch()

        let settings = app.buttons["quick-note-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        XCTAssertTrue(app.buttons["quick-note-settings-cancel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["quick-note-settings-done"].exists)
        XCTAssertTrue(app.buttons["高级设置"].exists)
        app.buttons["quick-note-settings-cancel"].click()

        app.typeKey("n", modifierFlags: [.command, .option])
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: settings
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)

        let quickDirectory = libraryURL.appending(path: "快速笔记", directoryHint: .isDirectory)
        let quickNoteURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: quickDirectory, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "md" })
        )
        XCTAssertEqual(try String(contentsOf: quickNoteURL, encoding: .utf8), "")
    }

    func testQuickNoteSlashPaletteOpensAndInsertsAtTheCaret() throws {
        let libraryURL = FileManager.default.temporaryDirectory
            .appending(path: "RepotraSlashUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing",
            "--ui-testing-library", libraryURL.path,
            "--show-quick-note",
        ]
        app.launch()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()

        editor.typeText("line/")
        XCTAssertFalse(app.descendants(matching: .any)["markdown-slash-palette"].exists)
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey(.delete, modifierFlags: [])

        editor.typeText("/")
        let palette = app.descendants(matching: .any)["markdown-slash-palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "", "行首 Slash 应被命令菜单消费")

        editor.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(palette.waitForExistence(timeout: 1))

        editor.typeText("/")
        let taskAction = app.buttons["markdown-slash-action-task-list"]
        XCTAssertTrue(taskAction.waitForExistence(timeout: 3))
        taskAction.click()
        app.typeText("todo")
        app.typeKey("n", modifierFlags: [.command, .option])

        let quickDirectory = libraryURL.appending(path: "快速笔记", directoryHint: .isDirectory)
        let quickNoteURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: quickDirectory, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "md" })
        )
        XCTAssertEqual(try String(contentsOf: quickNoteURL, encoding: .utf8), "- [ ] todo")
    }

    func testNoteRowUsesFullWidthHitTargetAndDoubleClickRenamesInline() throws {
        let libraryURL = FileManager.default.temporaryDirectory
            .appending(path: "RepotraRenameUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: libraryURL.appending(path: "Original.md"))
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing", "--ui-testing-library", libraryURL.path,
        ]
        app.launch()

        let row = app.descendants(matching: .any)["note-row-Original.md"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        row.doubleClick()

        let field = app.textFields["笔记名"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Renamed")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryURL.appending(path: "Renamed.md").path))
    }

    func testNoteCanBeDraggedIntoFolder() throws {
        let libraryURL = FileManager.default.temporaryDirectory
            .appending(path: "RepotraDragUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folderURL = libraryURL.appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("drag me".utf8).write(to: libraryURL.appending(path: "Draggable.md"))
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing", "--ui-testing-library", libraryURL.path,
        ]
        app.launch()

        let note = app.descendants(matching: .any)["note-row-Draggable.md"]
        let folder = app.descendants(matching: .any)["folder-row-Archive"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(folder.waitForExistence(timeout: 5))

        note.click(forDuration: 0.35, thenDragTo: folder)

        let movedNote = app.descendants(matching: .any)["note-row-Archive/Draggable.md"]
        XCTAssertTrue(movedNote.waitForExistence(timeout: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.appending(path: "Draggable.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryURL.appending(path: "Draggable.md").path))
    }

    func testFolderSingleClickTogglesAndDoubleClickRenames() throws {
        let libraryURL = FileManager.default.temporaryDirectory
            .appending(path: "RepotraFolderGestureUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folderURL = libraryURL.appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folderURL.appending(path: "Inside.md"))
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing", "--ui-testing-library", libraryURL.path,
        ]
        app.launch()

        let folder = app.descendants(matching: .any)["folder-row-Archive"]
        let child = app.descendants(matching: .any)["note-row-Archive/Inside.md"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertFalse(child.exists)

        folder.click()
        XCTAssertTrue(child.waitForExistence(timeout: 3))

        folder.doubleClick()
        let renameField = app.textFields["folder-rename-field"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 3))
        XCTAssertEqual(renameField.value as? String, "Archive")

        app.buttons["取消"].click()
        XCTAssertTrue(child.exists, "双击重命名不应同时折叠文件夹")

        folder.click()
        XCTAssertFalse(child.waitForExistence(timeout: 1))
    }

    func testSidebarKeyboardNavigationOpensAndRenamesVisibleRows() throws {
        let libraryURL = FileManager.default.temporaryDirectory
            .appending(path: "RepotraKeyboardUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: libraryURL.appending(path: "A.md"))
        try Data("bravo".utf8).write(to: libraryURL.appending(path: "B.md"))
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing", "--ui-testing-library", libraryURL.path,
        ]
        app.launch()

        let first = app.descendants(matching: .any)["note-row-A.md"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.click()
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 3))

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons["A"].exists, "方向键只移动侧栏游标，不应立即打开笔记")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["B"].waitForExistence(timeout: 3))

        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let renameField = app.textFields["笔记名"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 3))
        renameField.typeKey(.escape, modifierFlags: [])

        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 3))
    }

    func testSidebarKeyboardFolderNavigationAndDoubleEnterRename() throws {
        let libraryURL = FileManager.default.temporaryDirectory
            .appending(path: "RepotraKeyboardFolderUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folderURL = libraryURL.appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folderURL.appending(path: "Inside.md"))
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing", "--ui-testing-library", libraryURL.path,
        ]
        app.launch()

        let folder = app.descendants(matching: .any)["folder-row-Archive"]
        let child = app.descendants(matching: .any)["note-row-Archive/Inside.md"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.click()
        XCTAssertTrue(child.waitForExistence(timeout: 3))

        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textFields["folder-rename-field"].waitForExistence(timeout: 3))
        app.buttons["取消"].click()
        XCTAssertFalse(child.waitForExistence(timeout: 1))
    }

    func testRenameConflictCanKeepBothFromSidebar() throws {
        let libraryURL = FileManager.default.temporaryDirectory
            .appending(path: "RepotraRenameConflictUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: libraryURL.appending(path: "Draft.md"))
        try Data("existing".utf8).write(to: libraryURL.appending(path: "Final.md"))
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing", "--ui-testing-library", libraryURL.path,
        ]
        app.launch()

        let row = app.descendants(matching: .any)["note-row-Draft.md"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.doubleClick()
        let field = app.textFields["笔记名"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Final")
        field.typeKey(.return, modifierFlags: [])

        let keepBoth = app.buttons["保留两者"]
        XCTAssertTrue(keepBoth.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["覆盖已有笔记"].exists)
        XCTAssertTrue(app.buttons["取消"].exists)
        app.buttons["取消"].click()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "Final")
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryURL.appending(path: "Draft.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryURL.appending(path: "Final.md").path))

        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(keepBoth.waitForExistence(timeout: 3))
        keepBoth.click()

        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryURL.appending(path: "Final 2.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryURL.appending(path: "Final.md").path))
    }
}
