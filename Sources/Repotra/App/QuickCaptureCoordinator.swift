import AppKit
import Observation
import SwiftUI

@MainActor
struct QuickCapturePresentation {
    let sessions: [QuickNoteSessionRecord]
    let activeSessionID: UUID
    let sessionProvider: @MainActor (UUID) async -> NoteSession?
    let createSession: @MainActor () async -> UUID?
    let renameSession: @MainActor (UUID, String, RenameConflictResolution?) async -> NoteRenameOutcome
    let deleteSession: @MainActor (UUID) async -> Void
    let recordsProvider: @MainActor () async -> ([QuickNoteSessionRecord], UUID?)
}

@MainActor
@Observable
private final class FloatingEditorState {
    var session: NoteSession?
    private(set) var focusRequest = 0
    var records: [QuickNoteSessionRecord] = []
    var activeSessionID: UUID?
    @ObservationIgnored var presentation: QuickCapturePresentation?

    func configure(
        session: NoteSession,
        presentation: QuickCapturePresentation? = nil,
        requestsEditorFocus: Bool = true
    ) {
        self.session = session
        self.presentation = presentation
        records = presentation?.sessions ?? []
        activeSessionID = presentation?.activeSessionID
        if requestsEditorFocus { requestFocusAtEnd() }
    }

    func switchSession(to id: UUID) async {
        guard id != activeSessionID, let presentation else { return }
        await session?.saveNow()
        guard let next = await presentation.sessionProvider(id) else { return }
        session = next
        activeSessionID = id
        await refreshRecords()
        requestFocusAtEnd()
    }

    func createSession() async {
        guard let presentation else { return }
        await session?.saveNow()
        guard let id = await presentation.createSession(),
              let next = await presentation.sessionProvider(id) else { return }
        session = next
        activeSessionID = id
        await refreshRecords()
        requestFocusAtEnd()
    }

    func renameActive(
        to value: String,
        resolution: RenameConflictResolution? = nil
    ) async -> NoteRenameOutcome {
        guard let id = activeSessionID, let presentation else {
            return .failed("找不到快速笔记会话。")
        }
        let result = await presentation.renameSession(id, value, resolution)
        if result.succeeded { await refreshRecords() }
        return result
    }

    func deleteActive() async {
        guard let id = activeSessionID, let presentation else { return }
        await session?.saveNow()
        await presentation.deleteSession(id)
        await refreshRecords()
        guard let nextID = activeSessionID,
              let next = await presentation.sessionProvider(nextID) else {
            session = nil
            return
        }
        session = next
        requestFocusAtEnd()
    }

    func requestFocusAtEnd() { focusRequest &+= 1 }

    private func refreshRecords() async {
        guard let presentation else { return }
        let state = await presentation.recordsProvider()
        records = state.0.sorted { $0.createdAt < $1.createdAt }
        activeSessionID = state.1 ?? records.first?.id
    }
}

@MainActor
final class QuickCaptureCoordinator: NSObject, NSWindowDelegate {
    private static let frameAutosaveName = "Repotra.QuickCaptureFrame"
    private var panel: FloatingPanel?
    private let state = FloatingEditorState()
    private let appearanceController: QuickNoteAppearanceController
    private let appAppearance = AppAppearanceController.shared
    private let backgroundDirectoryURL = QuickNoteAppearanceStore.defaultBackgroundsURL()

