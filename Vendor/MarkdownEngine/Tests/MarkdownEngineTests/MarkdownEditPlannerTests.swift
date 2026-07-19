import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Obsidian-style Markdown edit transactions")
struct MarkdownEditPlannerTests {
    private func insertion(
        _ source: String,
        at location: Int,
        text: String,
        selectionLength: Int = 0,
        insideCode: Bool = false
    ) -> MarkdownEditTransaction? {
        let selection = NSRange(location: location, length: selectionLength)
        return MarkdownEditPlanner.transaction(
            for: .insert(text),
            in: MarkdownEditContext(
                source: source,
                affectedRange: selection,
                selectedRange: selection,
                isInsideCodeBlock: insideCode
            )
        )
    }

    private func applying(_ transaction: MarkdownEditTransaction, to source: String) -> String {
        (source as NSString).replacingCharacters(
            in: transaction.replacementRange,
            with: transaction.replacementText
        )
    }

    private func enter(
        _ source: String,
        at location: Int? = nil
    ) throws -> (source: String, caret: Int) {
        let caret = location ?? (source as NSString).length
        let transaction = try #require(insertion(source, at: caret, text: "\n"))
        return (applying(transaction, to: source), transaction.selectionAfter.location)
    }

    @Test("bare dash stays literal and moves to a new line")
    func bareDashEnter() throws {
        let transaction = try #require(insertion("-", at: 1, text: "\n"))
        #expect(applying(transaction, to: "-") == "-\n")
        #expect(transaction.selectionAfter == NSRange(location: 2, length: 0))
    }

    @Test("bare dash cannot consume an existing trailing newline")
    func bareDashBeforeExistingNewline() throws {
        let source = "-\nnext"
        let transaction = try #require(insertion(source, at: 1, text: "\n"))
        #expect(applying(transaction, to: source) == "-\n\nnext")
        #expect(transaction.selectionAfter.location == 2)
    }

    @Test("empty recognized list exits while non-empty list continues")
    func listEnterBehavior() throws {
        let empty = try #require(insertion("- ", at: 2, text: "\n"))
        #expect(applying(empty, to: "- ") == "")
        #expect(empty.selectionAfter.location == 0)

        let content = "- item"
        let continued = try #require(insertion(content, at: 6, text: "\n"))
        #expect(applying(continued, to: content) == "- item\n- ")
        #expect(continued.selectionAfter.location == 9)
    }

    @Test("ordered and task items continue with human defaults")
    func orderedAndTaskContinuation() throws {
        let ordered = "9. item"
        let orderedTransaction = try #require(insertion(ordered, at: 7, text: "\n"))
        #expect(applying(orderedTransaction, to: ordered) == "9. item\n10. ")

        let task = "- [x] done"
        let taskTransaction = try #require(insertion(task, at: 10, text: "\n"))
        #expect(applying(taskTransaction, to: task) == "- [x] done\n- [ ] ")
    }

    @Test("a continued task exits cleanly on the second return")
    func taskReturnSequence() throws {
        let first = try enter("- [ ] 你好")
        #expect(first.source == "- [ ] 你好\n- [ ] ")
        #expect(first.caret == (first.source as NSString).length)

        let second = try enter(first.source, at: first.caret)
        #expect(second.source == "- [ ] 你好\n")
        #expect(second.caret == (second.source as NSString).length)

        let third = try enter(second.source, at: second.caret)
        #expect(third.source == "- [ ] 你好\n\n")
        #expect(third.caret == (third.source as NSString).length)
    }

    @Test("empty tasks exit with or without a trailing gap")
    func emptyTaskVariantsExit() throws {
        for source in ["- [ ]", "- [ ] ", "- [x]", "* [ ]", "+ [X]", "1. [ ]", "1) [x]"] {
            let result = try enter(source)
            #expect(result.source.isEmpty, "failed to exit \(source.debugDescription)")
            #expect(result.caret == 0)
        }

        // Live preview collapses the gap after `[ ]`; TextKit may report the
        // caret at the checkbox edge instead of after that gap.
        let collapsedGap = try enter("- [ ] ", at: 5)
        #expect(collapsedGap.source.isEmpty)
        #expect(collapsedGap.caret == 0)
    }

    @Test("empty task exit does not depend on a collapsed-prefix caret offset")
    func emptyTaskExitsFromEveryReportedCaretOffset() throws {
        let source = "- [ ] "
        for caret in 0...(source as NSString).length {
            let result = try enter(source, at: caret)
            #expect(result.source.isEmpty, "caret \(caret) did not exit the task")
            #expect(result.caret == 0)
        }
    }

    @Test("task-like text without a separating gap remains ordinary list content")
    func taskLikeTextIsNotTask() throws {
        let result = try enter("- [ ]text")
        #expect(result.source == "- [ ]text\n- ")
    }

    @Test("parenthesized ordered items continue and exit")
    func parenthesizedOrderedItems() throws {
        let continued = try enter("9) item")
        #expect(continued.source == "9) item\n10) ")
        let exited = try enter("9) ")
        #expect(exited.source.isEmpty)
    }

    @Test("all bare markers stay literal")
    func bareMarkersStayLiteral() throws {
        for source in ["-", "*", "+", "1.", "1)", ">"] {
            let result = try enter(source)
            #expect(result.source == source + "\n")
        }
    }

    @Test("empty root structures exit consistently")
    func emptyRootStructuresExit() throws {
        for source in ["- ", "* ", "+ ", "1. ", "1) ", "> ", ">> "] {
            let result = try enter(source)
            #expect(result.source.isEmpty, "failed to exit \(source.debugDescription)")
        }
    }

