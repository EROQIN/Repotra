import SwiftUI

extension Notification.Name {
    static let repotraToggleSidebar = Notification.Name("Repotra.ToggleSidebar")
    static let repotraFocusTitle = Notification.Name("Repotra.FocusTitle")
}

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        Group {
            if model.libraryURL == nil {
                WelcomeView()
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    LibrarySidebar()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
                } detail: {
                    editorDetail
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let session = model.selectedSession {
                    DocumentToolbarTitle(session: session)
                        .environment(model)
                        .frame(width: 380)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let session = model.selectedSession {
                    DocumentToolbarActions(session: session)
                        .environment(model)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .repotraToggleSidebar)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        .overlay {
            if model.isLoading {
                ProgressView()
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: Binding(
            get: { model.isLibraryPickerPresented },
            set: { if !$0 { model.dismissLibraryPicker() } }
        )) {
            LibraryLocationPicker().environment(model)
        }
        .alert("Repotra", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "发生未知错误。")
        }
    }

    @ViewBuilder
    private var editorDetail: some View {
        if let session = model.selectedSession, let rootURL = model.libraryURL {
            MarkdownEditorView(
                session: session,
                rootURL: rootURL,
                context: .main,
                importImageFile: { url in await model.importImage(from: url) },
                importImageData: { data in await model.importImage(data: data) }
            )
            .background(Color(nsColor: .textBackgroundColor))
            .sheet(isPresented: Binding(
                get: { session.conflict != nil },
                set: { _ in }
            )) {
                ConflictResolutionView(session: session).environment(model)
            }
        } else {
            ContentUnavailableView(
                "选择一篇笔记",
                systemImage: "doc.text",
                description: Text("从侧边栏选择笔记，或按 ⌘N 新建。")
            )
        }
    }
}

private struct DocumentToolbarTitle: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: NoteSession
    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @State private var titleError: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        titleEditor
        .onReceive(NotificationCenter.default.publisher(for: .repotraFocusTitle)) { _ in beginEditing() }
        .onChange(of: model.titleEditRequestPath) { _, path in
            guard path == session.relativePath else { return }
            model.titleEditRequestPath = nil
            beginEditing()
        }
    }

    @ViewBuilder
    private var titleEditor: some View {
        if isEditingTitle {
            VStack(spacing: 1) {
                TextField("文件名", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    .onExitCommand { cancelEditing() }
                if let titleError {
                    Text(titleError).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
            .onChange(of: titleFocused) { _, focused in
                if !focused, isEditingTitle { commitTitle() }
            }
        } else {
            Button { beginEditing() } label: {
                HStack(spacing: 5) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击重命名")
        }
    }

    private func beginEditing() {
        draftTitle = session.title
        titleError = nil
        isEditingTitle = true
        Task { @MainActor in titleFocused = true }
    }

    private func cancelEditing() {
        isEditingTitle = false
        titleFocused = false
        titleError = nil
    }

    private func commitTitle() {
        guard isEditingTitle else { return }
        let value = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = model.filenameValidationError(value) {
            titleError = error
            titleFocused = true
            return
        }
        guard value != session.title else { cancelEditing(); return }
        Task {
            let renamed = await model.rename(path: session.relativePath, to: value)
            if renamed {
                cancelEditing()
            } else {
                titleError = model.errorMessage ?? "无法重命名。"
                model.errorMessage = nil
                titleFocused = true
            }
        }
    }
}

private struct DocumentToolbarActions: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: NoteSession

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                if session.isSaving { ProgressView().controlSize(.mini) }
                Text(session.isDirty ? "未保存" : "已保存")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 52)

            if let path = model.selectedPath {
                Button { Task { await model.togglePinnedSelectedNote() } } label: {
                    Image(systemName: model.stickyWindows.pinnedPaths.contains(path) ? "pin.fill" : "pin")
                }
                .help(model.stickyWindows.pinnedPaths.contains(path) ? "取消贴图" : "贴到桌面")
            }

            Menu {
                Button("立即保存") { Task { await session.saveNow() } }
                Button("重命名") {
                    NotificationCenter.default.post(name: .repotraFocusTitle, object: nil)
                }
                Divider()
                Button("在 Finder 中显示") { model.revealSelectedNote() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("更多")
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "note.text")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Repotra").font(.largeTitle.bold())
            Text("轻量 Markdown 笔记，也可以贴在桌面上。").foregroundStyle(.secondary)
            LibraryPickerButton("选择资料库…", isProminent: true).fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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
                Button("将本地内容另存副本") { Task { await model.resolveConflictBySavingCopy(session) } }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("覆盖外部版本", role: .destructive) { Task { await session.overwriteExternalVersion() } }
            }
        }
        .padding(28)
        .frame(width: 600)
    }
}
