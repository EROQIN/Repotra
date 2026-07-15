import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.libraryURL == nil {
                WelcomeView()
            } else {
                NavigationSplitView {
                    LibrarySidebar()
                        .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 410)
                } detail: {
                    editorDetail
                }
                .toolbar { toolbarContent }
            }
        }
        .overlay {
            if model.isLoading {
                ProgressView()
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Repotra", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: {
                if !$0 {
                    model.errorMessage = nil
                }
            }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "发生未知错误。")
        }
    }

    @ViewBuilder
    private var editorDetail: some View {
        if let session = model.selectedSession, let rootURL = model.libraryURL {
            ZStack {
                Color(nsColor: .textBackgroundColor).ignoresSafeArea()
                MarkdownEditorView(
                    session: session,
                    rootURL: rootURL,
                    importImageFile: { url in await model.importImage(from: url) },
                    importImageData: { data in await model.importImage(data: data) }
                )
            }
            .navigationTitle(session.title)
            .sheet(isPresented: Binding(
                get: { session.conflict != nil },
                set: { _ in }
            )) {
                ConflictResolutionView(session: session)
                    .environment(model)
            }
        } else {
            ContentUnavailableView(
                "选择一篇笔记",
                systemImage: "doc.text",
                description: Text("从侧边栏选择笔记，或按 ⌘N 新建。")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await model.createNote() } } label: { Image(systemName: "square.and.pencil") }
                .help("新建笔记")
            Button { Task { await model.createFolder() } } label: { Image(systemName: "folder.badge.plus") }
                .help("新建文件夹")
            if let path = model.selectedPath, model.selectedSession != nil {
                Button { Task { await model.togglePinnedSelectedNote() } } label: {
                    Image(systemName: model.stickyWindows.pinnedPaths.contains(path) ? "pin.slash" : "pin")
                }
                .help(model.stickyWindows.pinnedPaths.contains(path) ? "取消钉住" : "钉到桌面")
            }
            Spacer()
            if let session = model.selectedSession {
                HStack(spacing: 5) {
                    if session.isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Text(session.isDirty ? "未保存" : "已保存")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "note.text")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.tint)
            Text("Repotra")
                .font(.largeTitle.bold())
            Text("轻量 Markdown 笔记，也可以贴在桌面上。")
                .foregroundStyle(.secondary)
            Button("选择资料库…") { model.chooseLibrary() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConflictResolutionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: NoteSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(
                session.conflict?.kind == .deleted ? "文件已被外部删除" : "文件已在其他应用中修改",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.title2.bold())
            .foregroundStyle(.orange)
            Text("Repotra 已暂停自动保存，因此本地输入不会覆盖外部内容。请选择处理方式。")
                .foregroundStyle(.secondary)
            HStack {
                if session.conflict?.diskSnapshot != nil {
                    Button("载入外部版本") { session.reloadExternalVersion() }
                }
                Button("将本地内容另存副本") {
                    Task { await model.resolveConflictBySavingCopy(session) }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("覆盖外部版本", role: .destructive) {
                    Task { await session.overwriteExternalVersion() }
                }
            }
        }
        .padding(28)
        .frame(width: 600)
    }
}