    @Test("return in the middle splits the item without losing its tail")
    func splitListItem() throws {
        let source = "- hello world"
        let transaction = try #require(insertion(source, at: 7, text: "\n"))
        #expect(applying(transaction, to: source) == "- hello\n-  world")
    }

    @Test("empty nested item outdents one level before exiting")
    func nestedEmptyItemOutdents() throws {
        let source = "\t- "
        let transaction = try #require(insertion(source, at: 3, text: "\n"))
        #expect(applying(transaction, to: source) == "- ")
        #expect(transaction.selectionAfter.location == 2)
    }

    @Test("empty nested task outdents before it exits")
    func nestedEmptyTaskOutdentsThenExits() throws {
        let first = try enter("\t- [ ] ")
        #expect(first.source == "- [ ] ")
        let second = try enter(first.source, at: first.caret)
        #expect(second.source.isEmpty)
        #expect(second.caret == 0)
    }

    @Test("backspace uses the same task and quote prefixes")
    func structuredBackspace() throws {
        func backspace(_ source: String, caret: Int) throws -> MarkdownEditTransaction {
            try #require(MarkdownEditPlanner.transaction(
                for: .insert(""),
                in: MarkdownEditContext(
                    source: source,
                    affectedRange: NSRange(location: caret - 1, length: 1),
                    selectedRange: NSRange(location: caret, length: 0)
                )
            ))
        }

        let task = try backspace("- [ ] text", caret: 6)
        #expect(applying(task, to: "- [ ] text") == "text")
        #expect(task.selectionAfter.location == 0)

        let quote = try backspace("> text", caret: 2)
        #expect(applying(quote, to: "> text") == "text")

        let nested = try backspace("\t- [ ] text", caret: 7)
        #expect(applying(nested, to: "\t- [ ] text") == "- [ ] text")
    }

    @Test("indentation actions share the structure classifier")
    func structuredIndentation() throws {
        let source = "- [ ] one\n1) two\n> quote"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        let indented = try #require(MarkdownEditPlanner.transaction(
            for: .indent,
            in: MarkdownEditContext(source: source, affectedRange: selection, selectedRange: selection)
        ))
        let indentedSource = applying(indented, to: source)
        #expect(indentedSource == "\t- [ ] one\n\t1) two\n\t> quote")

        let indentedSelection = NSRange(location: 0, length: (indentedSource as NSString).length)
        let outdented = try #require(MarkdownEditPlanner.transaction(
            for: .outdent,
            in: MarkdownEditContext(
                source: indentedSource,
                affectedRange: indentedSelection,
                selectedRange: indentedSelection
            )
        ))
        #expect(applying(outdented, to: indentedSource) == source)
    }

    @Test("hard breaks retain their current list or quote block")
    func structuredHardBreaks() throws {
        let task = "- [ ] item"
        let taskBreak = try #require(MarkdownEditPlanner.transaction(
            for: .hardBreak,
            in: MarkdownEditContext(
                source: task,
                affectedRange: NSRange(location: 10, length: 0),
                selectedRange: NSRange(location: 10, length: 0)
            )
        ))
        #expect(applying(taskBreak, to: task) == "- [ ] item  \n      ")

        let quote = "> quote"
        let quoteBreak = try #require(MarkdownEditPlanner.transaction(
            for: .hardBreak,
            in: MarkdownEditContext(
                source: quote,
                affectedRange: NSRange(location: 7, length: 0),
                selectedRange: NSRange(location: 7, length: 0)
            )
        ))
        #expect(applying(quoteBreak, to: quote) == "> quote  \n> ")
    }

    @Test("front matter and code fences create editable skeletons")
    func blockSkeletons() throws {
        let frontMatter = try #require(insertion("---", at: 3, text: "\n"))
        #expect(applying(frontMatter, to: "---") == "---\n\n---")
        #expect(frontMatter.selectionAfter.location == 4)

        let fenceSource = "```swift"
        let fence = try #require(insertion(fenceSource, at: 8, text: "\n", insideCode: true))
        #expect(applying(fence, to: fenceSource) == "```swift\n\n```")
        #expect(fence.selectionAfter.location == 9)
    }

    @Test("pairs wrap selections, skip closers, and delete together")
    func autoPairs() throws {
        let wrapped = try #require(insertion("word", at: 0, text: "(", selectionLength: 4))
        #expect(applying(wrapped, to: "word") == "(word)")
        #expect(wrapped.selectionAfter == NSRange(location: 1, length: 4))

        let skipped = try #require(insertion("()", at: 1, text: ")"))
        #expect(applying(skipped, to: "()") == "()")
        #expect(skipped.selectionAfter.location == 2)

        let skippedQuote = try #require(insertion("\"\"", at: 1, text: "\""))
        #expect(applying(skippedQuote, to: "\"\"") == "\"\"")
        #expect(skippedQuote.selectionAfter.location == 2)

        let deletion = try #require(MarkdownEditPlanner.transaction(
            for: .insert(""),
            in: MarkdownEditContext(
                source: "()",
                affectedRange: NSRange(location: 0, length: 1),
                selectedRange: NSRange(location: 1, length: 0)
            )
        ))
        #expect(applying(deletion, to: "()") == "")
        #expect(deletion.selectionAfter.location == 0)
    }

    @Test("hard break does not create a second list item")
    func hardBreak() throws {
        let source = "- item"
        let transaction = try #require(MarkdownEditPlanner.transaction(
            for: .hardBreak,
            in: MarkdownEditContext(
                source: source,
                affectedRange: NSRange(location: 6, length: 0),
                selectedRange: NSRange(location: 6, length: 0)
            )
        ))
        #expect(applying(transaction, to: source).hasPrefix("- item  \n"))
        #expect(!applying(transaction, to: source).contains("\n- "))
    }
}