    override init() {
        appearanceController = QuickNoteAppearanceController()
        super.init()
        appearanceController.onPreviewChange = { [weak self] appearance in self?.apply(appearance) }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(
        session: NoteSession,
        presentation: QuickCapturePresentation,
        rootURL: URL,
        importImageFile: @escaping @MainActor (URL) async -> String?,
        importImageData: @escaping @MainActor (Data) async -> String?
    ) async {
        if isVisible { hide(); return }
        await show(session: session, presentation: presentation, rootURL: rootURL,
                   importImageFile: importImageFile, importImageData: importImageData)
    }

    func show(
        session: NoteSession,
        presentation: QuickCapturePresentation,
        rootURL: URL,
        activatesEditor: Bool = true,
        importImageFile: @escaping @MainActor (URL) async -> String?,
        importImageData: @escaping @MainActor (Data) async -> String?
    ) async {
        await appearanceController.loadIfNeeded(force: true)
        state.configure(
            session: session,
            presentation: presentation,
            requestsEditorFocus: activatesEditor
        )
        if let panel {
            panel.orderFrontRegardless()
            if activatesEditor { panel.makeKey() }
            return
        }
        let panel = makePanel(title: "快速笔记", frameName: Self.frameAutosaveName)
        panel.onHide = { [weak self] in self?.hide() }
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatingEditorView(
            state: state,
            rootURL: rootURL,
            appearanceController: appearanceController,
            appAppearance: appAppearance,
            backgroundDirectoryURL: backgroundDirectoryURL,
            showsSessionManager: true,
            importImageFile: importImageFile,
            importImageData: importImageData
        ))
        self.panel = panel
        apply(appearanceController.preview)
        restore(panel, name: Self.frameAutosaveName)
        panel.orderFrontRegardless()
        if activatesEditor { panel.makeKey() }
    }

    func hide() {
        appearanceController.cancel()
        panel?.orderOut(nil)
        let session = state.session
        Task { @MainActor in await session?.saveNow() }
    }

    func closeForLibrarySwitch() async {
        appearanceController.cancel()
        await state.session?.saveNow()
        panel?.delegate = nil; panel?.close(); panel = nil
        state.session = nil
    }

    func persistNow() async {
        appearanceController.cancel()
        await state.session?.saveNow()
    }

    func closeIfPresenting(path: String) async {
        guard state.session?.relativePath == path else { return }
        appearanceController.cancel()
        await state.session?.saveNow()
        panel?.delegate = nil
        panel?.close()
        panel = nil
        state.session = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

    private func apply(_ appearance: QuickNoteAppearance) {
        panel?.isOpaque = false
        panel?.backgroundColor = .clear
        panel?.alphaValue = min(1, max(0.35, appearance.opacity))
        panel?.hasShadow = appearance.hasShadow
    }
}

@MainActor
final class FloatingNoteCoordinator: NSObject, NSWindowDelegate {
    private static let frameAutosaveName = "Repotra.FloatingNoteFrame"
    private var panel: FloatingPanel?
    private let state = FloatingEditorState()
    private let appearanceController = QuickNoteAppearanceController()
    private let appAppearance = AppAppearanceController.shared

    func toggle(
        session: NoteSession,
        rootURL: URL,
        importImageFile: @escaping @MainActor (URL) async -> String?,
        importImageData: @escaping @MainActor (Data) async -> String?
    ) async {
        if panel?.isVisible == true, state.session?.relativePath == session.relativePath { hide(); return }
        await state.session?.saveNow()
        await appearanceController.loadIfNeeded(force: true)
        state.configure(session: session)
        if let panel {
            panel.orderFrontRegardless(); panel.makeKey(); return
        }
        let panel = makePanel(title: session.title, frameName: Self.frameAutosaveName)
        panel.onHide = { [weak self] in self?.hide() }
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatingEditorView(
            state: state,
            rootURL: rootURL,
            appearanceController: appearanceController,
            appAppearance: appAppearance,
            backgroundDirectoryURL: QuickNoteAppearanceStore.defaultBackgroundsURL(),
            showsSessionManager: false,
            importImageFile: importImageFile,
            importImageData: importImageData
        ))
        self.panel = panel
        panel.alphaValue = min(1, max(0.35, appearanceController.preview.opacity))
        panel.hasShadow = appearanceController.preview.hasShadow
        restore(panel, name: Self.frameAutosaveName)
        panel.orderFrontRegardless(); panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
        let session = state.session
        Task { @MainActor in await session?.saveNow() }
    }

    func persistNow() async { await state.session?.saveNow() }
    func closeIfPresenting(path: String) async {
        guard state.session?.relativePath == path else { return }
        await state.session?.saveNow()
        panel?.delegate = nil
        panel?.close()
        panel = nil
        state.session = nil
    }
    func closeForLibrarySwitch() async {
        await state.session?.saveNow()
        panel?.delegate = nil
        panel?.close()
        panel = nil
        state.session = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
}

private final class FloatingPanel: NSPanel {
    var onHide: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onHide?() }
}

