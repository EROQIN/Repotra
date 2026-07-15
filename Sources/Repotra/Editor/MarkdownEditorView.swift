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
    var renderOptions = MarkdownRenderOptions()
    let importImageFile: @MainActor (URL) async -> String?
    let importImageData: @MainActor (Data) async -> String?

    @State private var commandCenter = MarkdownCommandCenter()
    @State private var rawSourceMode = false
    @State private var hasTextSelection = false
    @State private var showsBlockMenu = false
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
                onPasteImage: importImage(from:),
                onSlashCommand: { showsBlockMenu = true },
                onSelectionChange: { hasTextSelection = $0.length > 0 },
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
            if context == .main, hasTextSelection || showsBlockMenu {
                editorTools
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if context == .main, showsBlockMenu {
                slashPalette
                    .padding(.top, 54)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: hasTextSelection)
        .focusedSceneValue(\.markdownCommandCenter, commandCenter)
    }

    private var configuration: MarkdownEditorConfiguration {
        var value = MarkdownEditorConfiguration.default
        var theme = MarkdownEditorTheme.default
        theme.bodyText = renderOptions.textColor
        theme.mutedText = renderOptions.textColor.withAlphaComponent(0.48)
        theme.disabledText = renderOptions.textColor.withAlphaComponent(0.28)
        theme.headingMarker = renderOptions.textColor.withAlphaComponent(0.35)
        theme.link = NSColor.systemBlue
        theme.highlightColor = NSColor.systemYellow.withAlphaComponent(0.28)
        value.theme = theme
        value.services = MarkdownEditorServices(
            images: LibraryAssetProvider(rootURL: rootURL),
            syntaxHighlighter: Self.codeHighlighter,
            bus: commandCenter.bus
        )
        value.readingWidth = context == .main ? 720 : nil
        value.rawSourceMode = rawSourceMode
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
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("插入块 / Markdown 命令")

            Button {
                rawSourceMode.toggle()
            } label: {
                Image(systemName: rawSourceMode ? "doc.richtext.fill" : "chevron.left.forwardslash.chevron.right")
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .help(rawSourceMode ? "返回融合视图" : "显示 Markdown 源码")
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    private var slashPalette: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("插入 Markdown")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            slashButton("正文", icon: "textformat", command: .heading(0))
            slashButton("一级标题", icon: "textformat.size.larger", command: .heading(1))
            slashButton("引用", icon: "text.quote", command: .blockquote)
            slashButton("无序列表", icon: "list.bullet", command: .unorderedList)
            slashButton("有序列表", icon: "list.number", command: .orderedList)
            slashInsert("任务列表", icon: "checklist", markdown: "- [ ] ")
            slashButton("代码块", icon: "chevron.left.forwardslash.chevron.right", command: .codeBlock)
            slashInsert("表格 3×3", icon: "tablecells", markdown: "| A | B | C |\n|---|---|---|\n|   |   |   |\n|   |   |   |\n")
            slashInsert("脚注", icon: "textformat.superscript", markdown: "[^1]\n\n[^1]: ")
            slashInsert("目录", icon: "list.bullet.indent", markdown: "[TOC]\n")
            slashInsert("YAML Front Matter", icon: "slider.horizontal.3", markdown: "---\ntitle: \n---\n")
        }
        .padding(6)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.separator.opacity(0.45), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func slashButton(_ title: String, icon: String, command: MarkdownEditorCommand) -> some View {
        Button {
            showsBlockMenu = false
            commandCenter.perform(command)
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func toolButton(_ systemName: String, help: String, command: MarkdownEditorCommand) -> some View {
        Button { commandCenter.perform(command) } label: {
            Image(systemName: systemName).frame(width: 28, height: 26)
        }
        .buttonStyle(.plain)
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
