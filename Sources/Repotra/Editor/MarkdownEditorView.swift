import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownEditorView: NSViewRepresentable {
    @Bindable var session: NoteSession
    let rootURL: URL?
    var renderOptions: MarkdownRenderOptions = .standard
    var importImageFile: @MainActor (URL) async -> String?
    var importImageData: @MainActor (Data) async -> String?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            rootURL: rootURL,
            renderOptions: renderOptions,
            importImageFile: importImageFile,
            importImageData: importImageData
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = FusionTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 30)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.insertionPointColor = renderOptions.textColor
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.onDisplayLocation = { [weak coordinator = context.coordinator] location, taskToggle in
            coordinator?.activate(atDisplayLocation: location, toggleTask: taskToggle) ?? false
        }
        textView.ensureActiveSelection = { [weak coordinator = context.coordinator] in
            coordinator?.ensureSelectionIsActive() ?? true
        }
        textView.onImportImageFile = { [weak coordinator = context.coordinator] url in
            coordinator?.insertImage(from: url)
        }
        textView.onImportImageData = { [weak coordinator = context.coordinator] data in
            coordinator?.insertImage(data: data)
        }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.rebuild(source: session.content, selectionSourceLocation: 0)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.session = session
        context.coordinator.rootURL = rootURL
        context.coordinator.renderOptions = renderOptions
        guard let textView = scrollView.documentView as? FusionTextView else { return }
        textView.insertionPointColor = renderOptions.textColor
        if context.coordinator.source != session.content || context.coordinator.lastOptions != renderOptions {
            let location = context.coordinator.currentSourceSelectionLocation()
            context.coordinator.rebuild(source: session.content, selectionSourceLocation: location)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var session: NoteSession
        var rootURL: URL?
        var renderOptions: MarkdownRenderOptions
        var lastOptions = MarkdownRenderOptions.standard
        weak var textView: FusionTextView?
        private let engine = MarkdownRenderEngine()
        private var rendered: RenderedDocument?
        private var isApplying = false
        private let importImageFile: @MainActor (URL) async -> String?
        private let importImageData: @MainActor (Data) async -> String?
        private var reflowTask: Task<Void, Never>?
        var source = ""

        init(
            session: NoteSession,
            rootURL: URL?,
            renderOptions: MarkdownRenderOptions,
            importImageFile: @escaping @MainActor (URL) async -> String?,
            importImageData: @escaping @MainActor (Data) async -> String?
        ) {
            self.session = session
            self.rootURL = rootURL
            self.renderOptions = renderOptions
            self.importImageFile = importImageFile
            self.importImageData = importImageData
        }

        func rebuild(source: String, selectionSourceLocation: Int) {
            guard let textView else { return }
            reflowTask?.cancel()
            self.source = source
            lastOptions = renderOptions
            let next = engine.render(
                source: source,
                activeLocation: max(0, min((source as NSString).length, selectionSourceLocation)),
                rootURL: rootURL,
                options: renderOptions
            )
            rendered = next
            isApplying = true
            textView.textStorage?.setAttributedString(next.attributedString)
            let active = next.segments.first(where: \.isActive)
            let displaySelection: Int
            if let active {
                let relative = max(0, min(active.sourceRange.length, selectionSourceLocation - active.sourceRange.location))
                displaySelection = active.displayRange.location + min(relative, active.displayRange.length)
            } else {
                displaySelection = 0
            }
            textView.setSelectedRange(NSRange(location: min(displaySelection, textView.string.utf16.count), length: 0))
            isApplying = false
        }

        func textDidChange(_: Notification) {
            guard !isApplying, let textView, let rendered,
                  let active = rendered.segments.first(where: \.isActive) else { return }
            let displayText = textView.string as NSString
            let outsideLength = rendered.displayLength - active.displayRange.length
            let activeLength = max(0, displayText.length - outsideLength)
            let activeDisplayRange = NSRange(location: active.displayRange.location, length: activeLength)
            guard NSMaxRange(activeDisplayRange) <= displayText.length else { return }
            let replacement = displayText.substring(with: activeDisplayRange)
            let sourceText = source as NSString
            guard NSMaxRange(active.sourceRange) <= sourceText.length else { return }
            let nextSource = sourceText.replacingCharacters(in: active.sourceRange, with: replacement)
            let sourceDelta = (replacement as NSString).length - active.sourceRange.length
            let displayDelta = activeLength - active.displayRange.length
            let updatedSegments = rendered.segments.map { segment in
                if segment.isActive {
                    return RenderedSegment(
                        sourceRange: NSRange(location: segment.sourceRange.location, length: (replacement as NSString).length),
                        displayRange: NSRange(location: segment.displayRange.location, length: activeLength),
                        isActive: true,
                        rawSource: replacement
                    )
                }
                let followsActive = segment.sourceRange.location > active.sourceRange.location
                return RenderedSegment(
                    sourceRange: NSRange(
                        location: segment.sourceRange.location + (followsActive ? sourceDelta : 0),
                        length: segment.sourceRange.length
                    ),
                    displayRange: NSRange(
                        location: segment.displayRange.location + (followsActive ? displayDelta : 0),
                        length: segment.displayRange.length
                    ),
                    isActive: false,
                    rawSource: segment.rawSource
                )
            }
            self.rendered = RenderedDocument(
                attributedString: rendered.attributedString,
                segments: updatedSegments,
                activeSourceRange: NSRange(location: active.sourceRange.location, length: (replacement as NSString).length)
            )
            source = nextSource
            session.updateContent(nextSource)
            let oldSeparators = active.rawSource.components(separatedBy: "\n\n").count
            let newSeparators = replacement.components(separatedBy: "\n\n").count
            if (nextSource as NSString).length < 100_000 || oldSeparators != newSeparators {
                scheduleReflow()
            }
        }

        func activate(atDisplayLocation location: Int, toggleTask: Bool) -> Bool {
            guard let rendered, let segment = rendered.segment(atDisplayLocation: location), !segment.isActive else {
                return false
            }
            if toggleTask, toggleTaskMarker(in: segment) {
                return true
            }
            let sourceLocation = engine.sourceLocation(for: location, segment: segment)
            rebuild(source: source, selectionSourceLocation: sourceLocation)
            return true
        }

        func ensureSelectionIsActive() -> Bool {
            guard let textView, let rendered,
                  let segment = rendered.segment(atDisplayLocation: textView.selectedRange().location),
                  !segment.isActive else { return true }
            let location = engine.sourceLocation(for: textView.selectedRange().location, segment: segment)
            rebuild(source: source, selectionSourceLocation: location)
            return true
        }

        func currentSourceSelectionLocation() -> Int {
            guard let textView, let rendered,
                  let segment = rendered.segment(atDisplayLocation: textView.selectedRange().location) else { return 0 }
            if segment.isActive {
                return segment.sourceRange.location + max(0, textView.selectedRange().location - segment.displayRange.location)
            }
            return engine.sourceLocation(for: textView.selectedRange().location, segment: segment)
        }

        func insertImage(from url: URL) {
            Task { @MainActor [weak self] in
                guard let self, let path = await importImageFile(url) else { return }
                textView?.insertText("![\(url.deletingPathExtension().lastPathComponent)](\(path))", replacementRange: textView?.selectedRange() ?? .init())
            }
        }

        func insertImage(data: Data) {
            Task { @MainActor [weak self] in
                guard let self, let path = await importImageData(data) else { return }
                textView?.insertText("![Image](\(path))", replacementRange: textView?.selectedRange() ?? .init())
            }
        }

        private func toggleTaskMarker(in segment: RenderedSegment) -> Bool {
            let raw = segment.rawSource
            let replacement: String
            if let range = raw.range(of: "[ ]") {
                replacement = raw.replacingCharacters(in: range, with: "[x]")
            } else if let range = raw.range(of: "[x]", options: .caseInsensitive) {
                replacement = raw.replacingCharacters(in: range, with: "[ ]")
            } else {
                return false
            }
            let next = (source as NSString).replacingCharacters(in: segment.sourceRange, with: replacement)
            session.updateContent(next)
            rebuild(source: next, selectionSourceLocation: segment.sourceRange.location)
            return true
        }

        private func scheduleReflow() {
            reflowTask?.cancel()
            reflowTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard let self, !Task.isCancelled else { return }
                rebuild(source: source, selectionSourceLocation: currentSourceSelectionLocation())
            }
        }
    }
}