@MainActor
private func makePanel(title: String, frameName: String) -> FloatingPanel {
    let panel = FloatingPanel(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
        styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    panel.title = title
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.toolTip = "隐藏窗口"
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 420, height: 300)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return panel
}

@MainActor
private func restore(_ panel: NSPanel, name: String) {
    let restored = panel.setFrameUsingName(name)
    _ = panel.setFrameAutosaveName(name)
    if !restored { panel.center(); return }
    guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) else {
        panel.setContentSize(NSSize(width: 560, height: 420)); panel.center(); return
    }
    if let screen = panel.screen ?? NSScreen.main {
        panel.setFrame(panel.constrainFrameRect(panel.frame, to: screen), display: false)
    }
}

private struct FloatingEditorView: View {
    @Bindable var state: FloatingEditorState
    let rootURL: URL
    @Bindable var appearanceController: QuickNoteAppearanceController
    @Bindable var appAppearance: AppAppearanceController
    let backgroundDirectoryURL: URL
    let showsSessionManager: Bool
    let importImageFile: @MainActor (URL) async -> String?
    let importImageData: @MainActor (Data) async -> String?
    @State private var showsAppearance = false
    @State private var showsSessions = false

    var body: some View {
        let appearance = appearanceController.preview
        ZStack {
            AppearanceBackgroundView(presentation: .quickNote(appearance.background, backgroundsURL: backgroundDirectoryURL))
                .id(appearanceController.revision)
            if let session = state.session {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        FloatingTitle(state: state, session: session, canRename: showsSessionManager)
                        Spacer()
                        FloatingSaveStatus(
                            session: session,
                            accessibilityIdentifier: showsSessionManager
                                ? "quick-note-save-status"
                                : "floating-note-save-status"
                        )
                        if showsSessionManager {
                            Button {
                                showsAppearance = false
                                appearanceController.cancel()
                                showsSessions.toggle()
                            } label: {
                                FloatingHeaderIcon(symbol: "rectangle.stack")
                            }
                            .buttonStyle(RepotraHoverButtonStyle())
                            .accessibilityLabel("快速笔记会话")
                            .accessibilityIdentifier("quick-note-sessions")
                            .help("切换快速笔记")
                            .popover(isPresented: $showsSessions, arrowEdge: .bottom) {
                                QuickSessionSwitcher(
                                    state: state,
                                    dismiss: { showsSessions = false }
                                )
                            }
                        }
                        Button {
                            showsSessions = false
                            if showsAppearance { showsAppearance = false }
                            else { appearanceController.beginEditing(); showsAppearance = true }
                        } label: {
                            FloatingHeaderIcon(symbol: "slider.horizontal.3")
                        }
                        .buttonStyle(RepotraHoverButtonStyle())
                        .accessibilityIdentifier(showsSessionManager ? "quick-note-settings" : "floating-note-settings")
                        .help("外观设置")
                        .popover(isPresented: $showsAppearance, arrowEdge: .bottom) {
                            QuickNoteAppearanceEditor(
                                controller: appearanceController,
                                onCancel: { appearanceController.cancel() },
                                onCommit: { await appearanceController.commit() }
                            )
                        }
                    }
                    .padding(.leading, 72)
                    .padding(.trailing, 12)
                    .frame(height: 34)
                    .background(.ultraThinMaterial)
                    Divider().opacity(0.35)
                    MarkdownEditorView(
                        session: session,
                        rootURL: rootURL,
                        context: .quickCapture,
                        startsAtDocumentEnd: true,
                        focusRequest: state.focusRequest,
                        renderOptions: MarkdownRenderOptions(
                            fontFamily: appearance.fontFamily,
                            fontSize: appearance.fontSize,
                            textColor: appearance.textColor.nsColor,
                            accentColor: appAppearance.preferences.accent.nsColor
                        ),
                        importImageFile: importImageFile,
                        importImageData: importImageData
                    )
                    .id(session.editorDocumentID)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
        .overlay { QuickNoteBorderView(appearance: appearance).id(appearanceController.revision) }
        .onChange(of: showsAppearance) { _, shown in if !shown { appearanceController.cancel() } }
        .preferredColorScheme(appAppearance.preferences.interfaceTheme.colorScheme)
        .tint(appAppearance.preferences.accent.color)
        .ignoresSafeArea(.container, edges: .top)
    }

}

private struct FloatingHeaderIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}

