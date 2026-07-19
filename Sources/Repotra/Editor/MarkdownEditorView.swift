import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum MarkdownEditorContext: Sendable {
    case main
    case sticky
    case quickCapture
}

enum MarkdownEditorCommand: Sendable {
    case bold
    case italic
    case strikethrough
    case highlight
    case inlineCode
    case link
    case heading(Int)
    case blockquote
    case unorderedList
    case orderedList
    case codeBlock
    case horizontalRule
    case image
}

struct SlashPalettePlacement: Equatable {
    static let preferredWidth: CGFloat = 230
    static let preferredHeight: CGFloat = 356
    static let minimumAnchoredHeight: CGFloat = 140
    static let edgeMargin: CGFloat = 8
    static let anchorGap: CGFloat = 6

    let origin: CGPoint
    let width: CGFloat
    let maxHeight: CGFloat
    let opensAbove: Bool

    static func resolve(
        containerSize: CGSize,
        anchor: CGRect,
        preferredWidth: CGFloat = preferredWidth,
        preferredHeight: CGFloat = preferredHeight,
        minimumAnchoredHeight: CGFloat = minimumAnchoredHeight,
        margin: CGFloat = edgeMargin,
        gap: CGFloat = anchorGap
    ) -> SlashPalettePlacement {
        let usableWidth = max(1, containerSize.width - margin * 2)
        let width = min(preferredWidth, usableWidth)
        let maximumX = max(margin, containerSize.width - margin - width)
        let x = min(max(anchor.minX, margin), maximumX)

        let usableHeight = max(1, containerSize.height - margin * 2)
        let below = max(0, containerSize.height - margin - anchor.maxY - gap)
        let above = max(0, anchor.minY - margin - gap)

        // When neither side can hold a useful command list, use the whole
        // viewport and let the palette scroll internally. This keeps it inside
        // very small floating-note windows instead of clipping around the caret.
        if max(below, above) < minimumAnchoredHeight {
            return SlashPalettePlacement(
                origin: CGPoint(x: x, y: margin),
                width: width,
                maxHeight: min(preferredHeight, usableHeight),
                opensAbove: false
            )
        }

        let opensAbove = below < minimumAnchoredHeight && above > below
        let available = opensAbove ? above : below
        let height = min(preferredHeight, max(1, available))
        let y = opensAbove ? anchor.minY - gap - height : anchor.maxY + gap
        return SlashPalettePlacement(
            origin: CGPoint(x: x, y: min(max(y, margin), max(margin, containerSize.height - margin - height))),
            width: width,
            maxHeight: height,
            opensAbove: opensAbove
        )
    }
}

@MainActor
@Observable
final class MarkdownCommandCenter {
    let id: UUID
    let bus: MarkdownEditorBus

    init() {
        let identifier = UUID()
        id = identifier
        func name(_ action: String) -> Notification.Name {
            Notification.Name("Repotra.Markdown.\(identifier.uuidString).\(action)")
        }

        bus = MarkdownEditorBus(
            applyBoldRequest: name("bold"),
            applyItalicRequest: name("italic"),
            applyHeadingRequest: name("heading"),
            applyHighlightRequest: name("highlight"),
            applyStrikethroughRequest: name("strikethrough"),
            applyInlineCodeRequest: name("inline-code"),
            applyBlockquoteRequest: name("blockquote"),
            applyUnorderedListRequest: name("unordered-list"),
            applyOrderedListRequest: name("ordered-list"),
            applyLinkRequest: name("link"),
            applyCodeBlockRequest: name("code-block"),
            applyHorizontalRuleRequest: name("horizontal-rule"),
            applyImageRequest: name("image"),
            insertMarkdownRequest: name("insert-markdown")
        )
    }

    func insert(_ markdown: String) {
        NotificationCenter.default.post(
            name: bus.insertMarkdownRequest!, object: nil, userInfo: ["text": markdown]
        )
    }

    func perform(_ command: MarkdownEditorCommand) {
        let center = NotificationCenter.default
        switch command {
        case .bold: center.post(name: bus.applyBoldRequest!, object: nil)
        case .italic: center.post(name: bus.applyItalicRequest!, object: nil)
        case .strikethrough: center.post(name: bus.applyStrikethroughRequest!, object: nil)
        case .highlight: center.post(name: bus.applyHighlightRequest!, object: nil)
        case .inlineCode: center.post(name: bus.applyInlineCodeRequest!, object: nil)
        case .link: center.post(name: bus.applyLinkRequest!, object: nil)
        case let .heading(level):
            center.post(name: bus.applyHeadingRequest!, object: nil, userInfo: ["level": level])
        case .blockquote: center.post(name: bus.applyBlockquoteRequest!, object: nil)
        case .unorderedList: center.post(name: bus.applyUnorderedListRequest!, object: nil)
        case .orderedList: center.post(name: bus.applyOrderedListRequest!, object: nil)
        case .codeBlock: center.post(name: bus.applyCodeBlockRequest!, object: nil)
        case .horizontalRule: center.post(name: bus.applyHorizontalRuleRequest!, object: nil)
        case .image: center.post(name: bus.applyImageRequest!, object: nil)
        }
    }
}