@MainActor
final class FusionTextView: NSTextView {
    var onDisplayLocation: ((Int, Bool) -> Bool)?
    var ensureActiveSelection: (() -> Bool)?
    var onImportImageFile: ((URL) -> Void)?
    var onImportImageData: ((Data) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let shouldToggleTask = point.x < textContainerInset.width + 42
        if onDisplayLocation?(index, shouldToggleTask) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        _ = ensureActiveSelection?()
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }
        switch characters {
        case "b": wrapSelection(prefix: "**", suffix: "**"); return true
        case "i": wrapSelection(prefix: "*", suffix: "*"); return true
        case "k": wrapSelection(prefix: "[", suffix: "](https://)"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let selection = selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = text.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
        let patterns = [
            #"^(\s*[-+*]\s+\[[ xX]\]\s+)"#,
            #"^(\s*[-+*]\s+)"#,
            #"^(\s*)(\d+)\.\s+"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { continue }
            var marker = (line as NSString).substring(with: match.range)
            if pattern.contains("\\d+"), match.numberOfRanges > 2 {
                let indent = (line as NSString).substring(with: match.range(at: 1))
                let number = Int((line as NSString).substring(with: match.range(at: 2))) ?? 0
                marker = "\(indent)\(number + 1). "
            } else if marker.contains("[x]") || marker.contains("[X]") {
                marker = marker.replacingOccurrences(of: "[x]", with: "[ ]", options: .caseInsensitive)
            }
            let remainder = line.dropFirst(match.range.length).trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty {
                replaceCharacters(in: NSRange(location: lineRange.location, length: selection.location - lineRange.location), with: "")
                super.insertNewline(sender)
            } else {
                insertText("\n\(marker)", replacementRange: selection)
            }
            return
        }
        super.insertNewline(sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let imageURL = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true })
        {
            onImportImageFile?(imageURL)
            return
        }
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:])
        {
            onImportImageData?(png)
            return
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let imageURL = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) {
            onImportImageFile?(imageURL)
            return true
        }
        return super.performDragOperation(sender)
    }

    private func wrapSelection(prefix: String, suffix: String) {
        _ = ensureActiveSelection?()
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        insertText(prefix + selected + suffix, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + prefix.utf16.count, length: selected.utf16.count))
    }
}