private struct QuickSessionSwitcher: View {
    @Bindable var state: FloatingEditorState
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("快速笔记").font(.headline)
                Spacer()
                Button {
                    Task {
                        await state.createSession()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
                .buttonStyle(RepotraHoverButtonStyle())
                .help("新建快速笔记")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(state.records) { record in
                        Button {
                            Task {
                                await state.switchSession(to: record.id)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: record.id == state.activeSessionID ? "checkmark.circle.fill" : "note.text")
                                    .foregroundStyle(record.id == state.activeSessionID ? Color.accentColor : .secondary)
                                    .frame(width: 16)
                                Text(title(for: record)).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RepotraHoverButtonStyle(isSelected: record.id == state.activeSessionID))
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 240)

            Divider()

            Button(role: .destructive) {
                Task {
                    await state.deleteActive()
                    dismiss()
                }
            } label: {
                Label("删除当前会话", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
            }
            .buttonStyle(RepotraHoverButtonStyle())
        }
        .frame(width: 240)
    }

    private func title(for record: QuickNoteSessionRecord) -> String {
        ((record.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

private struct FloatingTitle: View {
    @Bindable var state: FloatingEditorState
    @Bindable var session: NoteSession
    let canRename: Bool
    @State private var editing = false
    @State private var draft = ""
    @State private var error: String?
    @State private var conflict: NoteRenameConflict?
    @State private var isRenaming = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                VStack(alignment: .leading, spacing: 1) {
                    TextField("笔记名", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .focused($focused)
                        .onSubmit { commit() }.onExitCommand { cancel() }
                    if let error { Text(error).font(.caption2).foregroundStyle(.red) }
                }
            } else {
                Button { if canRename { begin() } } label: {
                    Text(session.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .frame(height: 24)
                }
                .buttonStyle(RepotraHoverButtonStyle())
            }
        }
        .onChange(of: focused) { _, value in
            if !value, editing, conflict == nil, !isRenaming { commit() }
        }
        .onChange(of: conflict) { oldValue, newValue in
            if oldValue != nil, newValue == nil, editing, !isRenaming {
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
        editing = true
        Task { @MainActor in focused = true }
    }
    private func cancel() {
        editing = false
        focused = false
        error = nil
        conflict = nil
        isRenaming = false
    }
    private func commit(resolution: RenameConflictResolution? = nil) {
        guard !isRenaming else { return }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/"), !value.contains(":") else {
            error = "请输入有效名称"; focused = true; return
        }
        guard value != session.title || resolution != nil else { cancel(); return }
        isRenaming = true
        Task {
            let outcome = await state.renameActive(to: value, resolution: resolution)
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

private struct FloatingSaveStatus: View {
    @Bindable var session: NoteSession
    let accessibilityIdentifier: String

    var body: some View {
        ZStack {
            if session.conflict != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if session.lastError != nil {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            } else if session.isSaving || session.isDirty {
                Circle()
                    .fill(.white.opacity(session.isSaving ? 0.9 : 0.55))
                    .frame(width: 5, height: 5)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .frame(width: 16, height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHidden(accessibilityLabel.isEmpty)
    }

    private var accessibilityLabel: String {
        if session.conflict != nil { return "保存冲突" }
        if session.lastError != nil { return "保存失败" }
        if session.isSaving { return "正在保存" }
        if session.isDirty { return "尚未保存" }
        return ""
    }
}

private struct QuickNoteBorderView: View {
    let appearance: QuickNoteAppearance
    var body: some View {
        if appearance.hasBorder {
            RoundedRectangle(cornerRadius: appearance.cornerRadius)
                .stroke(Color(nsColor: PathUtilities.hexColor(appearance.borderColor)), lineWidth: 1)
        }
    }
}
