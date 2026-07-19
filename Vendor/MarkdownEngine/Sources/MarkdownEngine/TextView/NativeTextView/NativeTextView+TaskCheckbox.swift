//
//  NativeTextView+TaskCheckbox.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Hit-test for `[ ]` / `[x]` checkbox glyphs and toggle the underlying text
//  + `.taskCheckbox` attribute, then nudge the coordinator to restyle the
//  enclosing paragraph.
//

import AppKit

extension NativeTextView {

    /// The drawn circular task control under `containerPoint`, if any.
    ///
    /// The `[ ]` chars are collapsed to ~zero width, so their bounding rect sits
    /// at the content edge; reconstruct the drawn circle from the shared
    /// `TaskCheckboxGeometry` (right-aligned to it). `baseFont`, not
    /// NSTextView.font (see the draw site). `searchRange` bounds the scan —
    /// the hovered line for cursor checks, nil (whole doc) for clicks.
    func taskCheckboxHit(at containerPoint: CGPoint, in searchRange: NSRange? = nil) -> (range: NSRange, isChecked: Bool)? {
        guard let textContainer = textContainer,
              let bridge = layoutBridge,
              let storage = textStorage, storage.length > 0 else { return nil }
        let boxSize = TaskCheckboxGeometry.size(for: baseFont)
        let scan = searchRange ?? NSRange(location: 0, length: storage.length)
        var hit: (range: NSRange, isChecked: Bool)?
        storage.enumerateAttribute(.taskCheckbox, in: scan, options: []) { value, attrRange, stop in
            guard let isChecked = value as? Bool else { return }
            let anchor = bridge.boundingRect(forCharacterRange: attrRange, in: textContainer)
            let visualRect = CGRect(
                x: TaskCheckboxGeometry.controlX(contentX: anchor.minX, size: boxSize),
                y: anchor.midY - boxSize / 2,
                width: boxSize,
                height: boxSize
            )
            if TaskCheckboxGeometry.hitRect(for: visualRect).contains(containerPoint) {
                hit = (attrRange, isChecked)
                stop.pointee = true
            }
        }
        return hit
    }

    func toggleTaskCheckboxIfHit(event: NSEvent) -> Bool? {
        guard let bridge = layoutBridge,
              let storage = textStorage else { return nil }
        let localPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )

        guard let (effectiveRange, hitIsChecked) = taskCheckboxHit(at: containerPoint) else { return nil }

        let nsText = storage.string as NSString
        let checkboxText = nsText.substring(with: effectiveRange)
        guard checkboxText.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil else { return nil }

        let replacement = hitIsChecked ? "[ ]" : "[x]"
        if shouldChangeText(in: effectiveRange, replacementString: replacement) {
            storage.replaceCharacters(in: effectiveRange, with: replacement)
            storage.addAttribute(.taskCheckbox, value: !hitIsChecked, range: effectiveRange)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: effectiveRange)
            didChangeText()
            bridge.invalidateDisplay(forCharacterRange: effectiveRange)
            if let coord = delegate as? NativeTextViewCoordinator {
                let paragraph = (storage.string as NSString).paragraphRange(for: effectiveRange)
                coord.restyleParagraphs([paragraph], in: self)
            }
        }
        return true
    }
}
