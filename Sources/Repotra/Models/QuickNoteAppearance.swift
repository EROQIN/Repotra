import AppKit
import Foundation
import Observation

enum QuickNoteColor: Codable, Hashable, Sendable {
    case systemText
    case systemBackground
    case hex(String)

    var nsColor: NSColor {
        switch self {
        case .systemText:
            return .labelColor
        case .systemBackground:
            return .textBackgroundColor
        case let .hex(value):
            return PathUtilities.hexColor(value)
        }
    }

    func normalized(fallback: QuickNoteColor) -> QuickNoteColor {
        guard case let .hex(value) = self else { return self }
        guard let canonical = Self.canonicalHex(value) else { return fallback }
        return .hex(canonical)
    }

    private static func canonicalHex(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard (text.count == 6 || text.count == 8), UInt64(text, radix: 16) != nil else {
            return nil
        }
        if text.count == 6 { text += "FF" }
        return "#" + text.uppercased()
    }
}

enum QuickNoteBackgroundKind: String, Codable, CaseIterable, Sendable {
    case system
    case solid
    case gradient
    case image
}

struct QuickNoteBackground: Codable, Hashable, Sendable {
    var kind: QuickNoteBackgroundKind = .system
    var primaryColor: QuickNoteColor = .systemBackground
    var secondaryColor: QuickNoteColor = .systemBackground
    /// A committed file name, or a staging-relative path while settings are open.
    var imageFileName: String?
    var imageScaling: StickyImageScaling = .fill
}

struct QuickNoteAppearance: Codable, Hashable, Sendable {
    var fontFamily = "SF Pro"
    var fontSize = 16.0
    var textColor: QuickNoteColor = .systemText
    var background = QuickNoteBackground()
    var opacity = 0.96
    var cornerRadius = 14.0
    var hasShadow = true
    var hasBorder = false
    var borderColor = "#00000026"

    static let standard = QuickNoteAppearance()

    func normalized(availableFontFamilies: Set<String>? = nil) -> Self {
        var value = self
        value.fontSize = min(30, max(11, value.fontSize.isFinite ? value.fontSize : Self.standard.fontSize))
        value.opacity = min(1, max(0.35, value.opacity.isFinite ? value.opacity : Self.standard.opacity))
        value.cornerRadius = min(
            28,
            max(0, value.cornerRadius.isFinite ? value.cornerRadius : Self.standard.cornerRadius)
        )
        value.textColor = value.textColor.normalized(fallback: .systemText)
        value.background.primaryColor = value.background.primaryColor.normalized(fallback: .systemBackground)
        value.background.secondaryColor = value.background.secondaryColor.normalized(fallback: .systemBackground)
        if case let .hex(border) = QuickNoteColor.hex(value.borderColor).normalized(fallback: .hex(Self.standard.borderColor)) {
            value.borderColor = border
        }

        if let availableFontFamilies,
           value.fontFamily != Self.standard.fontFamily,
           !availableFontFamilies.contains(value.fontFamily)
        {
            value.fontFamily = Self.standard.fontFamily
        }
        return value
    }
}

enum QuickNoteThemePreset: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark
    case warm
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        case .warm: "暖黄"
        case .custom: "自定义"
        }
    }

    static var selectableCases: [Self] { [.system, .light, .dark, .warm] }

    func applying(to current: QuickNoteAppearance) -> QuickNoteAppearance {
        guard self != .custom else { return current }
        var value = Self.template(for: self)
        value.fontSize = current.fontSize
        value.opacity = current.opacity
        return value
    }

    static func matching(_ appearance: QuickNoteAppearance) -> Self {
        for preset in selectableCases {
            var candidate = appearance
            let template = template(for: preset)
            candidate.fontSize = template.fontSize
            candidate.opacity = template.opacity
            if candidate == template { return preset }
        }
        return .custom
    }

    private static func template(for preset: Self) -> QuickNoteAppearance {
        var value = QuickNoteAppearance.standard
        switch preset {
        case .system:
            break
        case .light:
            value.textColor = .hex("#1F2328FF")
            value.background.kind = .solid
            value.background.primaryColor = .hex("#FFFFFFFF")
            value.background.secondaryColor = .hex("#F3F4F6FF")
        case .dark:
            value.textColor = .hex("#F1F3F4FF")
            value.background.kind = .solid
            value.background.primaryColor = .hex("#202124FF")
            value.background.secondaryColor = .hex("#303134FF")
            value.borderColor = "#FFFFFF24"
        case .warm:
            value.textColor = .hex("#3B3325FF")
            value.background.kind = .solid
            value.background.primaryColor = .hex("#FFF3C4FF")
            value.background.secondaryColor = .hex("#FFE39AFF")
            value.borderColor = "#6B542224"
        case .custom:
            break
        }
        return value
    }
}

