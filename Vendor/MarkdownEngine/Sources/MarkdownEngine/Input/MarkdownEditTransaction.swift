import AppKit

enum MarkdownEditAction: Equatable {
    case insert(String)
    case hardBreak
    case indent
    case outdent
}

struct MarkdownEditContext {
    let source: String
    let affectedRange: NSRange
    let selectedRange: NSRange
    let maximumNestingLevel: Int
    let isInsideCodeBlock: Bool
    let autoClosePairsEnabled: Bool

    init(
        source: String,
        affectedRange: NSRange,
        selectedRange: NSRange,
        maximumNestingLevel: Int = 3,
        isInsideCodeBlock: Bool = false,
        autoClosePairsEnabled: Bool = true
    ) {
        self.source = source
        self.affectedRange = affectedRange
        self.selectedRange = selectedRange
        self.maximumNestingLevel = maximumNestingLevel
        self.isInsideCodeBlock = isInsideCodeBlock
        self.autoClosePairsEnabled = autoClosePairsEnabled
    }
}

struct MarkdownEditTransaction: Equatable {
    let replacementRange: NSRange
    let replacementText: String
    let selectionAfter: NSRange
    /// AppKit may schedule its own list continuation after Return even though
    /// this transaction already exited an empty Markdown structure. The native
    /// adapter uses this bit to reject that one redundant continuation only.
    let suppressesAutomaticContinuation: Bool

    init(
        replacementRange: NSRange,
        replacementText: String,
        selectionAfter: NSRange,
        suppressesAutomaticContinuation: Bool = false
    ) {
        self.replacementRange = replacementRange
        self.replacementText = replacementText
        self.selectionAfter = selectionAfter
        self.suppressesAutomaticContinuation = suppressesAutomaticContinuation
    }
}

