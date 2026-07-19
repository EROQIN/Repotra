import AppKit
import Observation
import SwiftUI

enum AppInterfaceTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppAccentChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case cyan
    case blue
    case indigo
    case purple
    case orange

    var id: Self { self }
    var title: String {
        switch self {
        case .system: "系统"
        case .cyan: "青蓝"
        case .blue: "蓝色"
        case .indigo: "靛蓝"
        case .purple: "紫色"
        case .orange: "橙色"
        }
    }
    var nsColor: NSColor {
        switch self {
        case .system: .controlAccentColor
        case .cyan: NSColor(srgbRed: 0.10, green: 0.66, blue: 0.74, alpha: 1)
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .orange: .systemOrange
        }
    }
    var color: Color { Color(nsColor: nsColor) }
}

enum AppBackgroundKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case solid
    case gradient
    case image

    var id: Self { self }
    var title: String {
        switch self {
        case .system: "系统"
        case .solid: "纯色"
        case .gradient: "渐变"
        case .image: "图片"
        }
    }
}

enum AppTextColorMode: String, Codable, Sendable {
    case automatic
    case manual
}

struct AppBackgroundConfiguration: Codable, Hashable, Sendable {
    var kind: AppBackgroundKind = .system
    var primaryColor = "#FFFFFFFF"
    var secondaryColor = "#F2F2F7FF"
    var imageFileName: String?
    var imageScaling: StickyImageScaling = .fill
    var imageOverlayOpacity = 0.18
    var imageLuminance: Double?
    var textColorMode: AppTextColorMode = .automatic
    var manualTextColor = "#1F2328FF"

    static let standard = AppBackgroundConfiguration()

    func normalized() -> Self {
        var value = self
        value.primaryColor = Self.canonicalHex(primaryColor) ?? Self.standard.primaryColor
        value.secondaryColor = Self.canonicalHex(secondaryColor) ?? Self.standard.secondaryColor
        value.manualTextColor = Self.canonicalHex(manualTextColor) ?? Self.standard.manualTextColor
        value.imageOverlayOpacity = min(
            0.7,
            max(0, imageOverlayOpacity.isFinite ? imageOverlayOpacity : Self.standard.imageOverlayOpacity)
        )
        if let luminance = imageLuminance {
            value.imageLuminance = luminance.isFinite ? min(1, max(0, luminance)) : nil
        }
        if let fileName = imageFileName,
           fileName.isEmpty || fileName.contains("/") || fileName.contains("\\") || fileName.contains("..")
        {
            value.imageFileName = nil
        }
        if value.kind != .image {
            value.imageFileName = nil
            value.imageLuminance = nil
        }
        if value.kind == .image, value.imageFileName == nil {
            value.kind = .system
            value.imageLuminance = nil
        }
        return value
    }

    var resolvedTextColor: NSColor {
        if textColorMode == .manual { return PathUtilities.hexColor(manualTextColor) }
        if kind == .system { return .labelColor }
        let luminance: Double
        switch kind {
        case .system:
            return .labelColor
        case .solid:
            luminance = Self.relativeLuminance(of: primaryColor)
        case .gradient:
            luminance = (
                Self.relativeLuminance(of: primaryColor)
                    + Self.relativeLuminance(of: secondaryColor)
            ) / 2
        case .image:
            luminance = imageLuminance ?? Self.relativeLuminance(of: primaryColor)
        }
        return luminance > 0.48
            ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
            : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1)
    }

    var imageOverlayColor: NSColor {
        Self.relativeLuminance(of: PathUtilities.hexString(resolvedTextColor, includeAlpha: true)) > 0.5
            ? .black
            : .white
    }

    static func relativeLuminance(of value: String) -> Double {
        guard let rgba = rgbaComponents(value) else { return 1 }
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgba.red) + 0.7152 * linear(rgba.green) + 0.0722 * linear(rgba.blue)
    }

    static func canonicalHex(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, UInt64(text, radix: 16) != nil else { return nil }
        if text.count == 6 { text += "FF" }
        return "#" + text.uppercased()
    }

    private static func rgbaComponents(_ value: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard let canonical = canonicalHex(value), let raw = UInt64(canonical.dropFirst(), radix: 16) else { return nil }
        return (
            Double((raw >> 24) & 0xFF) / 255,
            Double((raw >> 16) & 0xFF) / 255,
            Double((raw >> 8) & 0xFF) / 255,
            Double(raw & 0xFF) / 255
        )
    }
}