struct MarkdownEditorView: View {
    private static let codeHighlighter = HighlighterSwiftBridge()

    @Bindable var session: NoteSession
    let rootURL: URL
    var context: MarkdownEditorContext = .main
    var startsAtDocumentEnd = false
    var focusRequest = 0
    var navigationRequest = 0
    var navigationLocation = 0
    var sourceMode: Binding<Bool>?
    var renderOptions = MarkdownRenderOptions()
    let importImageFile: @MainActor (URL) async -> String?
    let importImageData: @MainActor (Data) async -> String?

    @State private var commandCenter = MarkdownCommandCenter()
    @State private var localRawSourceMode = false
    @State private var hasTextSelection = false
    @State private var showsBlockMenu = false
    @State private var selectedSlashAction = 0
    @State private var slashAnchorRect: CGRect?
    @State private var visibleCodeBlocks: [CodeBlockSelection] = []
    @State private var copiedCodeBlockID: Int?

    var body: some View {
        ZStack(alignment: .top) {
            NativeTextViewWrapper(
                text: Binding(
                    get: { session.content },
                    set: { session.updateContent($0) }
                ),
                configuration: configuration,
                fontName: renderOptions.fontFamily,
                fontSize: renderOptions.fontSize,
                documentId: session.editorDocumentID.uuidString,
                startsAtDocumentEnd: startsAtDocumentEnd,
                focusRequest: focusRequest,
                navigationRequest: navigationRequest,
                navigationLocation: navigationLocation,
                onPasteImage: importImage(from:),
                onSlashCommandAtCaret: { anchor in
                    slashAnchorRect = anchor
                    selectedSlashAction = 0
                    showsBlockMenu = true
                },
                onCommandPaletteKey: handleSlashPaletteKey,
                onFocusChange: { focused in
                    if !focused { dismissSlashPalette() }
                },
                onSelectionChange: {
                    hasTextSelection = $0.length > 0
                    if showsBlockMenu { dismissSlashPalette() }
                },
                onCodeBlockSelectionChange: { selections in
                    DispatchQueue.main.async { visibleCodeBlocks = selections }
                }
            )

            ForEach(visibleCodeBlocks) { selection in
                CodeBlockButton(
                    selection: selection,
                    isCopied: copiedCodeBlockID == selection.id
                ) {
                    copyCodeBlock(selection)
                }
            }
            if context == .main, hasTextSelection {
                editorTools
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if showsBlockMenu, let slashAnchorRect {
                GeometryReader { geometry in
                    let placement = SlashPalettePlacement.resolve(
                        containerSize: geometry.size,
                        anchor: slashAnchorRect
                    )
                    slashPalette(maxHeight: placement.maxHeight)
                        .frame(width: placement.width, height: placement.maxHeight)
                        .position(
                            x: placement.origin.x + placement.width / 2,
                            y: placement.origin.y + placement.maxHeight / 2
                        )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                .zIndex(20)
            }
        }
        .animation(.easeOut(duration: 0.14), value: hasTextSelection)
        .animation(.easeOut(duration: 0.14), value: showsBlockMenu)
        .onChange(of: session.editorDocumentID) { _, _ in dismissSlashPalette() }
        .onDisappear { dismissSlashPalette() }
        .focusedSceneValue(\.markdownCommandCenter, commandCenter)
    }

    private var configuration: MarkdownEditorConfiguration {
        var value = MarkdownEditorConfiguration.default
        var theme = MarkdownEditorTheme.default
        theme.bodyText = renderOptions.textColor
        theme.mutedText = renderOptions.textColor.withAlphaComponent(0.48)
        theme.disabledText = renderOptions.textColor.withAlphaComponent(0.28)
        theme.headingMarker = renderOptions.textColor.withAlphaComponent(0.35)
        theme.taskCheckboxAccent = renderOptions.accentColor
        theme.link = renderOptions.accentColor
        theme.strikethroughColor = renderOptions.textColor.withAlphaComponent(0.46)
        theme.highlightColor = NSColor.systemYellow.withAlphaComponent(0.28)
        value.theme = theme
        value.services = MarkdownEditorServices(
            images: LibraryAssetProvider(rootURL: rootURL),
            syntaxHighlighter: Self.codeHighlighter,
            bus: commandCenter.bus
        )
        value.readingWidth = context == .main ? (renderOptions.readingWidth ?? 720) : nil
        value.rawSourceMode = isRawSourceMode
        value.textInsets = TextInsets(
            horizontal: context == .main ? 40 : 18,
            vertical: context == .main ? 46 : 24
        )
        value.overscroll = context == .sticky
            ? OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0)
            : .default
        value.scrollers = .vertical
        return value
    }

    private var editorTools: some View {
        HStack(spacing: 2) {
            toolButton("bold", help: "粗体 ⌘B", command: .bold)
            toolButton("italic", help: "斜体 ⌘I", command: .italic)
            toolButton("strikethrough", help: "删除线 ⇧⌘X", command: .strikethrough)
            toolButton("chevron.left.forwardslash.chevron.right", help: "行内代码 ⇧⌘C", command: .inlineCode)
            toolButton("highlighter", help: "高亮 ⇧⌘H", command: .highlight)
            toolButton("link", help: "链接 ⌘K", command: .link)
            Divider().frame(height: 18).padding(.horizontal, 4)
            Menu {
                Button("正文") { commandCenter.perform(.heading(0)) }
                ForEach(1 ... 6, id: \.self) { level in
                    Button("标题 \(level)") { commandCenter.perform(.heading(level)) }
                }
                Divider()
                Button("引用") { commandCenter.perform(.blockquote) }
                Button("无序列表") { commandCenter.perform(.unorderedList) }
                Button("有序列表") { commandCenter.perform(.orderedList) }
                Button("代码块") { commandCenter.perform(.codeBlock) }
                Button("分隔线") { commandCenter.perform(.horizontalRule) }
                Button("图片") { commandCenter.perform(.image) }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 26)
                    .repotraHoverFeedback()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("插入块 / Markdown 命令")

            Button {
                toggleSourceMode()
            } label: {
                Image(systemName: isRawSourceMode ? "doc.richtext.fill" : "chevron.left.forwardslash.chevron.right")
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(RepotraHoverButtonStyle())
            .help(isRawSourceMode ? "返回融合视图" : "显示 Markdown 源码")
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    private func slashPalette(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("插入 Markdown")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            Divider().opacity(0.55)
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(slashActions.enumerated()), id: \.element.id) { index, action in
                            Button { executeSlashAction(index) } label: {
                                Label(action.title, systemImage: action.icon)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(RepotraHoverButtonStyle(isSelected: index == selectedSlashAction))
                            .focusable(false)
                            .id(action.id)
                            .accessibilityIdentifier("markdown-slash-action-\(action.id)")
                            .accessibilityLabel(action.title)
                            .accessibilityValue(index == selectedSlashAction ? "已选择" : "")
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.automatic)
                .onChange(of: selectedSlashAction) { _, index in
                    guard slashActions.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        scrollProxy.scrollTo(slashActions[index].id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxHeight: maxHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.separator.opacity(0.45), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown-slash-palette")
        .accessibilityLabel("插入 Markdown")
    }

    private struct SlashAction {
        let id: String
        let title: String
        let icon: String
        let command: MarkdownEditorCommand?
        let markdown: String?
    }

    private var slashActions: [SlashAction] {
        [
            .init(id: "body", title: "正文", icon: "textformat", command: .heading(0), markdown: nil),
            .init(id: "heading-1", title: "一级标题", icon: "textformat.size.larger", command: .heading(1), markdown: nil),
            .init(id: "quote", title: "引用", icon: "text.quote", command: .blockquote, markdown: nil),
            .init(id: "unordered-list", title: "无序列表", icon: "list.bullet", command: .unorderedList, markdown: nil),
            .init(id: "ordered-list", title: "有序列表", icon: "list.number", command: .orderedList, markdown: nil),
            .init(id: "task-list", title: "任务列表", icon: "checklist", command: nil, markdown: "- [ ] "),
            .init(id: "code-block", title: "代码块", icon: "chevron.left.forwardslash.chevron.right", command: .codeBlock, markdown: nil),
            .init(id: "table", title: "表格 3×3", icon: "tablecells", command: nil, markdown: "| A | B | C |\n|---|---|---|\n|   |   |   |\n|   |   |   |\n"),
            .init(id: "footnote", title: "脚注", icon: "textformat.superscript", command: nil, markdown: "[^1]\n\n[^1]: "),
            .init(id: "toc", title: "目录", icon: "list.bullet.indent", command: nil, markdown: "[TOC]\n"),
            .init(id: "front-matter", title: "YAML Front Matter", icon: "slider.horizontal.3", command: nil, markdown: "---\ntitle: \n---\n")
        ]
    }

    private var isRawSourceMode: Bool { sourceMode?.wrappedValue ?? localRawSourceMode }

    private func toggleSourceMode() {
        if let sourceMode { sourceMode.wrappedValue.toggle() } else { localRawSourceMode.toggle() }
    }

    private func handleSlashPaletteKey(_ key: InlinePreviewKey) -> Bool {
        guard showsBlockMenu else { return false }
        switch key {
        case .moveUp: selectedSlashAction = max(0, selectedSlashAction - 1)
        case .moveDown: selectedSlashAction = min(slashActions.count - 1, selectedSlashAction + 1)
        case .confirm, .confirmAndOpen: executeSlashAction(selectedSlashAction)
        case .cancel: dismissSlashPalette()
        }
        return true
    }

    private func executeSlashAction(_ index: Int) {
        guard slashActions.indices.contains(index) else { return }
        let action = slashActions[index]
        dismissSlashPalette()
        if let command = action.command { commandCenter.perform(command) }
        if let markdown = action.markdown { commandCenter.insert(markdown) }
    }

    private func dismissSlashPalette() {
        showsBlockMenu = false
        slashAnchorRect = nil
    }

    private func slashButton(_ title: String, icon: String, command: MarkdownEditorCommand) -> some View {
        Button {
            showsBlockMenu = false
            commandCenter.perform(command)
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RepotraHoverButtonStyle())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func slashInsert(_ title: String, icon: String, markdown: String) -> some View {
        Button {
            showsBlockMenu = false
            commandCenter.insert(markdown)
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RepotraHoverButtonStyle())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func toolButton(_ systemName: String, help: String, command: MarkdownEditorCommand) -> some View {
        Button { commandCenter.perform(command) } label: {
            Image(systemName: systemName).frame(width: 28, height: 26)
        }
        .buttonStyle(RepotraHoverButtonStyle())
        .help(help)
    }

    private func importImage(from pasteboard: NSPasteboard) -> String? {
        let assetsURL = rootURL.appending(path: "assets", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
            if let source = PasteboardImageReader.imageFileURL(from: pasteboard) {
                let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
                let name = "\(UUID().uuidString.lowercased()).\(ext)"
                try FileManager.default.copyItem(at: source, to: assetsURL.appending(path: name))
                return "![image](assets/\(name))"
            }
            if let data = PasteboardImageReader.imageData(from: pasteboard) {
                let name = "\(UUID().uuidString.lowercased()).png"
                try data.write(to: assetsURL.appending(path: name), options: [.atomic])
                return "![image](assets/\(name))"
            }
        } catch {
            session.lastError = "图片导入失败：\(error.localizedDescription)"
        }
        return nil
    }

    private func copyCodeBlock(_ selection: CodeBlockSelection) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selection.code, forType: .string)
        copiedCodeBlockID = selection.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            if copiedCodeBlockID == selection.id {
                copiedCodeBlockID = nil
            }
        }
    }
}

struct MarkdownRenderOptions {
    var fontFamily = "SF Pro"
    var fontSize: CGFloat = 16
    var textColor: NSColor = .labelColor
    var accentColor: NSColor = .controlAccentColor
    var readingWidth: CGFloat?
}

private struct LibraryAssetProvider: EmbeddedImageProvider, @unchecked Sendable {
    let rootURL: URL
    private let cache = NSCache<NSString, NSImage>()

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        let decoded = reference.name.removingPercentEncoding ?? reference.name
        guard !decoded.contains(".."), !decoded.hasPrefix("/") else { return nil }
        let key = decoded as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = rootURL.appending(path: decoded).standardizedFileURL
        guard url.path.hasPrefix(rootURL.standardizedFileURL.path), let image = NSImage(contentsOf: url) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    func fingerprint() -> AnyHashable {
        rootURL.path
    }
}

private struct MarkdownCommandCenterKey: FocusedValueKey {
    typealias Value = MarkdownCommandCenter
}

extension FocusedValues {
    var markdownCommandCenter: MarkdownCommandCenter? {
        get { self[MarkdownCommandCenterKey.self] }
        set { self[MarkdownCommandCenterKey.self] = newValue }
    }
}