struct QuickNoteAppearanceConfiguration: Codable, Sendable {
    var schemaVersion: Int
    var appearance: QuickNoteAppearance

    static let current = QuickNoteAppearanceConfiguration(
        schemaVersion: 1,
        appearance: .standard
    )
}

@MainActor
@Observable
final class QuickNoteAppearanceController {
    private(set) var committed: QuickNoteAppearance = .standard
    private(set) var draft: QuickNoteAppearance?
    private(set) var revision = 0
    private(set) var isLoaded = false
    private(set) var isSaving = false
    var warning: String?
    var errorMessage: String?

    @ObservationIgnored private let store: QuickNoteAppearanceStore
    @ObservationIgnored private var stagedBackground: QuickNoteStagedBackground?
    @ObservationIgnored var onPreviewChange: ((QuickNoteAppearance) -> Void)?

    init(store: QuickNoteAppearanceStore = QuickNoteAppearanceStore()) {
        self.store = store
    }

    var preview: QuickNoteAppearance { draft ?? committed }
    var isEditing: Bool { draft != nil }
    var selectedPreset: QuickNoteThemePreset { .matching(preview) }

    func loadIfNeeded(force: Bool = false) async {
        guard !isLoaded || force else { return }
        guard draft == nil else { return }
        await store.cleanStagingDirectory()
        let result = await store.load()
        let availableFonts = Set(NSFontManager.shared.availableFontFamilies)
        committed = result.appearance.normalized(availableFontFamilies: availableFonts)
        warning = result.warning
        isLoaded = true
        revision &+= 1
        onPreviewChange?(committed)
    }

    func beginEditing() {
        guard draft == nil else { return }
        draft = committed
        errorMessage = nil
        revision &+= 1
    }

    func updateDraft(_ change: (inout QuickNoteAppearance) -> Void) {
        if draft == nil { beginEditing() }
        guard var value = draft else { return }
        change(&value)
        draft = value.normalized()
        errorMessage = nil
        revision &+= 1
        onPreviewChange?(preview)
    }

    func applyPreset(_ preset: QuickNoteThemePreset) {
        guard preset != .custom else { return }
        updateDraft { $0 = preset.applying(to: $0) }
    }

    func resetDraft() {
        updateDraft { $0 = .standard }
        discardStagedBackground()
    }

    func stageBackground(from sourceURL: URL) async {
        guard isEditing else { return }
        do {
            let staged = try await store.stageBackground(from: sourceURL)
            guard isEditing else {
                await store.discard(staged)
                return
            }
            if let stagedBackground {
                await store.discard(stagedBackground)
            }
            stagedBackground = staged
            updateDraft { appearance in
                appearance.background.kind = .image
                appearance.background.imageFileName = staged.previewRelativePath
            }
            warning = nil
        } catch {
            errorMessage = "无法导入背景图片：\(error.localizedDescription)"
            NSSound.beep()
        }
    }

    @discardableResult
    func commit() async -> Bool {
        guard let draft else { return true }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let availableFonts = Set(NSFontManager.shared.availableFontFamilies)
        let candidate = draft.normalized(availableFontFamilies: availableFonts)
        let oldImage = committed.background.imageFileName
        do {
            let saved = try await store.commit(candidate, stagedBackground: stagedBackground)
            committed = saved
            self.draft = nil
            stagedBackground = nil
            warning = nil
            revision &+= 1
            onPreviewChange?(committed)
            if let oldImage, oldImage != saved.background.imageFileName {
                await store.removeBackground(fileName: oldImage)
            }
            return true
        } catch {
            errorMessage = "无法保存快速笔记设置：\(error.localizedDescription)"
            return false
        }
    }

    func cancel() {
        guard draft != nil else { return }
        draft = nil
        errorMessage = nil
        revision &+= 1
        onPreviewChange?(committed)
        discardStagedBackground()
    }

    private func discardStagedBackground() {
        guard let stagedBackground else { return }
        self.stagedBackground = nil
        Task { await store.discard(stagedBackground) }
    }
}
