import Foundation

struct CodableFrame: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let defaultFrame = CodableFrame(x: 180, y: 180, width: 360, height: 420)
}

enum StickyBackgroundKind: String, Codable, CaseIterable, Sendable {
    case solid
    case gradient
    case image
}

enum StickyImageScaling: String, Codable, CaseIterable, Sendable {
    case fill
    case fit
    case stretch
}

struct StickyBackground: Codable, Hashable, Sendable {
    var kind: StickyBackgroundKind = .solid
    var primaryColor = "#FFF3A6"
    var secondaryColor = "#FFD27A"
    var imagePath: String?
    var imageScaling: StickyImageScaling = .fill
}

struct StickyAppearance: Codable, Hashable, Sendable {
    var fontFamily = "SF Pro"
    var fontSize = 15.0
    var textColor = "#27251F"
    var background = StickyBackground()
    var opacity = 0.96
    var cornerRadius = 14.0
    var hasShadow = true
    var hasBorder = false
    var borderColor = "#00000026"
    var hidesTitleBar = false

    static let standard = StickyAppearance()
}

struct StickyRecord: Codable, Hashable, Sendable {
    var notePath: String
    var frame: CodableFrame = .defaultFrame
    var screenIdentifier: String?
    var alwaysOnTop = false
    var appearance: StickyAppearance = .standard
}

struct LibraryConfiguration: Codable, Sendable {
    var schemaVersion: Int
    var libraryID: UUID

    static func fresh() -> LibraryConfiguration {
        LibraryConfiguration(schemaVersion: 1, libraryID: UUID())
    }
}

struct StickyConfigurationFile: Codable, Sendable {
    var schemaVersion: Int
    var stickies: [String: StickyRecord]

    static let empty = StickyConfigurationFile(schemaVersion: 1, stickies: [:])
}
