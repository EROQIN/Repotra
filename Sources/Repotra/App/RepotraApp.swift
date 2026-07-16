import AppKit
import SwiftUI

@main
struct RepotraApp: App {
    @NSApplicationDelegateAdaptor(RepotraApplicationDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(model)
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
                Button("贴到桌面 / 取消贴图") { Task { await model.togglePinnedSelectedNote() } }
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
                .frame(width: 500, height: 330)
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
    @Environment(AppModel.self) private var model
    @State private var hotKey = GlobalHotKeyController.shared

    var body: some View {
        @Bindable var hotKey = hotKey
        Form {
            LabeledContent("当前资料库") {
                Text(model.libraryURL?.path ?? "未选择")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            LibraryPickerButton("切换资料库…")
                .fixedSize()
            Section("快速笔记") {
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
        .padding()
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
