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
    /// A newly pasted sticky behaves like a screenshot pin and stays above
    /// normal windows. Existing metadata keeps its explicit preference.
    var alwaysOnTop = true
    var appearance: StickyAppearance = .standard
}

struct LibraryDisplayState: Codable, Hashable, Sendable {
    var showsSidebar = true
    var showsInspector = true
    var selectedSection = "library"
}

struct QuickNoteSessionRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var relativePath: String
    var createdAt: Date

    init(id: UUID = UUID(), relativePath: String, createdAt: Date = .now) {
        self.id = id
        self.relativePath = relativePath
        self.createdAt = createdAt
    }
}

struct LibraryConfiguration: Codable, Sendable {
    var schemaVersion: Int
    var libraryID: UUID
    var quickNotePath: String?
    var favoritePaths: [String]
    var recentPaths: [String]
    var displayState: LibraryDisplayState
    var quickNotesDirectoryPath: String?
    var quickNoteSessions: [QuickNoteSessionRecord]
    var activeQuickNoteSessionID: UUID?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, libraryID, quickNotePath, favoritePaths, recentPaths, displayState
        case quickNotesDirectoryPath, quickNoteSessions, activeQuickNoteSessionID
    }

    init(
        schemaVersion: Int,
        libraryID: UUID,
        quickNotePath: String?,
        favoritePaths: [String] = [],
        recentPaths: [String] = [],
        displayState: LibraryDisplayState = .init(),
        quickNotesDirectoryPath: String? = nil,
        quickNoteSessions: [QuickNoteSessionRecord] = [],
        activeQuickNoteSessionID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.libraryID = libraryID
        self.quickNotePath = quickNotePath
        self.favoritePaths = favoritePaths
        self.recentPaths = recentPaths
        self.displayState = displayState
        self.quickNotesDirectoryPath = quickNotesDirectoryPath
        self.quickNoteSessions = quickNoteSessions
        self.activeQuickNoteSessionID = activeQuickNoteSessionID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? values.decode(Int.self, forKey: .schemaVersion)) ?? 1
        libraryID = (try? values.decode(UUID.self, forKey: .libraryID)) ?? UUID()
        quickNotePath = try? values.decodeIfPresent(String.self, forKey: .quickNotePath)
        favoritePaths = (try? values.decode([String].self, forKey: .favoritePaths)) ?? []
        recentPaths = (try? values.decode([String].self, forKey: .recentPaths)) ?? []
        displayState = (try? values.decode(LibraryDisplayState.self, forKey: .displayState)) ?? .init()
        quickNotesDirectoryPath = try? values.decodeIfPresent(String.self, forKey: .quickNotesDirectoryPath)
        quickNoteSessions = (try? values.decode([QuickNoteSessionRecord].self, forKey: .quickNoteSessions)) ?? []
        activeQuickNoteSessionID = try? values.decodeIfPresent(UUID.self, forKey: .activeQuickNoteSessionID)
    }

    static func fresh() -> LibraryConfiguration {
        LibraryConfiguration(schemaVersion: 3, libraryID: UUID(), quickNotePath: nil)
    }
}

struct StickyConfigurationFile: Codable, Sendable {
    var schemaVersion: Int
    var stickies: [String: StickyRecord]

    static let empty = StickyConfigurationFile(schemaVersion: 1, stickies: [:])
}
