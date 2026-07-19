import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct RepotraApp: App {
    @NSApplicationDelegateAdaptor(RepotraApplicationDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var appearance = AppAppearanceController.shared

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(model)
                .environment(appearance)
                .preferredColorScheme(appearance.preferences.interfaceTheme.colorScheme)
                .tint(appearance.preferences.accent.color)
                .onAppear { appDelegate.model = model }
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("打开资料库…") { model.presentLibraryPicker() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("新建笔记") { Task { await model.createNote() } }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("新建文件夹") { Task { await model.createFolder() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("笔记") {
                Button("显示或隐藏临时浮窗") { Task { await model.toggleFloatingSelectedNote() } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("立即保存") { Task { await model.selectedSession?.saveNow() } }
                    .keyboardShortcut("s", modifiers: [.command])
                Divider()
                Button("快速笔记") { model.requestQuickCapture() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("显示或隐藏侧栏") {
                    NotificationCenter.default.post(name: .repotraToggleSidebar, object: nil)
                }
                .keyboardShortcut("\\", modifiers: [.command])
                Button("重命名当前笔记") {
                    NotificationCenter.default.post(name: .repotraFocusTitle, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            MarkdownFormattingCommands()
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(appearance)
                .preferredColorScheme(appearance.preferences.interfaceTheme.colorScheme)
                .tint(appearance.preferences.accent.color)
                .frame(width: 540, height: 600)
        }
    }
}

@MainActor
final class RepotraApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet {
            GlobalHotKeyController.shared.onTrigger = { [weak self] in
                self?.model?.requestQuickCapture()
            }
        }
    }
    private var isFinishingTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinishingTermination, let model else { return .terminateNow }
        isFinishingTermination = true
        Task { @MainActor in
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct SettingsView: View {
    private enum MainColorTarget: String {
        case primary
        case secondary
        case text
    }

    @Environment(AppModel.self) private var model
    @Environment(AppAppearanceController.self) private var appearance
    @State private var hotKey = GlobalHotKeyController.shared
    @State private var activeMainColorTarget: MainColorTarget?
    @State private var showsMainBackgroundImporter = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }
            personalizationSettings
                .tabItem { Label("个性化", systemImage: "paintpalette") }
            quickNoteSettings
                .tabItem { Label("快速笔记", systemImage: "note.text") }
        }
        .padding(12)
        .fileImporter(
            isPresented: $showsMainBackgroundImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                await appearance.importBackground(from: url)
            }
        }
    }

    private var generalSettings: some View {
        Form {
            Section("资料库") {
                LabeledContent("当前资料库") {
                    Text(model.libraryURL?.path ?? "未选择")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LibraryPickerButton("切换资料库…")
                    .fixedSize()
            }
        }
        .formStyle(.grouped)
    }

    private var quickNoteSettings: some View {
        @Bindable var hotKey = hotKey
        return Form {
            Section("全局快捷键") {
                Toggle("启用全局快捷键", isOn: $hotKey.isEnabled)
                LabeledContent("唤起快捷键") {
                    ShortcutRecorderView(shortcut: $hotKey.shortcut)
                        .frame(width: 110, height: 28)
                }
                if let error = hotKey.registrationError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("恢复默认 ⌥⌘N") { hotKey.restoreDefault() }
            }
        }
        .formStyle(.grouped)
    }

    private var personalizationSettings: some View {
        Form {
            Section("应用界面") {
                Picker("界面主题", selection: appearanceBinding(\.interfaceTheme)) {
                    ForEach(AppInterfaceTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance-interface-theme")

                Picker("强调色", selection: appearanceBinding(\.accent)) {
                    ForEach(AppAccentChoice.allCases) { accent in
                        HStack(spacing: 7) {
                            Circle().fill(accent.color).frame(width: 10, height: 10)
                            Text(accent.title)
                        }
                        .tag(accent)
                    }
                }
                .accessibilityIdentifier("appearance-accent")
            }

            Section("写作区") {
                Picker("字体", selection: appearanceBinding(\.editorFontFamily)) {
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .accessibilityIdentifier("appearance-editor-font")

                settingSlider(
                    "字号",
                    value: appearanceBinding(\.editorFontSize),
                    range: 11 ... 30,
                    step: 1,
                    valueText: "\(Int(appearance.preferences.editorFontSize)) pt"
                )
                .accessibilityIdentifier("appearance-editor-font-size")
                settingSlider(
                    "内容宽度",
                    value: appearanceBinding(\.editorReadingWidth),
                    range: 560 ... 960,
                    step: 20,
                    valueText: "\(Int(appearance.preferences.editorReadingWidth)) pt"
                )
                .accessibilityIdentifier("appearance-editor-reading-width")

            }

            Section("主页面背景") {
                Picker("背景预设", selection: canvasPresetBinding) {
                    ForEach(EditorCanvasStyle.selectableCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                    if appearance.selectedCanvasPreset == .custom {
                        Text(EditorCanvasStyle.custom.title).tag(EditorCanvasStyle.custom)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance-editor-canvas")

                Picker("背景类型", selection: backgroundKindBinding) {
                    ForEach(AppBackgroundKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .accessibilityIdentifier("appearance-background-kind")

                if appearance.preferences.background.kind != .system {
                    mainColorEditorRow(
                        "主背景色",
                        target: .primary,
                        binding: backgroundColorBinding(\.primaryColor)
                    )
                }
                if appearance.preferences.background.kind == .gradient {
                    mainColorEditorRow(
                        "渐变色",
                        target: .secondary,
                        binding: backgroundColorBinding(\.secondaryColor)
                    )
                }
                if appearance.preferences.background.kind == .image {
                    HStack {
                        Button("更换背景图片…") { showsMainBackgroundImporter = true }
                            .accessibilityIdentifier("appearance-background-image")
                        Button("移除图片", role: .destructive) { appearance.removeBackgroundImage() }
                    }
                    Picker("图片填充", selection: backgroundBinding(\.imageScaling)) {
                        Text("填充").tag(StickyImageScaling.fill)
                        Text("适应").tag(StickyImageScaling.fit)
                        Text("拉伸").tag(StickyImageScaling.stretch)
                    }
                    settingSlider(
                        "遮罩强度",
                        value: backgroundBinding(\.imageOverlayOpacity),
                        range: 0 ... 0.7,
                        step: 0.05,
                        valueText: "\(Int((appearance.preferences.background.imageOverlayOpacity * 100).rounded()))%"
                    )
                    .accessibilityIdentifier("appearance-background-overlay")
                } else if appearance.preferences.background.kind != .system {
                    Button("选择背景图片…") { showsMainBackgroundImporter = true }
                        .accessibilityIdentifier("appearance-background-image")
                }

                Toggle("自动文字颜色", isOn: automaticTextColorBinding)
                    .accessibilityIdentifier("appearance-background-auto-text")
                if appearance.preferences.background.textColorMode == .manual {
                    mainColorEditorRow(
                        "文字颜色",
                        target: .text,
                        binding: backgroundColorBinding(\.manualTextColor)
                    )
                }
            }

            if let message = appearance.errorMessage ?? appearance.warning {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(appearance.errorMessage == nil ? .orange : .red)
                    .accessibilityIdentifier("appearance-message")
            }

            Button("恢复默认") { appearance.reset() }
                .accessibilityIdentifier("appearance-reset")
        }
        .formStyle(.grouped)
    }

    private var fontFamilies: [String] {
        let preferred = ["SF Pro", "Helvetica Neue", "Avenir Next", "Menlo", "PingFang SC"]
        return preferred + NSFontManager.shared.availableFontFamilies
            .filter { !preferred.contains($0) }
            .sorted()
    }

    private func appearanceBinding<Value>(
        _ keyPath: WritableKeyPath<AppAppearancePreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { appearance.preferences[keyPath: keyPath] },
            set: { value in appearance.update { $0[keyPath: keyPath] = value } }
        )
    }

    private var canvasPresetBinding: Binding<EditorCanvasStyle> {
        Binding(
            get: { appearance.selectedCanvasPreset },
            set: { appearance.applyCanvasPreset($0) }
        )
    }

    private var backgroundKindBinding: Binding<AppBackgroundKind> {
        Binding(
            get: { appearance.preferences.background.kind },
            set: { kind in
                if kind == .image, appearance.preferences.background.imageFileName == nil {
                    showsMainBackgroundImporter = true
                } else {
                    appearance.update { $0.background.kind = kind }
                }
            }
        )
    }

    private var automaticTextColorBinding: Binding<Bool> {
        Binding(
            get: { appearance.preferences.background.textColorMode == .automatic },
            set: { automatic in
                appearance.update {
                    $0.background.textColorMode = automatic ? .automatic : .manual
                }
            }
        )
    }

    private func backgroundBinding<Value>(
        _ keyPath: WritableKeyPath<AppBackgroundConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { appearance.preferences.background[keyPath: keyPath] },
            set: { value in appearance.update { $0.background[keyPath: keyPath] = value } }
        )
    }

    private func backgroundColorBinding(
        _ keyPath: WritableKeyPath<AppBackgroundConfiguration, String>
    ) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: PathUtilities.hexColor(appearance.preferences.background[keyPath: keyPath])) },
            set: { color in
                let value = PathUtilities.hexString(NSColor(color), includeAlpha: true)
                appearance.update { $0.background[keyPath: keyPath] = value }
            }
        )
    }

    @ViewBuilder
    private func mainColorEditorRow(
        _ title: String,
        target: MainColorTarget,
        binding: Binding<Color>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    activeMainColorTarget = activeMainColorTarget == target ? nil : target
                }
            } label: {
                HStack {
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    Text(InlineColorEditor.hexString(for: binding.wrappedValue))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(binding.wrappedValue)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(.primary.opacity(0.18), lineWidth: 0.75))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(activeMainColorTarget == target ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RepotraHoverButtonStyle())
            .accessibilityIdentifier("appearance-background-color-\(target.rawValue)")

            if activeMainColorTarget == target {
                InlineColorEditor(color: binding)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func settingSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step)
                    .frame(width: 205)
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

private struct MarkdownFormattingCommands: Commands {
    @FocusedValue(\.markdownCommandCenter) private var commandCenter

    var body: some Commands {
        CommandMenu("格式") {
            Button("粗体") { commandCenter?.perform(.bold) }
                .keyboardShortcut("b", modifiers: [.command])
            Button("斜体") { commandCenter?.perform(.italic) }
                .keyboardShortcut("i", modifiers: [.command])
            Button("链接") { commandCenter?.perform(.link) }
                .keyboardShortcut("k", modifiers: [.command])
            Button("删除线") { commandCenter?.perform(.strikethrough) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("高亮") { commandCenter?.perform(.highlight) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("行内代码") { commandCenter?.perform(.inlineCode) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            ForEach(0 ... 6, id: \.self) { level in
                Button(level == 0 ? "正文" : "标题 \(level)") {
                    commandCenter?.perform(.heading(level))
                }
                .keyboardShortcut(KeyEquivalent(Character(String(level))), modifiers: [.command])
            }
            Divider()
            Button("引用") { commandCenter?.perform(.blockquote) }
                .keyboardShortcut("q", modifiers: [.command, .shift])
            Button("代码块") { commandCenter?.perform(.codeBlock) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("无序列表") { commandCenter?.perform(.unorderedList) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("有序列表") { commandCenter?.perform(.orderedList) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("任务列表") { commandCenter?.insert("- [ ] ") }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("插入图片") { commandCenter?.perform(.image) }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
