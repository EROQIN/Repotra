//
//  TaskCheckboxGeometry.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.07.26.
//
//  Shared geometry for the drawn circular task control. The hidden `[ ] ` chars
//  are collapsed to ~zero advance by the styler, so `drawPosition`/
//  `boundingRect` of the box range sit at the task CONTENT's left edge. The
//  control is right-aligned to that edge with a small gap (Obsidian-style),
//  occupying the `- ` marker slot. Fragment draw and click hit-test both use
//  these functions so their rects can't drift apart.
//

import AppKit

enum TaskCheckboxGeometry {

    /// Gap between the control's right edge and the task content's left edge.
    static let gap: CGFloat = 2.0

    /// Invisible expansion around the visual control for easier clicking.
    static let hitSlop: CGFloat = 3.0

    /// Diameter of the circle for the given (body) font.
    static func size(for font: NSFont) -> CGFloat {
        let ascent = max(0, font.ascender)
        let descent = max(0, -font.descender)
        let fontHeight = max(1, ceil(ascent + descent))
        let markerWidth = ("[ ]" as NSString).size(withAttributes: [.font: font]).width
        return max(1.0, min(floor(fontHeight * 1.2), floor(markerWidth * 1.2)))
    }

    /// Left edge of the control: right-aligned to the content start x with `gap`.
    static func controlX(contentX: CGFloat, size: CGFloat) -> CGFloat {
        contentX - size - gap
    }

    static func hitRect(for visualRect: CGRect) -> CGRect {
        visualRect.insetBy(dx: -hitSlop, dy: -hitSlop)
    }
}