enum EditorCanvasStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case paper
    case warm
    case dark
    case custom

    var id: Self { self }
    var title: String {
        switch self {
        case .system: "系统"
        case .paper: "纸白"
        case .warm: "暖黄"
        case .dark: "深灰"
        case .custom: "自定义"
        }
    }

    static var selectableCases: [Self] { [.system, .paper, .warm, .dark] }

    var background: AppBackgroundConfiguration {
        var value = AppBackgroundConfiguration.standard
        switch self {
        case .system, .custom:
            break
        case .paper:
            value.kind = .solid
            value.primaryColor = "#FBFAF7FF"
            value.secondaryColor = value.primaryColor
        case .warm:
            value.kind = .solid
            value.primaryColor = "#FFF6DBFF"
            value.secondaryColor = value.primaryColor
        case .dark:
            value.kind = .solid
            value.primaryColor = "#1B1C1FFF"
            value.secondaryColor = value.primaryColor
        }
        return value
    }

    static func matching(_ background: AppBackgroundConfiguration) -> Self {
        selectableCases.first { $0.background == background.normalized() } ?? .custom
    }

    // Compatibility conveniences for callers and v1 tests.
    var backgroundColor: NSColor {
        self == .system ? .textBackgroundColor : PathUtilities.hexColor(background.primaryColor)
    }
    var textColor: NSColor { background.resolvedTextColor }
}

struct AppAppearancePreferences: Codable, Equatable, Sendable {
    var interfaceTheme: AppInterfaceTheme = .system
    var accent: AppAccentChoice = .system
    var editorFontFamily = "SF Pro"
    var editorFontSize = 16.0
    var editorReadingWidth = 720.0
    var background = AppBackgroundConfiguration.standard

    static let standard = AppAppearancePreferences()

    var editorCanvas: EditorCanvasStyle {
        get { EditorCanvasStyle.matching(background) }
        set { if newValue != .custom { background = newValue.background } }
    }

    func normalized(availableFontFamilies: Set<String>? = nil) -> Self {
        var value = self
        value.editorFontSize = min(
            30,
            max(11, value.editorFontSize.isFinite ? value.editorFontSize : Self.standard.editorFontSize)
        )
        value.editorReadingWidth = min(
            960,
            max(560, value.editorReadingWidth.isFinite ? value.editorReadingWidth : Self.standard.editorReadingWidth)
        )
        value.background = value.background.normalized()
        if value.editorFontFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value.editorFontFamily = Self.standard.editorFontFamily
        }
        if let availableFontFamilies,
           value.editorFontFamily != Self.standard.editorFontFamily,
           !availableFontFamilies.contains(value.editorFontFamily)
        {
            value.editorFontFamily = Self.standard.editorFontFamily
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case interfaceTheme
        case accent
        case editorFontFamily
        case editorFontSize
        case editorReadingWidth
        case background
        case editorCanvas
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        interfaceTheme = (try? values.decode(AppInterfaceTheme.self, forKey: .interfaceTheme)) ?? .system
        accent = (try? values.decode(AppAccentChoice.self, forKey: .accent)) ?? .system
        editorFontFamily = (try? values.decode(String.self, forKey: .editorFontFamily)) ?? "SF Pro"
        editorFontSize = (try? values.decode(Double.self, forKey: .editorFontSize)) ?? 16
        editorReadingWidth = (try? values.decode(Double.self, forKey: .editorReadingWidth)) ?? 720
        if let decoded = try? values.decode(AppBackgroundConfiguration.self, forKey: .background) {
            background = decoded
        } else if let legacy = try? values.decode(EditorCanvasStyle.self, forKey: .editorCanvas) {
            background = legacy.background
        } else {
            background = .standard
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(interfaceTheme, forKey: .interfaceTheme)
        try values.encode(accent, forKey: .accent)
        try values.encode(editorFontFamily, forKey: .editorFontFamily)
        try values.encode(editorFontSize, forKey: .editorFontSize)
        try values.encode(editorReadingWidth, forKey: .editorReadingWidth)
        try values.encode(background, forKey: .background)
    }
}

struct AppAppearanceConfiguration: Codable, Sendable {
    var schemaVersion: Int
    var preferences: AppAppearancePreferences
}

@MainActor
@Observable
final class AppAppearanceController {
    static let shared = AppAppearanceController()

