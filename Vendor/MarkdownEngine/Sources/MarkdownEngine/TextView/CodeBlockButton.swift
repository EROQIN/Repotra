//
//  CodeBlockButton.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 15.12.25
//  Purpose: Shows a small copy button overlay for each code block.
//

import SwiftUI

/// Position and content of a single fenced code block currently visible in
/// the editor.
///
/// Delivered to embedders through
/// ``NativeTextViewWrapper/onCodeBlockSelectionChange`` so they can overlay
/// a copy button (see ``CodeBlockButton``) at the right place.
public struct CodeBlockSelection: Identifiable, Sendable {
    /// Index of the source token, stable for as long as the block exists.
    public let id: Int
    /// Frame of the rendered code block in the text view's coordinate space.
    public let rect: CGRect
    /// Language tag declared after the opening fence (`` ```swift ``).
    public let language: String?
    /// Plain text content of the block, suitable for putting on the
    /// pasteboard.
    public let code: String

    /// Uppercased language label shown by the copy control. Unspecified
    /// fenced blocks deliberately use `TEXT` instead of an empty label.
    public var displayLanguage: String {
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "TEXT" : value.uppercased()
    }

    public init(id: Int, rect: CGRect, language: String?, code: String) {
        self.id = id
        self.rect = rect
        self.language = language
        self.code = code
    }
}

/// Drop-in SwiftUI overlay that renders a small copy-to-pasteboard button
/// in the top-right corner of a fenced code block.
///
/// Embedders typically place one of these per ``CodeBlockSelection`` they
/// receive from the editor. The view positions itself absolutely using
/// ``CodeBlockSelection/rect``.
public struct CodeBlockButton: View {
    /// The code block this button is attached to.
    public let selection: CodeBlockSelection
    /// Vertical inset from the code block's top edge, in points. Positive
    /// values push the button down into the code block.
    public let topInset: CGFloat
    /// Horizontal inset from the code block's trailing edge, in points.
    /// Positive values keep the button inside the code block; negative
    /// values let it overflow into a parent's gutter (the legacy Nodes
    /// look).
    public let trailingInset: CGFloat
    /// Closure invoked when the user clicks the button.
    public let onCopy: () -> Void
    /// Lets the host briefly acknowledge a completed copy operation.
    public let isCopied: Bool

    public init(
        selection: CodeBlockSelection,
        topInset: CGFloat = 6,
        trailingInset: CGFloat = 8,
        isCopied: Bool = false,
        onCopy: @escaping () -> Void
    ) {
        self.selection = selection
        self.topInset = topInset
        self.trailingInset = trailingInset
        self.isCopied = isCopied
        self.onCopy = onCopy
    }

    public var body: some View {
        // Invisible frame matching code block position & size
        Color.clear
            .frame(width: selection.rect.width, height: selection.rect.height)
            .overlay(alignment: .topTrailing) {
                Button(action: onCopy) {
                    Text(isCopied ? "已复制" : selection.displayLanguage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.82))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("复制 \(selection.displayLanguage) 代码")
                .padding(.top, topInset)
                .padding(.trailing, trailingInset)
            }
            .position(
                x: selection.rect.midX,
                y: selection.rect.midY
            )
    }
}
