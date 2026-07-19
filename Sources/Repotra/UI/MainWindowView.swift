import AppKit
import MarkdownEngine
import SwiftUI

extension Notification.Name {
    static let repotraToggleSidebar = Notification.Name("Repotra.ToggleSidebar")
    static let repotraFocusTitle = Notification.Name("Repotra.FocusTitle")
}

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppAppearanceController.self) private var appearance
    @State private var navigationRequest = 0
    @State private var navigationLocation = 0
    @State private var rawSourceMode = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            AppearanceBackgroundView(
                presentation: .app(
                    appearance.preferences.background,
                    backgroundsURL: AppAppearanceStore.defaultBackgroundsURL()
                )
            )
            .id(appearance.preferences.background)
            .allowsHitTesting(false)
            .ignoresSafeArea()

            Group {
                if model.libraryURL == nil {
                    WelcomeView()
                } else {
                    GeometryReader { proxy in
                        HStack(spacing: 0) {
                            if model.showsSidebar && proxy.size.width >= 790 {
                                LibrarySidebar()
                                    .frame(width: min(270, max(228, proxy.size.width * 0.22)))
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                                Divider().opacity(dividerOpacity)
                            }

                            EditorWorkspace(
                                navigationRequest: $navigationRequest,
                                navigationLocation: $navigationLocation,
                                rawSourceMode: $rawSourceMode
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if model.showsInspector && proxy.size.width >= 1080 {
                                Divider().opacity(dividerOpacity)
                                DocumentInspector { location in
                                    navigationLocation = location
                                    navigationRequest &+= 1
                                }
                                .frame(width: min(292, max(248, proxy.size.width * 0.21)))
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(WindowFrameAutosaver(name: "Repotra.MainWindow"))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.showsSidebar.toggle() }
                    model.updateDisplayState()
                } label: {
                    Image(systemName: "sidebar.left").frame(width: 28, height: 28)
                }
                .buttonStyle(RepotraHoverButtonStyle())
                .help(model.showsSidebar ? "隐藏侧栏" : "显示侧栏")
                Button { Task { await model.goBack() } } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }
                .buttonStyle(RepotraHoverButtonStyle())
                .disabled(!model.canGoBack).help("后退")
                Button { Task { await model.goForward() } } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 28)
                }
                .buttonStyle(RepotraHoverButtonStyle())
                .disabled(!model.canGoForward).help("前进")
            }
            ToolbarItem(placement: .principal) {
                if let session = model.selectedSession {
                    ToolbarDocumentTitle(session: session)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let session = model.selectedSession {
                    SaveStatusView(session: session)
                    Picker("编辑模式", selection: $rawSourceMode) {
                        Text("融合").tag(false)
                        Text("源码").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 104)
                    Button { model.toggleFavorite() } label: {
                        Image(systemName: model.isSelectedFavorite ? "star.fill" : "star")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(RepotraHoverButtonStyle(isSelected: model.isSelectedFavorite))
                    .help("收藏")
                    Button { Task { await model.toggleFloatingSelectedNote() } } label: {
                        Image(systemName: "macwindow").frame(width: 28, height: 28)
                    }
                    .buttonStyle(RepotraHoverButtonStyle())
                    .help("在临时浮窗中打开")
                    Menu {
                        Button("立即保存") { Task { await session.saveNow() } }
                        Button("重命名") { NotificationCenter.default.post(name: .repotraFocusTitle, object: nil) }
                        Divider()
                        Button("在 Finder 中显示") { model.revealSelectedNote() }
                        Button("移到废纸篓", role: .destructive) {
                            Task { await model.delete(path: session.relativePath) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                            .repotraHoverFeedback()
                    }
                    .menuIndicator(.hidden)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.showsInspector.toggle() }
                    model.updateDisplayState()
                } label: {
                    Image(systemName: "sidebar.right").frame(width: 28, height: 28)
                }
                .buttonStyle(RepotraHoverButtonStyle())
                .help(model.showsInspector ? "隐藏检查器" : "显示检查器")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .repotraToggleSidebar)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) { model.showsSidebar.toggle() }
            model.updateDisplayState()
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

    private var dividerOpacity: Double {
        appearance.preferences.background.kind == .system ? 0.45 : 0.28
    }
}

private struct EditorWorkspace: View {
    @Environment(AppModel.self) private var model
    @Environment(AppAppearanceController.self) private var appearance
    @Binding var navigationRequest: Int
    @Binding var navigationLocation: Int
    @Binding var rawSourceMode: Bool

    var body: some View {
        if let session = model.selectedSession, let rootURL = model.libraryURL {
            VStack(spacing: 0) {
                MarkdownEditorView(
                    session: session,
                    rootURL: rootURL,
                    context: .main,
                    navigationRequest: navigationRequest,
                    navigationLocation: navigationLocation,
                    sourceMode: $rawSourceMode,
                    renderOptions: MarkdownRenderOptions(
                        fontFamily: appearance.preferences.editorFontFamily,
                        fontSize: appearance.preferences.editorFontSize,
                        textColor: appearance.preferences.background.resolvedTextColor,
                        accentColor: appearance.preferences.accent.nsColor,
                        readingWidth: appearance.preferences.editorReadingWidth
                    ),
                    importImageFile: { url in await model.importImage(from: url) },
                    importImageData: { data in await model.importImage(data: data) }
                )
                .background(Color.clear)
            }
            .sheet(isPresented: Binding(
                get: { session.conflict != nil },
                set: { _ in }
            )) {
                ConflictResolutionView(session: session).environment(model)
            }
        } else {
            EmptyWorkspaceView()
        }
    }
}

private struct ToolbarDocumentTitle: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: NoteSession

    var body: some View {
        HStack(spacing: 6) {
            Text(breadcrumb)
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.quaternary)
            DocumentTitle(session: session)
        }
        .frame(minWidth: 190, maxWidth: 390)
    }

    private var breadcrumb: String {
        let parent = (session.relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? model.libraryURL?.lastPathComponent ?? "资料库" : parent
    }
}