enum MarkdownEditPlanner {
    private static let fenceRegex = try! NSRegularExpression(
        pattern: #"^```[A-Za-z0-9_+.-]*[ \t]*$"#
    )
    private static let openPairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
    ]

    static func transaction(
        for action: MarkdownEditAction,
        in context: MarkdownEditContext
    ) -> MarkdownEditTransaction? {
        let ns = context.source as NSString
        guard isValid(context.affectedRange, in: ns.length),
              isValid(context.selectedRange, in: ns.length) else { return nil }

        switch action {
        case let .insert(text):
            if text == "\n" { return newline(in: context) }
            if context.isInsideCodeBlock { return nil }
            if text == "\t" { return indentation(in: context, outdent: false) }
            if text.isEmpty {
                return (context.autoClosePairsEnabled ? pairedDeletion(in: context) : nil)
                    ?? structureBackspace(in: context)
            }
            return context.autoClosePairsEnabled ? pairedInsertion(text, in: context) : nil
        case .hardBreak:
            if context.isInsideCodeBlock { return replacing(context.selectedRange, with: "\n") }
            return hardBreak(in: context)
        case .indent:
            return indentation(in: context, outdent: false)
        case .outdent:
            return indentation(in: context, outdent: true)
        }
    }

    private static func newline(in context: MarkdownEditContext) -> MarkdownEditTransaction {
        let ns = context.source as NSString
        let selection = context.selectedRange
        if selection.length > 0 {
            return replacing(selection, with: "\n")
        }

        let info = lineInfo(in: ns, at: selection.location)
        let line = ns.substring(with: info.bodyRange)
        let localCaret = selection.location - info.bodyRange.location
        let lineEnd = info.bodyRange.location + info.bodyRange.length

        if info.bodyRange.location == 0, line == "---", selection.location == lineEnd {
            return replacing(context.affectedRange, with: "\n\n---", caretOffset: 1)
        }

        if selection.location == lineEnd,
           fenceRegex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil,
           isOpeningFence(at: info.bodyRange.location, in: ns),
           !hasClosingFence(after: info.fullRange, in: ns)
        {
            return replacing(context.affectedRange, with: "\n\n```", caretOffset: 1)
        }

        if context.isInsideCodeBlock {
            return replacing(context.affectedRange, with: "\n")
        }

        if let structure = MarkdownLineStructure.parse(line) {
            // An empty structure has no meaningful split position. Live
            // preview collapses task syntax and TextKit may report the caret
            // anywhere inside that prefix, so semantic emptiness—not a visual
            // caret boundary—decides whether Return exits the structure.
            if structure.contentIsEmpty(in: line) {
                let indentation = structure.indentation(in: line)
                if structure.isList, !indentation.isEmpty {
                    let removal = oneIndentRemoval(in: indentation)
                    return replacing(
                        NSRange(location: info.bodyRange.location, length: removal),
                        with: "",
                        selectionLocation: max(info.bodyRange.location, selection.location - removal)
                    )
                }
                return replacing(
                    NSRange(location: info.bodyRange.location, length: structure.prefixRange.length),
                    with: "",
                    selectionLocation: info.bodyRange.location,
                    suppressesAutomaticContinuation: true
                )
            }

            if localCaret >= NSMaxRange(structure.prefixRange) {
                return replacing(
                    context.affectedRange,
                    with: "\n" + structure.continuationPrefix(in: line)
                )
            }
        }

        return replacing(context.affectedRange, with: "\n")
    }

    private static func hardBreak(in context: MarkdownEditContext) -> MarkdownEditTransaction {
        let ns = context.source as NSString
        let info = lineInfo(in: ns, at: context.selectedRange.location)
        let line = ns.substring(with: info.bodyRange)
        if let structure = MarkdownLineStructure.parseList(line) {
            let continuationIndent = String(repeating: " ", count: max(2, structure.prefixRange.length))
            return replacing(context.selectedRange, with: "  \n" + continuationIndent)
        }
        if let structure = MarkdownLineStructure.parseQuote(line) {
            return replacing(context.selectedRange, with: "  \n" + structure.continuationPrefix(in: line))
        }
        return replacing(context.selectedRange, with: "  \n")
    }

    private static func pairedInsertion(
        _ text: String,
        in context: MarkdownEditContext
    ) -> MarkdownEditTransaction? {
        guard text.utf16.count == 1, let character = text.first else { return nil }
        let ns = context.source as NSString
        let selected = context.selectedRange

        if openPairs[character] == character, selected.length == 0,
           selected.location < ns.length,
           ns.substring(with: NSRange(location: selected.location, length: 1)) == text
        {
            return MarkdownEditTransaction(
                replacementRange: NSRange(location: selected.location, length: 0),
                replacementText: "",
                selectionAfter: NSRange(location: selected.location + 1, length: 0)
            )
        }

        if let close = openPairs[character] {
            let selectedText = ns.substring(with: selected)
            let replacement = String(character) + selectedText + String(close)
            return MarkdownEditTransaction(
                replacementRange: selected,
                replacementText: replacement,
                selectionAfter: NSRange(
                    location: selected.location + 1,
                    length: selected.length
                )
            )
        }

        if openPairs.values.contains(character), selected.length == 0,
           selected.location < ns.length,
           ns.substring(with: NSRange(location: selected.location, length: 1)) == text
        {
            return MarkdownEditTransaction(
                replacementRange: NSRange(location: selected.location, length: 0),
                replacementText: "",
                selectionAfter: NSRange(location: selected.location + 1, length: 0)
            )
        }
        return nil
    }

    private static func pairedDeletion(in context: MarkdownEditContext) -> MarkdownEditTransaction? {
        let ns = context.source as NSString
        let selection = context.selectedRange
        guard selection.length == 0,
              context.affectedRange.length == 1,
              context.affectedRange.location + 1 == selection.location,
              selection.location < ns.length else { return nil }
        let opening = ns.substring(with: context.affectedRange).first
        let closing = ns.substring(with: NSRange(location: selection.location, length: 1)).first
        guard let opening, let closing, openPairs[opening] == closing else { return nil }
        return MarkdownEditTransaction(
            replacementRange: NSRange(location: context.affectedRange.location, length: 2),
            replacementText: "",
            selectionAfter: NSRange(location: context.affectedRange.location, length: 0)
        )
    }

    private static func structureBackspace(in context: MarkdownEditContext) -> MarkdownEditTransaction? {
        let ns = context.source as NSString
        let selection = context.selectedRange
        guard selection.length == 0, context.affectedRange.length == 1 else { return nil }
        let info = lineInfo(in: ns, at: selection.location)
        let line = ns.substring(with: info.bodyRange)
        guard let structure = MarkdownLineStructure.parse(line),
              selection.location == info.bodyRange.location + NSMaxRange(structure.prefixRange) else { return nil }
        let indentation = structure.indentation(in: line)
        if !indentation.isEmpty {
            let removal = oneIndentRemoval(in: indentation)
            return replacing(
                NSRange(location: info.bodyRange.location, length: removal),
                with: "",
                selectionLocation: selection.location - removal
            )
        }
        return replacing(
            NSRange(location: info.bodyRange.location, length: structure.prefixRange.length),
            with: "",
            selectionLocation: info.bodyRange.location
        )
    }

    private static func indentation(
        in context: MarkdownEditContext,
        outdent: Bool
    ) -> MarkdownEditTransaction? {
        let ns = context.source as NSString
        var range = ns.lineRange(for: context.selectedRange)
        if context.selectedRange.length > 0,
           NSMaxRange(context.selectedRange) == NSMaxRange(range),
           range.length > 0 {
            range = ns.lineRange(for: NSRange(
                location: context.selectedRange.location,
                length: max(0, context.selectedRange.length - 1)
            ))
        }
        let source = ns.substring(with: range) as NSString
        var cursor = 0
        var pieces: [String] = []
        var edits: [(location: Int, delta: Int)] = []
        var hasStructure = false

        while cursor < source.length {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            let line = source.substring(with: lineRange)
            let body = line.trimmingCharacters(in: .newlines)
            let isStructured = MarkdownLineStructure.parse(body) != nil
            if !body.isEmpty && !isStructured { return nil }
            hasStructure = hasStructure || isStructured

            if outdent {
                let removal = leadingIndentRemoval(in: line)
                pieces.append((line as NSString).substring(from: removal))
                if removal > 0 { edits.append((range.location + cursor, -removal)) }
            } else {
                let level = MarkdownLists.indentLevel(from: String(line.prefix { $0 == " " || $0 == "\t" }))
                guard level < context.maximumNestingLevel else { return nil }
                pieces.append("\t" + line)
                edits.append((range.location + cursor, 1))
            }
            cursor = NSMaxRange(lineRange)
        }
        guard hasStructure else { return nil }
        let mapped = mapSelection(context.selectedRange, through: edits)
        return MarkdownEditTransaction(
            replacementRange: range,
            replacementText: pieces.joined(),
            selectionAfter: mapped
        )
    }

    private static func lineInfo(
        in text: NSString,
        at location: Int
    ) -> (fullRange: NSRange, bodyRange: NSRange) {
        let safe = min(max(0, location), text.length)
        let full = text.lineRange(for: NSRange(location: safe, length: 0))
        var body = full
        while body.length > 0 {
            let last = text.character(at: NSMaxRange(body) - 1)
            guard last == 0x0A || last == 0x0D else { break }
            body.length -= 1
        }
        return (full, body)
    }

    private static func replacing(
        _ range: NSRange,
        with text: String,
        caretOffset: Int? = nil,
        selectionLocation: Int? = nil,
        suppressesAutomaticContinuation: Bool = false
    ) -> MarkdownEditTransaction {
        let location = selectionLocation ?? (range.location + (caretOffset ?? text.utf16.count))
        return MarkdownEditTransaction(
            replacementRange: range,
            replacementText: text,
            selectionAfter: NSRange(location: location, length: 0),
            suppressesAutomaticContinuation: suppressesAutomaticContinuation
        )
    }

    private static func isOpeningFence(at lineStart: Int, in text: NSString) -> Bool {
        let prefix = text.substring(to: lineStart)
        let fenceCount = prefix.components(separatedBy: "```").count - 1
        return fenceCount.isMultiple(of: 2)
    }

    private static func hasClosingFence(after lineRange: NSRange, in text: NSString) -> Bool {
        guard NSMaxRange(lineRange) < text.length else { return false }
        return text.substring(from: NSMaxRange(lineRange)).contains("```")
    }

    private static func oneIndentRemoval(in whitespace: String) -> Int {
        whitespace.hasPrefix("\t") ? 1 : min(2, whitespace.prefix { $0 == " " }.count)
    }

    private static func leadingIndentRemoval(in line: String) -> Int {
        if line.hasPrefix("\t") { return 1 }
        return min(2, line.prefix { $0 == " " }.count)
    }

    private static func mapSelection(_ selection: NSRange, through edits: [(location: Int, delta: Int)]) -> NSRange {
        func map(_ location: Int) -> Int {
            location + edits.filter { $0.location < location || ($0.location == location && $0.delta > 0) }
                .reduce(0) { $0 + $1.delta }
        }
        let start = max(0, map(selection.location))
        let end = max(start, map(NSMaxRange(selection)))
        return NSRange(location: start, length: end - start)
    }

    private static func isValid(_ range: NSRange, in length: Int) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length
    }
}
