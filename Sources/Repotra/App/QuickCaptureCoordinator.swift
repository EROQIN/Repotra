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
        if let panel {
            if !panel.isVisible {
                appendCaptureHeading(to: session)
            }
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
        panel.standardWindowButton(.closeButton)?.isHidden = false
        panel.standardWindowButton(.closeButton)?.toolTip = "隐藏快速笔记"
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
    let importImageFile: @MainActor (URL) async -> String?
    let importImageData: @MainActor (Data) async -> String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text("快速笔记")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(session.isDirty ? "未保存" : "已保存")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            // The native traffic lights occupy the first ~60pt of the title
            // bar. Keep the title on that same row with a safe leading inset.
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
                importImageFile: importImageFile,
                importImageData: importImageData
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        // The panel uses a transparent full-size title bar. Move this compact
        // header into that title-bar row instead of placing it below the lights.
        .ignoresSafeArea(.container, edges: .top)
    }
}
