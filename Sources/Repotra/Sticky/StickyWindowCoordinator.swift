import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class StickyWindowModel {
    let session: NoteSession
    let rootURL: URL
    private(set) var record: StickyRecord

    @ObservationIgnored private let metadataStore: MetadataStore
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundPanel: NSOpenPanel?
    @ObservationIgnored var onPresentationChange: ((StickyRecord) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?

    init(session: NoteSession, rootURL: URL, record: StickyRecord, metadataStore: MetadataStore) {
        self.session = session
        self.rootURL = rootURL
        self.record = record
        self.metadataStore = metadataStore
    }

    deinit { persistTask?.cancel() }

    func setAlwaysOnTop(_ value: Bool) {
        mutate { $0.alwaysOnTop = value }
    }

    func setAppearance(_ appearance: StickyAppearance) {
        mutate { $0.appearance = appearance }
    }

    func updateNotePath(_ path: String) {
        mutate { $0.notePath = path }
    }

    func updateFrame(_ frame: NSRect, screenIdentifier: String?) {
        record.frame = CodableFrame(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.size.width,
            height: frame.size.height
        )
        record.screenIdentifier = screenIdentifier
        schedulePersist()
    }

    func importBackground() {
        if let backgroundPanel {
            backgroundPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        backgroundPanel = panel

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self else { return }
            backgroundPanel = nil
            guard response == .OK, let url = panel?.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let path = try await metadataStore.importBackground(from: url)
                    var appearance = record.appearance
                    appearance.background.kind = .image
                    appearance.background.imagePath = path
                    setAppearance(appearance)
                } catch {
                    NSSound.beep()
                }
            }
        }
        if let hostWindow = NSApp.keyWindow {
            panel.beginSheetModal(for: hostWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func persistNow() async {
        persistTask?.cancel()
        try? await metadataStore.save(record)
    }

    func removePersistedRecord() async {
        persistTask?.cancel()
        try? await metadataStore.remove(notePath: record.notePath)
    }

    private func mutate(_ operation: (inout StickyRecord) -> Void) {
        operation(&record)
        onPresentationChange?(record)
        schedulePersist()
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            try? await metadataStore.save(record)
        }
    }
}

@MainActor
@Observable
final class StickyWindowCoordinator: NSObject, NSWindowDelegate {
    private struct Entry {
        let panel: NSPanel
        let model: StickyWindowModel
    }

    private var entries: [String: Entry] = [:]
    private var isTerminating = false
    private var preservesMetadataWhileClosing = false

    var pinnedPaths: Set<String> {
        Set(entries.keys)
    }

    func pin(
        session: NoteSession,
        rootURL: URL,
        metadataStore: MetadataStore,
        existingRecord: StickyRecord? = nil,
        importImageFile: @escaping @MainActor (URL) async -> String?,
        importImageData: @escaping @MainActor (Data) async -> String?
    ) {
        let path = session.relativePath
        if let entry = entries[path] {
            entry.panel.makeKeyAndOrderFront(nil)
            return
        }
        let record = existingRecord ?? StickyRecord(notePath: path)
        let frame = restoredFrame(for: record)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(path)
        panel.title = session.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 260, height: 220)
        // Treat a sticky like a screenshot pin: it follows the user across
        // Spaces and full-screen apps, stays above normal windows, and does
        // not pollute Cmd-` window cycling.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let model = StickyWindowModel(session: session, rootURL: rootURL, record: record, metadataStore: metadataStore)
        model.onPresentationChange = { [weak panel] record in
            Self.apply(record: record, to: panel)
        }
        model.onClose = { [weak panel] in panel?.performClose(nil) }
        panel.contentView = NSHostingView(rootView: StickyNoteView(
            model: model,
            appAppearance: AppAppearanceController.shared,
            importImageFile: importImageFile,
            importImageData: importImageData
        ))
        entries[path] = Entry(panel: panel, model: model)
        Self.apply(record: record, to: panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        Task { await model.persistNow() }
    }

    func unpin(path: String) {
        entries[path]?.panel.performClose(nil)
    }

    func moveSession(from oldPath: String, to newPath: String) {
        guard let entry = entries.removeValue(forKey: oldPath) else { return }
        entry.panel.identifier = NSUserInterfaceItemIdentifier(newPath)
        entry.model.updateNotePath(newPath)
        entries[newPath] = entry
    }

    func closeWindowsForLibrarySwitch() {
        preservesMetadataWhileClosing = true
        let panels = entries.values.map(\.panel)
        entries.removeAll()
        panels.forEach { $0.close() }
        preservesMetadataWhileClosing = false
    }

    func prepareForTermination() {
        isTerminating = true
        for entry in entries.values {
            updateFrame(for: entry.panel, model: entry.model)
            Task { await entry.model.persistNow() }
        }
    }

    func windowDidMove(_ notification: Notification) {
        updateFromWindowNotification(notification)
    }

    func windowDidResize(_ notification: Notification) {
        updateFromWindowNotification(notification)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateFromWindowNotification(notification)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let path = panel.identifier?.rawValue,
              let entry = entries.removeValue(forKey: path) else { return }
        if isTerminating || preservesMetadataWhileClosing {
            updateFrame(for: panel, model: entry.model)
            Task { await entry.model.persistNow() }
        } else {
            Task { await entry.model.removePersistedRecord() }
        }
    }

    private func updateFromWindowNotification(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let path = panel.identifier?.rawValue,
              let entry = entries[path] else { return }
        updateFrame(for: panel, model: entry.model)
    }

    private func updateFrame(for panel: NSPanel, model: StickyWindowModel) {
        model.updateFrame(panel.frame, screenIdentifier: Self.identifier(for: panel.screen))
    }

    private func restoredFrame(for record: StickyRecord) -> NSRect {
        var frame = NSRect(
            x: record.frame.x,
            y: record.frame.y,
            width: max(260, record.frame.width),
            height: max(220, record.frame.height)
        )
        let desiredScreen = NSScreen.screens.first { Self.identifier(for: $0) == record.screenIdentifier }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = desiredScreen?.visibleFrame else { return frame }
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        return frame
    }

    private static func identifier(for screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return number.stringValue
    }

    private static func apply(record: StickyRecord, to panel: NSPanel?) {
        guard let panel else { return }
        panel.isFloatingPanel = record.alwaysOnTop
        panel.level = record.alwaysOnTop ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.alphaValue = min(1, max(0.35, record.appearance.opacity))
        panel.hasShadow = record.appearance.hasShadow
        panel.isMovableByWindowBackground = record.appearance.hidesTitleBar
        let hideButtons = record.appearance.hidesTitleBar
        panel.standardWindowButton(.closeButton)?.isHidden = hideButtons
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = hideButtons
        panel.standardWindowButton(.zoomButton)?.isHidden = hideButtons
        if record.alwaysOnTop {
            panel.orderFrontRegardless()
        }
    }
}