private struct DocumentHeader: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: NoteSession
    @Binding var rawSourceMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    HeaderButton("chevron.left", help: "上一处") { Task { await model.goBack() } }
                        .disabled(!model.canGoBack)
                    HeaderButton("chevron.right", help: "下一处") { Task { await model.goForward() } }
                        .disabled(!model.canGoForward)
                }

                Text(breadcrumb)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 10)
                SaveStatusView(session: session)

                Picker("编辑模式", selection: $rawSourceMode) {
                    Text("融合").tag(false)
                    Text("源码").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 108)

                HeaderButton(model.isSelectedFavorite ? "star.fill" : "star", help: "收藏") {
                    model.toggleFavorite()
                }
                HeaderButton(
                    model.stickyWindows.pinnedPaths.contains(session.relativePath) ? "pin.fill" : "pin",
                    help: "贴到桌面"
                ) { Task { await model.togglePinnedSelectedNote() } }

                Menu {
                    Button("立即保存") { Task { await session.saveNow() } }
                    Button("重命名") { NotificationCenter.default.post(name: .repotraFocusTitle, object: nil) }
                    Divider()
                    Button("在 Finder 中显示") { model.revealSelectedNote() }
                    Button("移到废纸篓", role: .destructive) {
                        Task { await model.delete(path: session.relativePath) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                        .repotraHoverFeedback()
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 18)
            .frame(height: 42)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                DocumentTitle(session: session)
                Spacer()
                Text(session.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 13)
        }
        .background(.ultraThinMaterial)
    }

    private var breadcrumb: String {
        let parent = (session.relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? model.libraryURL?.lastPathComponent ?? "资料库" : parent
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 28)
        }
        .buttonStyle(RepotraHoverButtonStyle(cornerRadius: 7))
        .help(help)
    }
}

private struct SaveStatusView: View {
    @Bindable var session: NoteSession

    var body: some View {
        if session.conflict != nil {
            Label("冲突", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if session.lastError != nil {
            Label("保存失败", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        } else if session.isSaving {
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("保存中") }
        } else if session.isDirty {
            Label("未保存", systemImage: "circle.fill").foregroundStyle(.secondary)
        }
    }
}

private struct DocumentTitle: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: NoteSession
    @State private var isEditing = false
    @State private var draft = ""
    @State private var error: String?
    @State private var conflict: NoteRenameConflict?
    @State private var isRenaming = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("文件名", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($focused)
                        .onSubmit { commit() }
                        .onExitCommand { cancel() }
                    if let error { Text(error).font(.caption2).foregroundStyle(.red) }
                }
            } else {
                Button { begin() } label: {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RepotraHoverButtonStyle())
                .help("点击重命名")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .repotraFocusTitle)) { _ in begin() }
        .onChange(of: model.titleEditRequestPath) { _, path in
            guard path == session.relativePath else { return }
            model.titleEditRequestPath = nil
            begin()
        }
        .onChange(of: focused) { _, value in
            if !value, isEditing, conflict == nil, !isRenaming { commit() }
        }
        .onChange(of: conflict) { oldValue, newValue in
            if oldValue != nil, newValue == nil, isEditing, !isRenaming {
                Task { @MainActor in focused = true }
            }
        }
        .noteRenameConflictDialog(
            conflict: $conflict,
            onResolve: { resolution in
                conflict = nil
                commit(resolution: resolution)
            },
            onCancel: {
                conflict = nil
                Task { @MainActor in focused = true }
            }
        )
    }

    private func begin() {
        draft = session.title
        error = nil
        conflict = nil
        isEditing = true
        Task { @MainActor in focused = true }
    }

    private func cancel() {
        isEditing = false
        focused = false
        error = nil
        conflict = nil
        isRenaming = false
    }

    private func commit(resolution: RenameConflictResolution? = nil) {
        guard isEditing, !isRenaming else { return }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validation = model.filenameValidationError(value) {
            error = validation
            focused = true
            return
        }
        guard value != session.title || resolution != nil else { cancel(); return }
        isRenaming = true
        Task {
            let outcome = await model.renameNote(
                path: session.relativePath,
                to: value,
                resolution: resolution
            )
            isRenaming = false
            switch outcome {
            case .renamed:
                cancel()
            case let .conflict(value):
                conflict = value
                focused = false
            case let .failed(message):
                error = message
                focused = true
            }
        }
    }
}

