import AppKit
import SwiftUI

struct SidebarKeyInputView: NSViewRepresentable {
    let focusRequest: Int
    let onFocusChange: (Bool) -> Void
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SidebarResponderView {
        let view = SidebarResponderView()
        view.onFocusChange = onFocusChange
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ view: SidebarResponderView, context: Context) {
        view.onFocusChange = onFocusChange
        view.onKeyDown = onKeyDown
        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    final class Coordinator {
        var lastFocusRequest = -1
    }
}

final class SidebarResponderView: NSView {
    var onFocusChange: ((Bool) -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange?(false) }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
