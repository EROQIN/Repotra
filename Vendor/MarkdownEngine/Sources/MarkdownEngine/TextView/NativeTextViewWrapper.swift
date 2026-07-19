//
//  NativeTextViewWrapper.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Brings the editor into SwiftUI and wires up the text view with the
// right setup, styling, and callbacks.
//
// Public selection / replacement value types live in
// `NativeTextViewSelectionTypes.swift`.
import SwiftUI
import AppKit

/// SwiftUI bridge for MarkdownEngine's AppKit-backed editor.
///
/// Wraps a TextKit 2 `NSTextView` inside an `NSScrollView` and exposes a
/// SwiftUI-friendly API of bindings (text, link state, replacement requests)
/// and callback closures (link clicks, caret movement, inline-selection and
/// code-block change notifications). All visual styling and external
/// dependencies are routed through ``MarkdownEditorConfiguration``.
///
/// ### Fit-to-content height
///
/// Set ``MarkdownEditorConfiguration/heightBehavior`` to `.fitsContent` to
/// make the editor report its content height to SwiftUI instead of scrolling
/// internally. Wrap the editor in a `ScrollView` so the page scrolls:
///
/// ```swift
/// ScrollView {
///     NativeTextViewWrapper(
///         text: $text,
///         configuration: .init(heightBehavior: .fitsContent)
///     )
/// }
/// ```
///
/// In `.fitsContent` mode the editor grows/shrinks per keystroke, scroll-
/// wheel events pass through to the enclosing scroller, and caret visibility
/// propagates to the enclosing (page-level) scroll view. The reading column
/// (`readingWidth`) composes naturally. See ``MarkdownEditorConfiguration/HeightBehavior``
/// for the full behavior contract and trade-offs.
public struct NativeTextViewWrapper: NSViewRepresentable {
    public typealias Coordinator = NativeTextViewCoordinator
    public typealias NSViewType = NSScrollView

    /// Two-way binding to the document text in storage form
    /// (`[[Name|<id>]]` for wiki-links). The engine keeps display and
    /// storage forms in sync internally.
    @Binding public var text: String
    /// Becomes `true` while the caret is inside a `[[Name]]` link's content
    /// range, so embedders can show a contextual UI (e.g. a popover).
    @Binding public var isWikiLinkActive: Bool
    /// Push a replacement into the editor by setting this to a non-nil value;
    /// the engine applies it on the next update and then clears the binding.
    @Binding public var pendingInlineReplacement: InlineReplacementRequest?
    /// The full editor configuration (theme + services + style toggles). Engine
    /// embedders construct this themselves and pass it in; the wrapper does
    /// not read UserDefaults or know about app-specific colors/services.
    public var configuration: MarkdownEditorConfiguration
    /// PostScript name of the base font used for body text.
    public var fontName: String
    /// Base font size in points. Headings, code blocks, and LaTeX are scaled
    /// off this value via ``MarkdownEditorConfiguration``.
    public var fontSize: CGFloat
    /// Opaque document identifier. Each value keeps its own undo stack and
    /// per-document editor state across switching away and back; the undo stack is
    /// dropped only if the document's text changes while it is switched away. Set a
    /// stable, unique value per document so undo/replacements stay scoped.
    public var documentId: String
    /// When `false` the editor renders read-only with no caret.
    public var isEditable: Bool
    /// Places the caret at the end after the initial document is laid out.
    /// Useful for append-only capture surfaces; ignored on later updates.
    public var startsAtDocumentEnd: Bool
    /// A host-controlled one-shot token. Whenever the value changes, the
    /// existing editor becomes first responder and places the caret at the
    /// document end without rebuilding text storage or its undo manager.
    public var focusRequest: Int
    /// A monotonic host token for source navigation. When it changes, the
    /// existing text view moves its insertion point to `navigationLocation`
    /// and scrolls there without rebuilding storage or replacing its undo stack.
    public var navigationRequest: Int
    public var navigationLocation: Int
    /// Optional paste hook. Return a Markdown image-embed string (e.g.
    /// `"![[my-image]]"`) to insert at the caret, or `nil` to fall through
    /// to the system's default plain-text paste.
    public var onPasteImage: ((NSPasteboard) -> String?)?
    /// Called when `/` is typed at the beginning of a line. The slash is
    /// consumed so the host can present a Markdown block command palette.
    public var onSlashCommand: (() -> Void)?
    /// Geometry-aware Slash command callback. The supplied rect is the caret
    /// in the editor scroll viewport's coordinate space, suitable for placing
    /// a host-owned follow-the-caret palette. When supplied, this callback is
    /// preferred over ``onSlashCommand``.
    public var onSlashCommandAtCaret: ((CGRect) -> Void)?
    /// Keyboard routing for a host-owned slash command palette.
    public var onCommandPaletteKey: ((InlinePreviewKey) -> Bool)?
    public var onFocusChange: ((Bool) -> Void)?

