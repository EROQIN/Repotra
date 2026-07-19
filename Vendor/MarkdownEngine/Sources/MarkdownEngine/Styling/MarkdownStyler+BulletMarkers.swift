//
//  MarkdownStyler+BulletMarkers.swift
//  MarkdownEngine
//
//  Caret-crossing helper for `-`/`*`/`+` bullet syntax. Bullet *rendering*
//  (the `•` overlay) now lives in the AST styler (`MarkdownASTStyler`); this
//  only reports caret membership so the coordinator can restyle on crossings.
//

import AppKit
import Foundation

extension MarkdownStyler {
    // MARK: Bullet Syntax Membership

    /// `<marker><spaces>` range on `location`'s line, or `nil` if the caret isn't strictly inside.
    static func bulletSyntaxRange(at location: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        let safeLoc = max(0, min(location, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let line = nsText.substring(with: lineRange)
        guard let structure = MarkdownLineStructure.parseList(line),
              structure.checkboxRange == nil,
              case .unordered = structure.kind else { return nil }
        let syntaxStart = lineRange.location + structure.syntaxRange.location
        let syntaxEnd = syntaxStart + structure.syntaxRange.length
        let syntaxRange = NSRange(location: syntaxStart, length: syntaxEnd - syntaxStart)
        if NSLocationInRange(location, syntaxRange) {
            return syntaxRange
        }
        return nil
    }
}
