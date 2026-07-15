//
//  NativeTextViewCoordinator+CodeBlocks.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Tracks code-block selections in the document so the host can render the
//  small language/copy button overlay on top of every fenced code block,
//  including the active block so new fences expose the control immediately.
//

import AppKit

extension NativeTextViewCoordinator {
    func updateCodeBlockSelection(textView: NSTextView, tokens: [MarkdownToken]? = nil) {
        guard let textContainer = textView.textContainer else {
            onCodeBlockSelectionChange?([])
            return
        }

        if let tokens = tokens {
            cachedCodeBlockTokens = tokens.enumerated()
                .filter { $0.element.kind == .codeBlock }
                .map { (index: $0.offset, token: $0.element) }
        } else if cachedCodeBlockTokens.isEmpty {
            onCodeBlockSelectionChange?([])
            return
        }

        let nsText = textView.string as NSString
        let scrollOffset = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero

        // One-shot full-document layout per document; fixes stale Y from TextKit 2's lazy layout without per-update cost.
        if !didEnsureLayoutForCurrentDocument, let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            didEnsureLayoutForCurrentDocument = true
        }

        let selections: [CodeBlockSelection] = cachedCodeBlockTokens.compactMap { originalIndex, token in
            guard var boundingRect = textView.viewRect(forCharacterRange: token.range, using: layoutBridge) else { return nil }

            boundingRect.origin.x = textView.frame.origin.x + textView.textContainerOrigin.x - scrollOffset.x
            boundingRect.size.width = textContainer.containerSize.width

            return CodeBlockSelection(
                id: originalIndex,
                rect: boundingRect,
                language: MarkdownTokenizer.extractLanguage(from: token, in: textView.string),
                code: nsText.substring(with: token.contentRange)
            )
        }

        onCodeBlockSelectionChange?(selections)
    }
}
