import AppKit
import Carbon
import Observation
import SwiftUI

struct HotKeyShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultQuickNote = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_N),
        modifiers: UInt32(cmdKey | optionKey)
    )

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    private static func keyName(for code: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z", UInt32(kVK_Space): "Space",
        ]
        return names[code] ?? "Key \(code)"
    }
}

@MainActor
@Observable
final class GlobalHotKeyController {
    static let shared = GlobalHotKeyController()

    var shortcut: HotKeyShortcut {
        didSet { persistAndRegister() }
    }
    var isEnabled: Bool {
        didSet { persistAndRegister() }
    }
    private(set) var registrationError: String?
    var onTrigger: (() -> Void)?

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var eventHandlerRef: EventHandlerRef?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "Repotra.QuickNoteShortcut"),
           let decoded = try? JSONDecoder().decode(HotKeyShortcut.self, from: data) {
            shortcut = decoded
        } else {
            shortcut = .defaultQuickNote
        }
        isEnabled = UserDefaults.standard.object(forKey: "Repotra.QuickNoteShortcutEnabled") as? Bool ?? true
        installHandler()
        register()
    }

    func restoreDefault() {
        shortcut = .defaultQuickNote
        isEnabled = true
    }

    private func persistAndRegister() {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "Repotra.QuickNoteShortcut")
        }
        UserDefaults.standard.set(isEnabled, forKey: "Repotra.QuickNoteShortcutEnabled")
        register()
    }

    private func installHandler() {
        guard eventHandlerRef == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in controller.onTrigger?() }
                return noErr
            },
            1,
            &type,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    private func register() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registrationError = nil
        guard isEnabled else { return }
        let signature = OSType(0x5250_5452) // RPTR
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr {
            hotKeyRef = reference
        } else {
            registrationError = "快捷键 \(shortcut.displayName) 已被其他应用占用。"
        }
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: HotKeyShortcut

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.shortcut = shortcut
        view.onChange = { shortcut = $0 }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.shortcut = shortcut
        nsView.needsDisplay = true
    }
}

final class ShortcutRecorderNSView: NSView {
    var shortcut = HotKeyShortcut.defaultQuickNote
    var onChange: ((HotKeyShortcut) -> Void)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 28) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        guard modifiers != 0 else { NSSound.beep(); return }
        shortcut = HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        isRecording = false
        onChange?(shortcut)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let text = isRecording ? "请按快捷键…" : shortcut.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