    private(set) var preferences: AppAppearancePreferences
    var warning: String?
    var errorMessage: String?
    var isImportingBackground = false

    @ObservationIgnored private let store: AppAppearanceStore

    init(store: AppAppearanceStore = AppAppearanceStore()) {
        self.store = store
        let result = store.load()
        let availableFonts = Set(NSFontManager.shared.availableFontFamilies)
        let normalized = result.preferences.normalized(availableFontFamilies: availableFonts)
        preferences = normalized
        warning = result.warning
        if result.requiresSave || normalized != result.preferences {
            if result.warning == nil, normalized != result.preferences {
                warning = "部分个性化设置无效，已恢复为安全值。"
            }
            try? store.save(normalized)
        }
    }

    var selectedCanvasPreset: EditorCanvasStyle { .matching(preferences.background) }

    func update(_ change: (inout AppAppearancePreferences) -> Void) {
        var candidate = preferences
        change(&candidate)
        let availableFonts = Set(NSFontManager.shared.availableFontFamilies)
        candidate = candidate.normalized(availableFontFamilies: availableFonts)
        let previousImage = preferences.background.imageFileName
        do {
            try store.save(candidate)
            preferences = candidate
            warning = nil
            errorMessage = nil
            if previousImage != candidate.background.imageFileName, let previousImage {
                store.removeBackground(fileName: previousImage)
            }
        } catch {
            errorMessage = "无法保存个性化设置：\(error.localizedDescription)"
            NSSound.beep()
        }
    }

    func applyCanvasPreset(_ preset: EditorCanvasStyle) {
        guard preset != .custom else { return }
        update { $0.background = preset.background }
    }

    func importBackground(from sourceURL: URL) async {
        guard !isImportingBackground else { return }
        isImportingBackground = true
        defer { isImportingBackground = false }
        var imported: AppBackgroundImportedAsset?
        do {
            let store = store
            imported = try await Task.detached { try store.importBackground(from: sourceURL) }.value
            guard let imported else { return }
            var candidate = preferences
            candidate.background.kind = .image
            candidate.background.imageFileName = imported.fileName
            candidate.background.imageLuminance = imported.luminance
            candidate = candidate.normalized()
            try store.save(candidate)
            let previousImage = preferences.background.imageFileName
            preferences = candidate
            warning = nil
            errorMessage = nil
            if let previousImage, previousImage != imported.fileName {
                store.removeBackground(fileName: previousImage)
            }
        } catch {
            if let imported { store.removeBackground(fileName: imported.fileName) }
            errorMessage = "无法导入主页面背景：\(error.localizedDescription)"
            NSSound.beep()
        }
    }

    func removeBackgroundImage() {
        update {
            $0.background.kind = .system
            $0.background.imageFileName = nil
            $0.background.imageLuminance = nil
        }
    }

    func reset() { update { $0 = .standard } }
}
