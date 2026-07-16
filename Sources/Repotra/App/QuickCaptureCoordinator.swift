import AppKit
import SwiftUI

@MainActor
final class QuickCaptureCoordinator: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(
        session: NoteSession,
        rootURL: URL,
        importImageFile: @escaping @MainActor (URL) async -> String?,
        importImageData: @escaping @MainActor (Data) async -> String?
    ) {
        if let panel, panel.isVisible {
            // A non-activating panel can become key without making Repotra the
            // active application. This keeps the app underneath untouched.
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }

        appendCaptureHeading(to: session)

        let panel = QuickCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.quickCaptureCoordinator = self
        panel.title = "快速笔记"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 300)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickCaptureView(
            session: session,
            rootURL: rootURL,
            onClose: { [weak self] in self?.hide() },
            importImageFile: importImageFile,
            importImageData: importImageData
        ))
        panel.center()
        self.panel = panel

        // Keep the previously active app in front while allowing the panel to
        // receive keyboard input immediately.
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func closeForLibrarySwitch() {
        panel?.delegate = nil
        panel?.close()
        panel = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func appendCaptureHeading(to session: NoteSession) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let heading = "### \(formatter.string(from: Date()))\n\n"
        let separator = session.content.isEmpty || session.content.hasSuffix("\n\n") ? "" : "\n\n"
        session.updateContent(session.content + separator + heading)
    }
}

private final class QuickCapturePanel: NSPanel {
    weak var quickCaptureCoordinator: QuickCaptureCoordinator?

    override func cancelOperation(_ sender: Any?) {
        quickCaptureCoordinator?.hide()
    }
}

private struct QuickCaptureView: View {
    @Bindable var session: NoteSession
    let rootURL: URL
    let onClose: () -> Void
    let importImageFile: @MainActor (URL) async -> String?
    let importImageData: @MainActor (Data) async -> String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.yellow)
                Text("快速笔记")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(session.isDirty ? "未保存" : "已保存")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("隐藏快速笔记 Esc")
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(.ultraThinMaterial)
            Divider().opacity(0.5)
            MarkdownEditorView(
                session: session,
                rootURL: rootURL,
                context: .quickCapture,
                startsAtDocumentEnd: true,
                importImageFile: importImageFile,
                importImageData: importImageData
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
