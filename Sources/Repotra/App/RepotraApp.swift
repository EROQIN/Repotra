import SwiftUI

@main
struct RepotraApp: App {
    @NSApplicationDelegateAdaptor(RepotraApplicationDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(model)
                .task { await model.start() }
                .onAppear { appDelegate.model = model }
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建笔记") { Task { await model.createNote() } }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("新建文件夹") { Task { await model.createFolder() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("笔记") {
                Button("钉到桌面 / 取消钉住") { Task { await model.togglePinnedSelectedNote() } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("立即保存") { Task { await model.selectedSession?.saveNow() } }
                    .keyboardShortcut("s", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 460, height: 220)
        }
    }
}

@MainActor
final class RepotraApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
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

    var body: some View {
        Form {
            LabeledContent("当前资料库") {
                Text(model.libraryURL?.path ?? "未选择")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button("切换资料库…") { model.chooseLibrary() }
        }
        .formStyle(.grouped)
        .padding()
    }
}
