import Foundation

/// A single source of truth for editable Markdown block prefixes.
///
/// All ranges are UTF-16 offsets relative to the supplied physical line. The
/// parser deliberately distinguishes a bare marker (`-`, `1.`, `>`) from a
/// recognized empty structure (`- `, `1. `, `> `). Task boxes may terminate a
/// line without an additional space, because TextKit can place the caret on
/// either side of the collapsed post-checkbox gap in live preview.
enum MarkdownLineStructureKind: Equatable {
    case unordered(marker: String)
    case ordered(number: Int, delimiter: String)
    case quote(markers: String)
}

struct MarkdownLineStructure: Equatable {
    let kind: MarkdownLineStructureKind
    let indentationRange: NSRange
    let markerRange: NSRange
    let checkboxRange: NSRange?
    let isChecked: Bool
    let prefixRange: NSRange
    let contentRange: NSRange

    var isList: Bool {
        switch kind {
        case .unordered, .ordered: true
        case .quote: false
        }
    }

    var isQuote: Bool {
        if case .quote = kind { return true }
        return false
    }

    var syntaxRange: NSRange {
        let end = checkboxRange.map(NSMaxRange) ?? NSMaxRange(prefixRange)
        return NSRange(location: markerRange.location, length: end - markerRange.location)
    }

    func content(in line: String) -> String {
        let ns = line as NSString
        guard NSMaxRange(contentRange) <= ns.length else { return "" }
        return ns.substring(with: contentRange)
    }

    func contentIsEmpty(in line: String) -> Bool {
        content(in: line).trimmingCharacters(in: .whitespaces).isEmpty
    }

    func indentation(in line: String) -> String {
        let ns = line as NSString
        guard NSMaxRange(indentationRange) <= ns.length else { return "" }
        return ns.substring(with: indentationRange)
    }

    func continuationPrefix(in line: String) -> String {
        let indent = indentation(in: line)
        switch kind {
        case let .unordered(marker):
            return indent + marker + (checkboxRange == nil ? " " : " [ ] ")
        case let .ordered(number, delimiter):
            return indent + "\(number + 1)\(delimiter)" + (checkboxRange == nil ? " " : " [ ] ")
        case let .quote(markers):
            return indent + markers + " "
        }
    }

    static func parse(_ line: String) -> MarkdownLineStructure? {
        parseList(line) ?? parseQuote(line)
    }

    static func parseList(_ line: String) -> MarkdownLineStructure? {
        let ns = line as NSString
        let bodyEnd = lineBodyEnd(ns)
        var cursor = 0
        while cursor < bodyEnd, isHorizontalWhitespace(ns.character(at: cursor)) {
            cursor += 1
        }
        let indentation = NSRange(location: 0, length: cursor)
        let markerStart = cursor
        guard markerStart < bodyEnd else { return nil }

        let kind: MarkdownLineStructureKind
        let first = ns.character(at: cursor)
        if first == 0x2D || first == 0x2A || first == 0x2B { // - * +
            cursor += 1
            kind = .unordered(marker: ns.substring(with: NSRange(location: markerStart, length: 1)))
        } else if isDigit(first) {
            var value = 0
            var digits = 0
            while cursor < bodyEnd, isDigit(ns.character(at: cursor)), digits < 9 {
                value = value * 10 + Int(ns.character(at: cursor) - 0x30)
                cursor += 1
                digits += 1
            }
            guard digits > 0, cursor < bodyEnd else { return nil }
            let delimiter = ns.character(at: cursor)
            guard delimiter == 0x2E || delimiter == 0x29 else { return nil } // . or )
            cursor += 1
            kind = .ordered(
                number: value,
                delimiter: ns.substring(with: NSRange(location: cursor - 1, length: 1))
            )
        } else {
            return nil
        }

        let marker = NSRange(location: markerStart, length: cursor - markerStart)
        let separatorStart = cursor
        while cursor < bodyEnd, isHorizontalWhitespace(ns.character(at: cursor)) {
            cursor += 1
        }
        // A bare marker remains literal Markdown until horizontal whitespace
        // follows it.
        guard cursor > separatorStart else { return nil }

        var checkbox: NSRange?
        var checked = false
        if cursor + 2 < bodyEnd,
           ns.character(at: cursor) == 0x5B,
           ns.character(at: cursor + 2) == 0x5D { // [x]
            let state = ns.character(at: cursor + 1)
            let validState = state == 0x20 || state == 0x78 || state == 0x58
            let after = cursor + 3
            let validBoundary = after == bodyEnd
                || (after < bodyEnd && isHorizontalWhitespace(ns.character(at: after)))
            if validState && validBoundary {
                checkbox = NSRange(location: cursor, length: 3)
                checked = state == 0x78 || state == 0x58
                cursor = after
                while cursor < bodyEnd, isHorizontalWhitespace(ns.character(at: cursor)) {
                    cursor += 1
                }
            }
        }

        return MarkdownLineStructure(
            kind: kind,
            indentationRange: indentation,
            markerRange: marker,
            checkboxRange: checkbox,
            isChecked: checked,
            prefixRange: NSRange(location: 0, length: cursor),
            contentRange: NSRange(location: cursor, length: bodyEnd - cursor)
        )
    }

    static func parseQuote(_ line: String) -> MarkdownLineStructure? {
        let ns = line as NSString
        let bodyEnd = lineBodyEnd(ns)
        var cursor = 0
        while cursor < bodyEnd, cursor < 3, isHorizontalWhitespace(ns.character(at: cursor)) {
            cursor += 1
        }
        let indentation = NSRange(location: 0, length: cursor)
        let markerStart = cursor
        guard cursor < bodyEnd, ns.character(at: cursor) == 0x3E else { return nil } // >

        var markerEnd = cursor
        while cursor < bodyEnd, ns.character(at: cursor) == 0x3E {
            cursor += 1
            markerEnd = cursor

            let gapStart = cursor
            while cursor < bodyEnd, isHorizontalWhitespace(ns.character(at: cursor)) {
                cursor += 1
            }
            if cursor < bodyEnd, ns.character(at: cursor) == 0x3E {
                continue
            }

            // `>` / `>>` at end of line are bare markers. A trailing gap turns
            // them into an empty quote; immediate non-whitespace is quote body.
            if cursor == bodyEnd, gapStart == cursor { return nil }
            break
        }

        let marker = NSRange(location: markerStart, length: markerEnd - markerStart)
        let markers = ns.substring(with: marker)
        return MarkdownLineStructure(
            kind: .quote(markers: markers),
            indentationRange: indentation,
            markerRange: marker,
            checkboxRange: nil,
            isChecked: false,
            prefixRange: NSRange(location: 0, length: cursor),
            contentRange: NSRange(location: cursor, length: bodyEnd - cursor)
        )
    }

    private static func lineBodyEnd(_ line: NSString) -> Int {
        var end = line.length
        while end > 0 {
            let character = line.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return end
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 0x30 && character <= 0x39
    }
}
