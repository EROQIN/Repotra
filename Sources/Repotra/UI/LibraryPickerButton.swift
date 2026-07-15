import AppKit
import OSLog
import SwiftUI

struct LibraryPickerButton: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    let title: String
    var isProminent = false

    init(_ title: String, isProminent: Bool = false) {
        self.title = title
        self.isProminent = isProminent
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.chooseLibrary(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier("chooseLibraryButton")
        button.setAccessibilityIdentifier("chooseLibraryButton")
        button.bezelStyle = .rounded
        button.keyEquivalent = isProminent ? "\r" : ""
        applyStyle(to: button)
        if isProminent {
            let coordinator = context.coordinator
            Task { @MainActor in await coordinator.model.start() }

            let savedPath = UserDefaults.standard.string(forKey: "Repotra.LastLibraryPath")
            let hasExistingLibrary = savedPath.map(FileManager.default.fileExists(atPath:)) ?? false
            if !hasExistingLibrary, !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    coordinator.model.presentInitialLibraryPicker()
                }
            }
        }
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.model = model
        button.title = title
        button.keyEquivalent = isProminent ? "\r" : ""
        button.isEnabled = !model.isLibraryPickerPresented
        applyStyle(to: button)
    }

    private func applyStyle(to button: NSButton) {
        button.controlSize = isProminent ? .large : .regular
        button.font = isProminent ? .systemFont(ofSize: 15, weight: .semibold) : .systemFont(ofSize: 13)
        button.bezelColor = isProminent ? .controlAccentColor : nil
        button.contentTintColor = isProminent ? .white : .controlTextColor
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: AppModel
        private let logger = Logger(subsystem: "com.erokin.Repotra", category: "LibraryPicker")

        init(model: AppModel) {
            self.model = model
        }

        @objc func chooseLibrary(_: NSButton) {
            logger.notice("Library picker requested from AppKit button")
            model.presentLibraryPicker()
        }
    }
}
