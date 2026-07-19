//
//  PerDocumentUndoTests.swift
//  MarkdownEngineTests
//
//  Per-`documentId` undo: a stable manager per document (Cmd+Z survives file
//  switches) and dropping a stale stack when the document's text was rewritten
//  while it was switched away. Headless.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct PerDocumentUndoTests {

    private final class TextBox {
        var value: String

        init(_ value: String = "") {
            self.value = value
        }
    }

    private func makeCoordinator(text: Binding<String> = .constant("")) -> NativeTextViewCoordinator {
        NativeTextViewCoordinator(
            text: text, fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
    }

    /// UndoManager with one registered action, so `canUndo` is deterministically true.
    private func populatedManager() -> UndoManager {
        let target = NSObject()
        let m = UndoManager()
        m.groupsByEvent = false
        m.beginUndoGrouping()
        m.registerUndo(withTarget: target) { _ in }
        m.endUndoGrouping()
        return m
    }

    @Test("Stable manager per document; distinct across; original returned on switch-back")
    func vendsStablePerDocumentManager() {
        let c = makeCoordinator()
        let tv = NativeTextView(frame: .zero)
        c.documentId = "A"
        let a = c.undoManager(for: tv)
        #expect(c.undoManager(for: tv) === a)
        c.documentId = "B"
        #expect(c.undoManager(for: tv) !== a)
        c.documentId = "A"
        #expect(c.undoManager(for: tv) === a)
    }

    @Test("Undo stack dropped only when the reloaded text diverged from the snapshot")
    func invalidatesOnlyOnDivergedContent() {
        let c = makeCoordinator()
        let m = populatedManager()
        c.undoManagers["A"] = m
        c.undoContentSnapshots["A"] = "hello"
        #expect(c.invalidateUndoIfContentDiverged(for: "A", incomingText: "hello") == false)
        #expect(m.canUndo) // unchanged → kept
        #expect(c.invalidateUndoIfContentDiverged(for: "A", incomingText: "hello world") == true)
        #expect(!m.canUndo) // diverged → dropped
    }

    @Test("No snapshot (first visit) never clears")
    func noSnapshotNeverClears() {
        let c = makeCoordinator()
        c.undoManagers["A"] = populatedManager()
        #expect(c.invalidateUndoIfContentDiverged(for: "A", incomingText: "x") == false)
    }

    @Test("Committed typing uses native character-sized undo steps")
    func committedTypingUndoGranularity() {
        _ = NSApplication.shared
        let c = makeCoordinator()
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.delegate = c
        tv.allowsUndo = true
        c.documentId = "A"
        c.textView = tv

        tv.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        tv.insertText("b", replacementRange: NSRange(location: 1, length: 0))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        #expect(tv.string == "ab")

        c.undoManager(for: tv)?.undo()
        #expect(tv.string == "a")
        c.undoManager(for: tv)?.undo()
        #expect(tv.string.isEmpty)
    }

    @Test("Task continuation and exit are separate native Undo steps")
    func taskReturnUndoGranularity() {
        _ = NSApplication.shared
        let c = makeCoordinator()
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.delegate = c
        tv.allowsUndo = true
        c.documentId = "task-return"
        c.textView = tv
        tv.string = "- [ ] 你好"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))

        tv.insertNewline(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        let continued = "- [ ] 你好\n- [ ] "
        #expect(tv.string == continued)

        tv.insertNewline(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        #expect(tv.string == "- [ ] 你好\n")

        let undo = c.undoManager(for: tv)
        undo?.undo()
        #expect(tv.string == continued)
        undo?.undo()
        #expect(tv.string == "- [ ] 你好")

        undo?.redo()
        #expect(tv.string == continued)
        undo?.redo()
        #expect(tv.string == "- [ ] 你好\n")
    }

    @Test("Rapid task Returns exit without waiting for a layout run loop")
    func rapidTaskReturns() {
        _ = NSApplication.shared
        let c = makeCoordinator()
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.delegate = c
        tv.allowsUndo = true
        c.documentId = "rapid-task-return"
        c.textView = tv
        tv.string = "- [ ] 你好"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))

        tv.insertNewline(nil)
        let afterFirst = tv.string
        let selectionAfterFirst = tv.selectedRange()
        tv.insertNewline(nil)

        #expect(
            tv.string == "- [ ] 你好\n",
            "first=\(afterFirst.debugDescription), selection=\(selectionAfterFirst), final=\(tv.string.debugDescription)"
        )
    }

    @Test("Newest queued text binding snapshot wins")
    func newestQueuedTextBindingSnapshotWins() async throws {
        let box = TextBox("initial")
        let binding = Binding(
            get: { box.value },
            set: { box.value = $0 }
        )
        let c = makeCoordinator(text: binding)
        c.documentId = "A"

        c.scheduleTextBindingSync("- [ ] 你好\n- [ ] ")
        c.scheduleTextBindingSync("- [ ] 你好\n")
        try await Task.sleep(for: .milliseconds(20))

        #expect(box.value == "- [ ] 你好\n")
        #expect(c.lastSyncedText == "- [ ] 你好\n")
    }

    @Test("Document transition invalidates a queued text binding write")
    func documentTransitionInvalidatesQueuedSync() async throws {
        let box = TextBox("current")
        let binding = Binding(
            get: { box.value },
            set: { box.value = $0 }
        )
        let c = makeCoordinator(text: binding)
        c.documentId = "A"

        c.scheduleTextBindingSync("stale A")
        c.documentId = "B"
        c.invalidatePendingTextBindingSync()
        try await Task.sleep(for: .milliseconds(20))

        #expect(box.value == "current")
    }

    @Test("System continuation after an empty task exit is rejected once")
    func rejectsDeferredSystemContinuationAfterTaskExit() {
        _ = NSApplication.shared
        let c = makeCoordinator()
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.delegate = c
        c.documentId = "system-continuation"
        c.textView = tv
        tv.string = "- [ ] "
        tv.setSelectedRange(NSRange(location: 6, length: 0))

        #expect(c.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(tv.string.isEmpty)
        #expect(
            !c.textView(
                tv,
                shouldChangeTextIn: NSRange(location: 0, length: 0),
                replacementString: "- "
            )
        )

        // The protection is one-shot; ordinary subsequent editing proceeds.
        #expect(
            c.textView(
                tv,
                shouldChangeTextIn: NSRange(location: 0, length: 0),
                replacementString: "- "
            )
        )
    }
}
