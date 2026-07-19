//
//  MarkdownStyler+TaskCheckboxes.swift
//  MarkdownEngine
//
//  Caret-crossing helper for GitHub-style `- [ ] / - [x]` task syntax. The
//  checkbox *styling* now lives in the AST styler (`MarkdownASTStyler`); this
//  only reports whether the caret sits inside the task syntax so the
//  coordinator can trigger a restyle when the caret enters/leaves.
//

import AppKit
import Foundation

extension MarkdownStyler {
    // MARK: Task Syntax Membership

    /// Full `<marker><spacer>[ ]` range if `location` is inside (or at the trailing edge of) it, else nil.
    static func taskSyntaxRange(at location: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        let safeLoc = max(0, min(location, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let line = nsText.substring(with: lineRange)
        guard let structure = MarkdownLineStructure.parseList(line),
              let checkbox = structure.checkboxRange else { return nil }
        let syntaxStart = lineRange.location + structure.markerRange.location
        let syntaxEnd = lineRange.location + NSMaxRange(checkbox)
        let syntaxRange = NSRange(location: syntaxStart, length: syntaxEnd - syntaxStart)
        if NSLocationInRange(location, syntaxRange) || location == syntaxEnd {
            return syntaxRange
        }
        return nil
    }
}