    /// Fires when the user clicks a `[[Name]]` link. The argument is the
    /// resolved opaque identifier (or the display name when no resolver
    /// was supplied).
    public var onLinkClick: ((String) -> Void)?
    /// Fires whenever the caret rect inside an active wiki-link changes,
    /// so embedders can position a follow-the-caret UI.
    public var onCaretRectChange: ((CGRect) -> Void)?
    /// Fires after every selection change in source coordinates.
    public var onSelectionChange: ((NSRange) -> Void)?
    /// Build the editor's right-click menu (the engine ships no menu). Receives the default
    /// NSMenu + the current selection range; return the menu to display (or unchanged).
    public var onBuildContextMenu: ((NSMenu, NSRange) -> NSMenu)?
    /// Fires when the caret enters or leaves a `[[Name]]` or `![[…]]`
    /// token. `nil` means the caret is no longer inside such a token.
    public var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    /// Fires on ↑/↓/Enter/Esc while an inline `[[…]]` preview is open, so the
    /// embedder can drive its autocomplete list. Return `true` to consume the key.
    public var onInlinePreviewKey: ((InlinePreviewKey) -> Bool)?
    /// Fires when the set of visible code blocks changes, so embedders can
    /// overlay copy buttons (see ``CodeBlockButton``).
    public var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
    /// Fires after the user toggles any of the three spell/grammar/auto-correction
    /// menu items. Embedders persist the policy and pass it back via
    /// ``MarkdownEditorConfiguration/spellChecking`` on next launch.
    public var onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)?

    /// Ghost text shown at the first-line position while the document is empty;
    /// the first typed character hides it. Lives inside the scrolled content, so
    /// it sits below the header band and tracks its expand/collapse animation.
    public var placeholder: NSAttributedString?

    /// SwiftUI header hosted above the body and scrolling with it. The engine owns
    /// an `NSHostingView`, reserves its (intrinsic) height at the top of the text
    /// content, and refreshes the hosted content on every SwiftUI update. The header
    /// is a sibling of the text view in the scrolled container, so it is fully
    /// interactive. Inject any required SwiftUI environment into this content
    /// before passing it in.
    public var header: AnyView?
    /// Visible header height when collapsed — typically just the top row. Content
    /// below this is clipped. The embedder measures and supplies it so the top row
    /// stays fully visible while the lower content reveals/hides.
    public var headerCollapsedHeight: CGFloat
    /// Whether the header is expanded to its full content height or collapsed to
    /// ``headerCollapsedHeight``. Toggling animates the reveal.
    public var headerExpanded: Bool

    /// documentIds whose scroll offset to keep; others are forgotten. `nil` keeps all.
    public var retainedScrollDocumentIds: Set<String>?

    /// Embedder-supplied predicate that suppresses the I-beam cursor in edit mode.
    /// Called on mouse-move with the event location in window coordinates.
    /// Return `true` to show the arrow cursor instead of the I-beam.
    public var isCursorExcluded: ((CGPoint) -> Bool)?

    public init(
        text: Binding<String>,
        isWikiLinkActive: Binding<Bool> = .constant(false),
        pendingInlineReplacement: Binding<InlineReplacementRequest?> = .constant(nil),
        configuration: MarkdownEditorConfiguration = .default,
        fontName: String = "SF Pro",
        fontSize: CGFloat = 16,
        documentId: String = "default",
        isEditable: Bool = true,
        startsAtDocumentEnd: Bool = false,
        focusRequest: Int = 0,
        navigationRequest: Int = 0,
        navigationLocation: Int = 0,
        onPasteImage: ((NSPasteboard) -> String?)? = nil,
        onSlashCommand: (() -> Void)? = nil,
        onSlashCommandAtCaret: ((CGRect) -> Void)? = nil,
        onCommandPaletteKey: ((InlinePreviewKey) -> Bool)? = nil,
        onFocusChange: ((Bool) -> Void)? = nil,
        onLinkClick: ((String) -> Void)? = nil,
        onCaretRectChange: ((CGRect) -> Void)? = nil,
        onSelectionChange: ((NSRange) -> Void)? = nil,
        onBuildContextMenu: ((NSMenu, NSRange) -> NSMenu)? = nil,
        onInlineSelectionChange: ((InlineSelectionState?) -> Void)? = nil,
        onInlinePreviewKey: ((InlinePreviewKey) -> Bool)? = nil,
        onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)? = nil,
        onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)? = nil,
        placeholder: NSAttributedString? = nil,
        header: AnyView? = nil,
        headerCollapsedHeight: CGFloat = 0,
        headerExpanded: Bool = true,
        retainedScrollDocumentIds: Set<String>? = nil,
        isCursorExcluded: ((CGPoint) -> Bool)? = nil
    ) {
        self._text = text
        self._isWikiLinkActive = isWikiLinkActive
        self._pendingInlineReplacement = pendingInlineReplacement
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.documentId = documentId
        self.isEditable = isEditable
        self.startsAtDocumentEnd = startsAtDocumentEnd
        self.focusRequest = focusRequest
        self.navigationRequest = navigationRequest
        self.navigationLocation = navigationLocation
        self.onPasteImage = onPasteImage
        self.onSlashCommand = onSlashCommand
        self.onSlashCommandAtCaret = onSlashCommandAtCaret
        self.onCommandPaletteKey = onCommandPaletteKey
        self.onFocusChange = onFocusChange
        self.onLinkClick = onLinkClick
        self.onCaretRectChange = onCaretRectChange
        self.onSelectionChange = onSelectionChange
        self.onBuildContextMenu = onBuildContextMenu
        self.onInlineSelectionChange = onInlineSelectionChange
        self.onInlinePreviewKey = onInlinePreviewKey
        self.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        self.onSpellCheckingPolicyChanged = onSpellCheckingPolicyChanged
        self.placeholder = placeholder
        self.header = header
        self.headerCollapsedHeight = headerCollapsedHeight
        self.headerExpanded = headerExpanded
        self.retainedScrollDocumentIds = retainedScrollDocumentIds
        self.isCursorExcluded = isCursorExcluded
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard configuration.heightBehavior == .fitsContent,
              let container = nsView.documentView as? NativeTextViewContainer else {
            return nil
        }
        let width = proposal.width ?? nsView.contentView.bounds.width
        // Height is taken from the most recent layout pass rather than re-measured
        // at `proposal.width`. Re-measuring TextKit content at a speculative width
        // inside sizeThatFits risks layout loops (TextKit relayout → frame change →
        // sizeThatFits re-entry) and is expensive for large documents. In practice
        // SwiftUI calls sizeThatFits after the view has already been laid out at the
        // proposed width, and `invalidateIntrinsicContentSize` in
        // `applyManagedFrameSize` ensures SwiftUI re-queries after every width-driven
        // relayout, so the returned height stays correct.
        return CGSize(width: width, height: container.scrollableContentHeight)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ClampedScrollView()
        scrollView.fitsContent = configuration.heightBehavior == .fitsContent
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = configuration.heightBehavior.wantsVerticalScroller(for: configuration.scrollers)
        scrollView.hasHorizontalScroller = configuration.scrollers.hasHorizontalScroller
        scrollView.autohidesScrollers = configuration.scrollers.autohidesScrollers
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: configuration.safeAreaInsets.top,
            left: configuration.safeAreaInsets.leading,
            bottom: configuration.safeAreaInsets.bottom,
            right: configuration.safeAreaInsets.trailing
        )

        // Let NSTextView auto-initialize its own TextKit 2 stack via init(frame:).
        let textView = NativeTextView(frame: .zero)

        // Configure the auto-created text container.
        guard let textContainer = textView.textContainer,
              let textLayoutManager = textView.textLayoutManager else {
            fatalError("NSTextView did not create a TextKit 2 stack on this OS version")
        }
        textContainer.lineFragmentPadding = 0
        if let readingWidth = configuration.readingWidth {
            // Fix wrap width at readingWidth so text never re-wraps on resize; only the column's position moves.
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(width: readingWidth, height: .greatestFiniteMagnitude)
        } else {
            textContainer.widthTracksTextView = true
        }
        textView.textContainerInset = NSSize(
            width: configuration.textInsets.horizontal,
            height: configuration.textInsets.vertical
        )
        textContainer.heightTracksTextView = false

        let layoutDelegate = MarkdownLayoutManagerDelegate()
        context.coordinator.layoutDelegate = layoutDelegate
        textLayoutManager.delegate = layoutDelegate
        textView.configuration = configuration
        textView.overscrollPercent = configuration.overscroll.percent
        textView.maxOverscrollPoints = configuration.overscroll.maxPoints
        textView.minOverscrollPoints = configuration.overscroll.minPoints
        context.coordinator.configuration = configuration
        textView.insertionPointColor = configuration.theme.bodyText
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = true
        let initialState = WikiLinkService.makeDisplayState(from: text) { configuration.services.wikiLinks.name(forID: $0) }
        textView.string = initialState.display
        textView.delegate = context.coordinator
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.postsFrameChangedNotifications = true
        // Width and origin are driven by the container document view (see below).
        textView.autoresizingMask = []
        textView.backgroundColor = .clear
        // Body compositing for the scroll-away header (clipsToBounds + redraw policy)
        // is applied by ScrollingHeaderController when a header is first supplied, so
        // header-less embedders keep AppKit's default rendering.
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        textView.allowsUndo = true
        textView.isCursorExcluded = isCursorExcluded
        textView.isAutomaticSpellingCorrectionEnabled = configuration.spellChecking.automaticSpellingCorrection
        textView.isContinuousSpellCheckingEnabled = configuration.spellChecking.continuousSpellChecking
        textView.isGrammarCheckingEnabled = configuration.spellChecking.grammarChecking
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = false
        // MarkdownEditPlanner owns list/task/quote continuation. AppKit's
        // automatic text-replacement pass runs after Return and can otherwise
        // reinsert a plain "- " after an empty task transaction removed its
        // complete "- [ ] " prefix. Keeping this off also prevents the system
        // from racing our ordered-list and quote transactions.
        textView.isAutomaticTextReplacementEnabled = false
        textView.onPasteImage = onPasteImage
        textView.onSlashCommand = onSlashCommand
        textView.onSlashCommandAtCaret = onSlashCommandAtCaret
        textView.onCommandPaletteKey = onCommandPaletteKey
        textView.onFocusChange = onFocusChange
        if #available(macOS 15.1, *) {
            textView.writingToolsBehavior = .complete
        }
        // Create TextKit 2 layout bridge
        let bridge = LayoutBridge(textLayoutManager)
        context.coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        // The document view is ALWAYS a container (`NativeTextViewContainer`) hosting
        // the text view, the optional scroll-away header (a top band stacked ABOVE the
        // text view as a sibling — disjoint frames, so body/header overlap is
        // geometrically impossible), and, in reading-column mode, the full-width
        // wide-table overlays around the centered fixed-width column. The text view
        // keeps managing its own height; the container offsets it below the header
        // band and sizes itself to the sum.
        let vpSize = scrollView.contentView.bounds.size
        let container = NativeTextViewContainer(frame: NSRect(origin: .zero, size: vpSize))
        container.autoresizingMask = [.width]
        container.clipsToBounds = true
        container.textView = textView
        let initialWidth = configuration.readingWidth != nil ? textView.readingColumnWidth : vpSize.width
        textView.frame = NSRect(x: 0, y: 0, width: initialWidth, height: textView.frame.height)
        container.addSubview(textView)
        scrollView.documentView = container
        // Force full-document layout at init so paragraph heights are known
        // upfront; otherwise TextKit 2 viewport layout causes scroll drift.
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.clampToInsets()
        scrollView.reflectScrolledClipView(scrollView.contentView)

        context.coordinator.lastHandledFocusRequest = focusRequest
        context.coordinator.lastHandledNavigationRequest = navigationRequest
        if startsAtDocumentEnd || focusRequest != 0 {
            let end = (textView.string as NSString).length
            let insertionPoint = NSRange(location: end, length: 0)
            textView.setSelectedRange(insertionPoint)
            textView.scrollRangeToVisible(insertionPoint)
            requestFocusAtDocumentEnd(textView)
        }

        context.coordinator.textView = textView
        context.coordinator.wikiLinkMetadata = initialState.metadata
        context.coordinator.onCaretRectChange = onCaretRectChange
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onBuildContextMenu = onBuildContextMenu
        context.coordinator.onInlineSelectionChange = onInlineSelectionChange
        context.coordinator.onInlinePreviewKey = onInlinePreviewKey
        context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange

        textView.recalcOverscroll(for: scrollView)
        textView.setPlaceholder(placeholder)
        // Initial reading-column centering; the resize observer below handles later changes.
        if configuration.readingWidth != nil {
            textView.centerReadingColumn(forClipWidth: scrollView.contentView.bounds.width)
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        var lastObservedViewportWidth = scrollView.contentView.bounds.width
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: nil) { _ in
            // Refresh code-block overlays only on real viewport width changes, not on TextKit height-only echoes during typing.
            let newWidth = scrollView.contentView.bounds.width
            if abs(newWidth - lastObservedViewportWidth) > 0.5 {
                lastObservedViewportWidth = newWidth
                // Re-center the column by position (no redraw) so it stays smooth during live resize.
                // Read readingWidth from the live textView.configuration (a class, captured by
                // reference) instead of the struct `configuration` captured by value at
                // makeNSView time — the embedder may change readingWidth between updates.
                if textView.configuration.readingWidth != nil {
                    textView.centerReadingColumn(forClipWidth: newWidth)
                }
                context.coordinator.didEnsureLayoutForCurrentDocument = false
                context.coordinator.updateCodeBlockSelection(textView: textView)
            }
            // Only react with overscroll recalc when the viewport itself resizes
            // (window resize). Without this guard, TextKit-induced frame changes echo
            // back here and re-trigger recalcOverscroll, causing a 149pt height
            // oscillation after clicks. Compare the CONTAINER (the document view) height
            // to the viewport — it tracks the viewport for short docs.
            guard let container = scrollView.documentView as? NativeTextViewContainer else { return }
            // Read heightBehavior from the live textView.configuration (a class,
            // captured by reference) — not the struct `configuration` captured by
            // value at makeNSView time. Without this, a runtime .fitsContent→.scrolls
            // switch leaves this closure permanently early-returning, so viewport-
            // resize-driven recalcOverscroll is skipped → stale overscroll.
            if textView.configuration.heightBehavior == .fitsContent {
                // In .fitsContent the container is content-tall (not viewport-tall),
                // so the container-vs-viewport guard below is always true — which
                // would fire recalcOverscroll on every clip-view frame change. Only
                // width changes need a re-measure (text re-wraps); height-only
                // changes are already handled by the width-change block above.
                return
            }
            guard abs(container.frame.height - scrollView.contentView.bounds.height) > 1 else { return }
            textView.recalcOverscroll(for: scrollView)
            scrollView.clampToInsets()
        }
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { _ in
            textView.ensureVisibleLayout()
            if context.coordinator.isWritingToolsActive {
                context.coordinator.fixWritingToolsChildWindowIfNeeded(textView: textView)
            }
            scrollView.clampToInsets()
            context.coordinator.refreshActiveLinkCaretRect()
            context.coordinator.updateCodeBlockSelection(textView: textView)
        }
        reconcileHeader(textView: textView, context: context)
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.nativeTextView else { return }
        if context.coordinator.lastHandledFocusRequest != focusRequest {
            context.coordinator.lastHandledFocusRequest = focusRequest
            requestFocusAtDocumentEnd(textView)
        }
        if context.coordinator.lastHandledNavigationRequest != navigationRequest {
            context.coordinator.lastHandledNavigationRequest = navigationRequest
            requestFocus(textView, at: navigationLocation)
        }
        reconcileHeader(textView: textView, context: context)

        let isNodeSwitch = context.coordinator.documentId != documentId
        let themeChanged = !themesEqual(
            context.coordinator.configuration.theme,
            configuration.theme
        )

        // Drop remembered offsets for documents no longer retained (always keep
        // the current one). Only rebuilds the dict when something must go.
        if let retained = retainedScrollDocumentIds {
            let needsPrune = context.coordinator.scrollOffsets.keys.contains { key in
                key != documentId && !retained.contains(key)
            }
            if needsPrune {
                context.coordinator.scrollOffsets = context.coordinator.scrollOffsets.filter {
                    $0.key == documentId || retained.contains($0.key)
                }
            }
            // Evict undo stacks + content snapshots for documents no longer
            // retained (keep the current one); clear actions before dropping.
            let staleUndoKeys = Set(context.coordinator.undoManagers.keys)
                .union(context.coordinator.undoContentSnapshots.keys)
                .filter { key in
                    key != documentId && key != "__default__" && !retained.contains(key)
                }
            for key in staleUndoKeys {
                context.coordinator.undoManagers[key]?.removeAllActions()
                context.coordinator.undoManagers.removeValue(forKey: key)
                context.coordinator.undoContentSnapshots.removeValue(forKey: key)
            }
        }

        let wtActive: Bool = {
            if #available(macOS 15.0, *), textView.isWritingToolsActive { return true }
            return context.coordinator.isWritingToolsActive
        }()

        if wtActive && isNodeSwitch {
            // User switched files while Writing Tools was active — discard the
            // WT session so it doesn't overwrite the wrong node.
            // Keep wtStartDocumentId so textViewWritingToolsDidEnd can detect the
            // node mismatch and discard the results.
            context.coordinator.isWritingToolsActive = false
        } else if wtActive {
            // WT active on the same node — don't interfere with the session.
            // Note: this skips the heightBehavior sync below, so a heightBehavior
            // change while Writing Tools is active won't take effect until the
            // session ends. WT sessions are transient and height-mode switches
            // during one are not a supported use case.
            return
        }

        textView.onPasteImage = onPasteImage
        textView.onSlashCommand = onSlashCommand
        textView.onSlashCommandAtCaret = onSlashCommandAtCaret
        textView.onCommandPaletteKey = onCommandPaletteKey
        textView.onFocusChange = onFocusChange
        textView.isCursorExcluded = isCursorExcluded
        textView.setPlaceholder(placeholder)
        // Theme changes are appearance-only transactions. Keep the text and
        // its undo history intact, but make the live TextKit stack observe the
        // new palette before the restyle decision below.
        textView.configuration.theme = configuration.theme
        context.coordinator.configuration.theme = configuration.theme
        // Sync heightBehavior across all three layers (scroll view, text view,
        // coordinator) so a runtime switch fully reconfigures.
        let heightBehaviorChanged = textView.configuration.heightBehavior != configuration.heightBehavior
        if let clamped = nsView as? ClampedScrollView {
            clamped.fitsContent = configuration.heightBehavior == .fitsContent
        }
        textView.configuration.heightBehavior = configuration.heightBehavior
        context.coordinator.configuration.heightBehavior = configuration.heightBehavior
        let desiredVerticalScroller = configuration.heightBehavior.wantsVerticalScroller(for: configuration.scrollers)
        if nsView.hasVerticalScroller != desiredVerticalScroller {
            nsView.hasVerticalScroller = desiredVerticalScroller
        }
        if nsView.hasHorizontalScroller != configuration.scrollers.hasHorizontalScroller {
            nsView.hasHorizontalScroller = configuration.scrollers.hasHorizontalScroller
        }
        if nsView.autohidesScrollers != configuration.scrollers.autohidesScrollers {
            nsView.autohidesScrollers = configuration.scrollers.autohidesScrollers
        }
        // When heightBehavior changes at runtime, re-measure and re-report so the
        // view reconfigures immediately (inflation toggles, overscroll zeroing).
        if heightBehaviorChanged {
            textView.recalcOverscroll(for: nsView)
            (nsView as? ClampedScrollView)?.clampToInsets()
            nsView.invalidateIntrinsicContentSize()
        }
        // Sync rawSourceMode; a flip rebuilds in the new presentation. It
        // changes display text ([[Name]] ↔ [[Name|UUID]]), so drop the doc's
        // undo stack — surviving actions would replay at stale ranges.
        let rawSourceModeChanged = context.coordinator.configuration.rawSourceMode != configuration.rawSourceMode
        if rawSourceModeChanged {
            context.coordinator.configuration.rawSourceMode = configuration.rawSourceMode
            textView.configuration.rawSourceMode = configuration.rawSourceMode
            textView.breakUndoCoalescing()
            context.coordinator.undoManagers[documentId]?.removeAllActions()
            context.coordinator.didInitialFormatting = false
            // isWikiLinkActive is a SwiftUI binding — defer off the update pass
            // to avoid "Modifying state during view update".
            let coordinator = context.coordinator
            DispatchQueue.main.async { coordinator.isWikiLinkActive = false }
        }
        // Reading column centers by POSITION (container subview), so the text inset is constant.
        let desiredTextInset = NSSize(
            width: configuration.textInsets.horizontal,
            height: configuration.textInsets.vertical
        )
        if abs(textView.textContainerInset.width - desiredTextInset.width) > 0.5
            || abs(textView.textContainerInset.height - desiredTextInset.height) > 0.5 {
            textView.textContainerInset = desiredTextInset
        }
        // Refresh services/theme when the embedder hands us a new configuration
        // (e.g. when the available wiki-link targets change). Cheap pointer-/
        // value-based comparison; full equality isn't required because the
        // embedder is the source of truth.
        let newImageFingerprint = configuration.services.images.fingerprint()
        let newWikiFingerprint = configuration.services.wikiLinks.fingerprint()
        let imageChanged = newImageFingerprint != context.coordinator.lastImageFingerprint
        let wikiChanged = newWikiFingerprint != context.coordinator.lastWikiFingerprint
        if imageChanged || wikiChanged {
            context.coordinator.lastImageFingerprint = newImageFingerprint
            context.coordinator.lastWikiFingerprint = newWikiFingerprint
            context.coordinator.configuration.services = configuration.services
            textView.configuration.services = configuration.services
            // Only an image change needs a layout re-measure; a wiki-link rename is style-only.
            if imageChanged, let tlm = textView.textLayoutManager {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            // Restyle live tv content — full rebuild would clobber paste-fresh embeds when `text` binding hasn't caught up.
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if fullRange.length > 0 {
                context.coordinator.restyleParagraphs([fullRange], in: textView)
            }
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.insertionPointColor = isEditable ? context.coordinator.configuration.theme.bodyText : .clear
        let fontChanged = (context.coordinator.fontName != fontName) || (context.coordinator.fontSize != fontSize)
        if let pendingInlineReplacement {
            if pendingInlineReplacement.documentId == documentId,
               context.coordinator.lastAppliedInlineReplacementID != pendingInlineReplacement.id {
                context.coordinator.applyInlineReplacement(pendingInlineReplacement, to: textView)
            }
            DispatchQueue.main.async {
                if self.pendingInlineReplacement?.id == pendingInlineReplacement.id {
                    self.pendingInlineReplacement = nil
                }
            }
            return
        }
        // A theme-only update must not be mistaken for a no-op: the editor's
        // source text is unchanged, so the old early-return would leave body
        // text, headings, markers, and typing attributes on the previous color.
        // Restyling only attributes keeps the native undo stack and Markdown
        // source untouched. Font/source/document transitions still use the
        // existing rebuild path below.
        let needsFullRebuild = isNodeSwitch
            || rawSourceModeChanged
            || fontChanged
            || !context.coordinator.didInitialFormatting
            || context.coordinator.lastSyncedText != text
        if !needsFullRebuild {
            if themeChanged {
                applyThemeOnly(configuration, to: textView, coordinator: context.coordinator)
            }
            return
        }
        if fontChanged {
            context.coordinator.didInitialFormatting = false
        }
        if isNodeSwitch {
            // Save the outgoing document's scroll position — unless it just left
            // the retained set, in which case let it reset to top next time.
            if let outgoingId = context.coordinator.documentId,
               retainedScrollDocumentIds?.contains(outgoingId) ?? true {
                context.coordinator.scrollOffsets[outgoingId] = nsView.contentView.bounds.origin.y
            }
            // Snapshot the outgoing document's content (storage form) so a later
            // switch-back can detect a file rewritten while it was backgrounded.
            // `lastSyncedText` still holds the outgoing content here.
            if let outgoingId = context.coordinator.documentId {
                context.coordinator.undoContentSnapshots[outgoingId] = context.coordinator.lastSyncedText
            }
            // Per-document undo: close the OUTGOING document's open coalescing group
            // (while its manager is still active), then switch the active documentId so
            // `undoManager(for:)` starts vending the INCOMING document's own manager. We
            // no longer clear undo here — that `removeAllActions()` is what killed Cmd+Z
            // across a file switch.
            textView.breakUndoCoalescing()
            context.coordinator.documentId = documentId
            // Drop the incoming document's undo stack if its text changed while
            // switched away — its recorded ranges are now stale.
            context.coordinator.invalidateUndoIfContentDiverged(for: documentId, incomingText: text)
            context.coordinator.didInitialFormatting = false
            context.coordinator.didEnsureLayoutForCurrentDocument = false
            context.coordinator.resetImageEmbedState()
            // Drop old document's wide-table overlays synchronously.
            textView.removeAllWideTableOverlays()
            // Park at top during the rebuild; the new document's own saved offset
            // (if any) is restored after its height is known (see below).
            nsView.contentView.scroll(to: NSPoint(x: 0, y: -nsView.contentInsets.top))
            nsView.reflectScrolledClipView(nsView.contentView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }

        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        textView.recalcOverscroll(for: nsView)
        (nsView as? ClampedScrollView)?.clampToInsets()

        // Sync coordinator's font fields BEFORE the rebuild so the helper
        // reads the current values from the View struct.
        context.coordinator.fontName = fontName
        context.coordinator.fontSize = fontSize
        context.coordinator.rebuildTextStorageAndStyle(
            textView,
            from: text,
            invalidateLayout: isNodeSwitch || rawSourceModeChanged
        )
        textView.recalcOverscroll(for: nsView)
        (nsView as? ClampedScrollView)?.clampToInsets()
        // Height is measured now, so restore the saved offset; clampToInsets keeps
        // it in range if the document got shorter.
        if isNodeSwitch, let savedY = context.coordinator.scrollOffsets[documentId] {
            nsView.contentView.scroll(to: NSPoint(x: nsView.contentView.bounds.origin.x, y: savedY))
            nsView.reflectScrolledClipView(nsView.contentView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }
        // Document rebuilds bypass textDidChange — re-derive emptiness here.
        textView.refreshPlaceholderVisibility()
        DispatchQueue.main.async {
            context.coordinator.updateCodeBlockSelection(textView: textView)
        }

        context.coordinator.onCaretRectChange = onCaretRectChange
        context.coordinator.onBuildContextMenu = onBuildContextMenu
        context.coordinator.onInlineSelectionChange = onInlineSelectionChange
        context.coordinator.onInlinePreviewKey = onInlinePreviewKey
        context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        context.coordinator.didInitialFormatting = true
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = NativeTextViewCoordinator(
            text: $text,
            fontName: fontName,
            fontSize: fontSize,
            isWikiLinkActive: $isWikiLinkActive,
            onLinkClick: onLinkClick,
            onInlineSelectionChange: onInlineSelectionChange
        )
        coordinator.documentId = documentId
        coordinator.configuration = configuration
        coordinator.lastImageFingerprint = configuration.services.images.fingerprint()
        coordinator.lastWikiFingerprint = configuration.services.wikiLinks.fingerprint()
        coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        coordinator.onSelectionChange = onSelectionChange
        coordinator.onInlinePreviewKey = onInlinePreviewKey
        coordinator.userPrefersContinuousSpellChecking = configuration.spellChecking.continuousSpellChecking
        coordinator.userPrefersGrammarChecking = configuration.spellChecking.grammarChecking
        coordinator.userPrefersAutomaticSpellingCorrection = configuration.spellChecking.automaticSpellingCorrection
        coordinator.onSpellCheckingPolicyChanged = onSpellCheckingPolicyChanged
        return coordinator
    }
}

private extension NativeTextViewWrapper {
    func requestFocusAtDocumentEnd(_ textView: NSTextView) {
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            let end = (textView.string as NSString).length
            let insertionPoint = NSRange(location: end, length: 0)
            textView.setSelectedRange(insertionPoint)
            textView.scrollRangeToVisible(insertionPoint)
            textView.window?.makeFirstResponder(textView)
        }
    }

    func requestFocus(_ textView: NSTextView, at sourceLocation: Int) {
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            let end = (textView.string as NSString).length
            let location = min(max(0, sourceLocation), end)
            let insertionPoint = NSRange(location: location, length: 0)
            textView.setSelectedRange(insertionPoint)
            textView.scrollRangeToVisible(insertionPoint)
            textView.window?.makeFirstResponder(textView)
        }
    }

    func themesEqual(_ lhs: MarkdownEditorTheme, _ rhs: MarkdownEditorTheme) -> Bool {
        lhs.bodyText.isEqual(rhs.bodyText)
            && lhs.mutedText.isEqual(rhs.mutedText)
            && lhs.disabledText.isEqual(rhs.disabledText)
            && lhs.headingMarker.isEqual(rhs.headingMarker)
            && lhs.taskCheckboxAccent.isEqual(rhs.taskCheckboxAccent)
            && lhs.link.isEqual(rhs.link)
            && lhs.incompleteLink.isEqual(rhs.incompleteLink)
            && lhs.findMatchHighlight.isEqual(rhs.findMatchHighlight)
            && lhs.findCurrentMatchHighlight.isEqual(rhs.findCurrentMatchHighlight)
            && lhs.latexLightModeText.isEqual(rhs.latexLightModeText)
            && lhs.latexDarkModeText.isEqual(rhs.latexDarkModeText)
            && lhs.strikethroughColor.isEqual(rhs.strikethroughColor)
            && lhs.highlightColor.isEqual(rhs.highlightColor)
    }

    func applyThemeOnly(
        _ configuration: MarkdownEditorConfiguration,
        to textView: NSTextView,
        coordinator: Coordinator
    ) {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        if configuration.rawSourceMode {
            let (baseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
                fontName: fontName,
                fontSize: fontSize,
                layoutBridge: coordinator.layoutBridge,
                configuration: configuration
            )
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: configuration.theme.bodyText,
                .paragraphStyle: paragraphStyle,
            ]
            textView.textStorage?.beginEditing()
            if fullRange.length > 0 {
                textView.textStorage?.setAttributes(baseAttributes, range: fullRange)
            }
            textView.textStorage?.endEditing()
            textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
                font: baseFont,
                paragraphStyle: paragraphStyle,
                theme: configuration.theme
            )
            textView.setNeedsDisplay(textView.visibleRect)
        } else {
            coordinator.restyleParagraphs([fullRange], in: textView)
        }
    }
}

