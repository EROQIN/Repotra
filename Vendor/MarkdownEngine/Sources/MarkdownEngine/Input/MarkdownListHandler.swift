import AppKit

struct MarkdownLists {
    static func indentLevel(from leadingWhitespace: String) -> Int {
        let tabCount = leadingWhitespace.filter { $0 == "\t" }.count
        let spaceCount = leadingWhitespace.filter { $0 == " " }.count
        return tabCount + (spaceCount / 2)
    }

    static func performEdit(
        _ textView: NSTextView,
        transaction: MarkdownEditTransaction
    ) {
        guard let coordinator = textView.delegate as? NativeTextViewCoordinator else { return }
        // A planned Markdown edit is one user action even when it replaces a
        // whole prefix. Keep it isolated from adjacent typing/Return events so
        // native Undo never merges two structural actions.
        textView.breakUndoCoalescing()
        coordinator.isProgrammaticEdit = true
        coordinator.pendingEditedRange = NSRange(
            location: transaction.replacementRange.location,
            length: transaction.replacementText.utf16.count
        )
        defer { coordinator.isProgrammaticEdit = false }

        guard textView.shouldChangeText(
            in: transaction.replacementRange,
            replacementString: transaction.replacementText
        ) else { return }
        textView.textStorage?.replaceCharacters(
            in: transaction.replacementRange,
            with: transaction.replacementText
        )
        textView.setSelectedRange(transaction.selectionAfter)
        if transaction.suppressesAutomaticContinuation {
            coordinator.pendingAutomaticContinuationSuppression = (
                location: transaction.selectionAfter.location,
                expiresAt: ProcessInfo.processInfo.systemUptime + 0.5
            )
        } else {
            coordinator.pendingAutomaticContinuationSuppression = nil
        }
        textView.didChangeText()
        textView.breakUndoCoalescing()
        textView.scrollRangeToVisible(transaction.selectionAfter)
    }

    static func performEdit(_ textView: NSTextView, replace range: NSRange, with string: String) {
        performEdit(
            textView,
            transaction: MarkdownEditTransaction(
                replacementRange: range,
                replacementText: string,
                selectionAfter: NSRange(location: range.location + string.utf16.count, length: 0)
            )
        )
    }

    static func blockquoteContinuedPaste(_ pasted: String, at location: Int, in document: String) -> String {
        guard pasted.contains("\n") else { return pasted }
        let ns = document as NSString
        guard location >= 0, location <= ns.length else { return pasted }
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        let line = ns.substring(with: lineRange)
        guard let structure = MarkdownLineStructure.parseQuote(line) else { return pasted }
        return pasted.replacingOccurrences(of: "\n", with: "\n" + structure.continuationPrefix(in: line))
    }

    static func handleInsertion(
        textView: NSTextView,
        affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard let replacementString else { return true }
        let configuration = (textView as? NativeTextView)?.configuration ?? .default
        guard configuration.lists.helpersEnabled,
              !textView.hasMarkedText() else { return true }
        let insideCode = textView.string.contains("`") && MarkdownDetection.isInsideCodeBlock(
            location: min(affectedCharRange.location, (textView.string as NSString).length),
            in: textView.string
        )

        let context = MarkdownEditContext(
            source: textView.string,
            affectedRange: affectedCharRange,
            selectedRange: textView.selectedRange(),
            maximumNestingLevel: configuration.lists.maximumNestingLevel,
            isInsideCodeBlock: insideCode,
            autoClosePairsEnabled: configuration.lists.autoClosePairsEnabled
        )
        guard let transaction = MarkdownEditPlanner.transaction(
            for: .insert(replacementString),
            in: context
        ) else { return true }
        performEdit(textView, transaction: transaction)
        return false
    }
}