private struct DocumentInspector: View {
    @Environment(AppModel.self) private var model
    let navigate: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("大纲")
                .font(.headline)
                .padding(.horizontal, 18)
                .frame(height: 46)
            Divider().opacity(0.45)
            if let session = model.selectedSession {
                let outline = session.outline
                if outline.isEmpty {
                    Text("添加标题后会在这里形成大纲")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(18)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(outline) { item in
                                Button { navigate(item.sourceRange.location) } label: {
                                    Text(item.title)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, CGFloat(item.level - 1) * 12)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(RepotraHoverButtonStyle())
                            }
                        }
                        .padding(9)
                    }
                }
                Divider().opacity(0.45)
                PropertiesView(session: session)
            } else {
                Spacer()
            }
        }
        .background(.ultraThinMaterial)
    }
}

private struct PropertiesView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: NoteSession

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("属性").font(.headline)
            property("路径", session.relativePath)
            property("修改", session.modifiedAt.formatted(date: .numeric, time: .shortened))
            property("字数", "\(wordCount)")
            property("字符", "\(session.content.count)")
            Toggle("收藏", isOn: Binding(get: { model.isSelectedFavorite }, set: { _ in model.toggleFavorite() }))
        }
        .font(.callout)
        .padding(18)
    }

    private var wordCount: Int {
        session.content.split { $0.isWhitespace || $0.isPunctuation }.count
    }

    private func property(_ name: String, _ value: String) -> some View {
        LabeledContent(name) {
            Text(value).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
        }
    }
}

private struct EmptyWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppAppearanceController.self) private var appearance
    var body: some View {
        VStack(spacing: 13) {
            BrandSpotImage(name: "empty-note")
                .frame(width: 104, height: 104)
            Text("选择一篇笔记").font(.title2.weight(.semibold))
            Text("从侧栏打开笔记，或按 ⌘N 创建新内容。")
                .foregroundStyle(
                    Color(nsColor: appearance.preferences.background.resolvedTextColor).opacity(0.66)
                )
            Button("新建笔记") {
                Task { await model.createNote() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color(nsColor: appearance.preferences.background.resolvedTextColor))
        .background(Color.clear)
    }
}

private struct WelcomeView: View {
    @Environment(AppAppearanceController.self) private var appearance

    var body: some View {
        VStack(spacing: 18) {
            BrandSpotImage(name: "choose-library").frame(width: 124, height: 124)
            Text("Repotra").font(.system(size: 36, weight: .bold, design: .rounded))
            Text("让本地 Markdown 回到安静、顺手的写作体验。")
                .foregroundStyle(Color(nsColor: appearance.preferences.background.resolvedTextColor).opacity(0.66))
            LibraryPickerButton("选择资料库…", isProminent: true).fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color(nsColor: appearance.preferences.background.resolvedTextColor))
        .background(Color.clear)
    }
}

private struct ConflictResolutionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: NoteSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                BrandSpotImage(name: "file-conflict").frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.conflict?.kind == .deleted ? "文件已被外部删除" : "文件已在其他应用中修改")
                        .font(.title2.bold())
                    Text("自动保存已暂停，本地输入不会覆盖外部内容。")
                        .foregroundStyle(.secondary)
                }
            }
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
        .frame(width: 620)
    }
}

private struct WindowFrameAutosaver: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.setFrameAutosaveName(name) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window?.frameAutosaveName != name { nsView.window?.setFrameAutosaveName(name) }
    }
}