// MARK: - Scrolling header view

private extension NativeTextViewWrapper {
    /// Host the embedder's header above the body, inside the container document
    /// view. The hosted content refreshes on every SwiftUI update; build,
    /// collapse/expand, and teardown live in `ScrollingHeaderController`.
    ///
    /// **`.fitsContent` note:** The header's band height is included in the
    /// reported content height (via `scrollableContentHeight`), so a static
    /// header works correctly. The *collapse-on-scroll* animation is driven by
    /// the inner scroll offset, which is always zero in `.fitsContent` (no
    /// internal scrolling), so the collapse never triggers. Combining a
    /// collapsing header with `.fitsContent` is allowed but the collapse
    /// behavior is not meaningful.
    func reconcileHeader(textView: NSTextView, context: Context) {
        let coord = context.coordinator
        guard let container = (textView as? NativeTextView)?.superview as? NativeTextViewContainer else { return }

        guard let header else {
            if let controller = coord.headerController {
                controller.remove(from: container)
                coord.headerController = nil
            }
            return
        }
        let controller = coord.headerController ?? ScrollingHeaderController()
        coord.headerController = controller
        controller.reconcile(
            header: header,
            collapsedHeight: headerCollapsedHeight,
            expanded: headerExpanded,
            container: container
        )
    }
}
