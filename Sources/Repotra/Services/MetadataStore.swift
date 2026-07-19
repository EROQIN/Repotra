import Foundation

actor MetadataStore {
    let rootURL: URL
    private let fileManager: FileManager
    private var libraryConfig = LibraryConfiguration.fresh()
    private var stickyFile = StickyConfigurationFile.empty

    private var metadataURL: URL {
        rootURL.appending(path: ".repotra")
    }

    private var libraryConfigURL: URL {
        metadataURL.appending(path: "library.json")
    }

    private var stickiesURL: URL {
        metadataURL.appending(path: "stickies.json")
    }

    private var backgroundsURL: URL {
        metadataURL.appending(path: "backgrounds")
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    @discardableResult
    func bootstrap() throws -> LibraryConfiguration {
        try fileManager.createDirectory(at: backgroundsURL, withIntermediateDirectories: true)
        let config: LibraryConfiguration
        if let data = try? Data(contentsOf: libraryConfigURL),
           let decoded = try? JSONDecoder().decode(LibraryConfiguration.self, from: data),
           (1 ... 3).contains(decoded.schemaVersion)
        {
            var migrated = decoded
            migrated.schemaVersion = 3
            config = migrated
            if decoded.schemaVersion != 3 {
                try write(migrated, to: libraryConfigURL)
            }
        } else {
            config = .fresh()
            try write(config, to: libraryConfigURL)
        }
        libraryConfig = config

        if let data = try? Data(contentsOf: stickiesURL),
           let decoded = try? JSONDecoder().decode(StickyConfigurationFile.self, from: data),
           decoded.schemaVersion == 1
        {
            stickyFile = decoded
        } else {
            stickyFile = .empty
            try write(stickyFile, to: stickiesURL)
        }
        return config
    }

    func quickNotePath() -> String? {
        libraryConfig.quickNotePath
    }

    func setQuickNotePath(_ path: String?) throws {
        libraryConfig.quickNotePath = path
        try write(libraryConfig, to: libraryConfigURL)
    }

    func quickNoteState() -> (
        legacyPath: String?,
        directoryPath: String?,
        sessions: [QuickNoteSessionRecord],
        activeSessionID: UUID?
    ) {
        (
            libraryConfig.quickNotePath,
            libraryConfig.quickNotesDirectoryPath,
            libraryConfig.quickNoteSessions.sorted { $0.createdAt < $1.createdAt },
            libraryConfig.activeQuickNoteSessionID
        )
    }

    func saveQuickNoteState(
        directoryPath: String,
        sessions: [QuickNoteSessionRecord],
        activeSessionID: UUID?
    ) throws {
        libraryConfig.quickNotesDirectoryPath = directoryPath
        libraryConfig.quickNoteSessions = sessions.sorted { $0.createdAt < $1.createdAt }
        libraryConfig.activeQuickNoteSessionID = activeSessionID
        libraryConfig.quickNotePath = nil
        libraryConfig.schemaVersion = 3
        try write(libraryConfig, to: libraryConfigURL)
    }

    func navigationState() -> (favorites: [String], recents: [String], display: LibraryDisplayState) {
        (libraryConfig.favoritePaths, libraryConfig.recentPaths, libraryConfig.displayState)
    }

    func saveNavigationState(
        favorites: [String],
        recents: [String],
        display: LibraryDisplayState
    ) throws {
        libraryConfig.favoritePaths = favorites
        libraryConfig.recentPaths = recents
        libraryConfig.displayState = display
        try write(libraryConfig, to: libraryConfigURL)
    }

    func records() -> [String: StickyRecord] {
        stickyFile.stickies
    }

    func record(for notePath: String) -> StickyRecord? {
        stickyFile.stickies[notePath]
    }

    func save(_ record: StickyRecord) throws {
        stickyFile.stickies[record.notePath] = record
        try write(stickyFile, to: stickiesURL)
    }

    func remove(notePath: String) throws {
        stickyFile.stickies.removeValue(forKey: notePath)
        try write(stickyFile, to: stickiesURL)
    }

    func moveRecord(from oldPath: String, to newPath: String) throws {
        var updates: [(String, String, StickyRecord)] = []
        for (path, record) in stickyFile.stickies {
            if path == oldPath || path.hasPrefix(oldPath + "/") {
                let suffix = String(path.dropFirst(oldPath.count))
                let updatedPath = newPath + suffix
                var updatedRecord = record
                updatedRecord.notePath = updatedPath
                updates.append((path, updatedPath, updatedRecord))
            }
        }
        for (oldKey, newKey, record) in updates {
            stickyFile.stickies.removeValue(forKey: oldKey)
            stickyFile.stickies[newKey] = record
        }
        if !updates.isEmpty {
            try write(stickyFile, to: stickiesURL)
        }
        if let quickPath = libraryConfig.quickNotePath,
           quickPath == oldPath || quickPath.hasPrefix(oldPath + "/") {
            libraryConfig.quickNotePath = newPath + String(quickPath.dropFirst(oldPath.count))
        }
        libraryConfig.quickNoteSessions = libraryConfig.quickNoteSessions.map { record in
            guard record.relativePath == oldPath || record.relativePath.hasPrefix(oldPath + "/") else { return record }
            var updated = record
            updated.relativePath = newPath + String(record.relativePath.dropFirst(oldPath.count))
            return updated
        }
        if let directory = libraryConfig.quickNotesDirectoryPath,
           directory == oldPath || directory.hasPrefix(oldPath + "/") {
            libraryConfig.quickNotesDirectoryPath = newPath + String(directory.dropFirst(oldPath.count))
        }
        libraryConfig.favoritePaths = remap(libraryConfig.favoritePaths, from: oldPath, to: newPath)
        libraryConfig.recentPaths = remap(libraryConfig.recentPaths, from: oldPath, to: newPath)
        try write(libraryConfig, to: libraryConfigURL)
    }

    func removeRecords(under path: String) throws {
        stickyFile.stickies = stickyFile.stickies.filter { key, _ in
            key != path && !key.hasPrefix(path + "/")
        }
        try write(stickyFile, to: stickiesURL)
        if libraryConfig.quickNotePath == path || libraryConfig.quickNotePath?.hasPrefix(path + "/") == true {
            libraryConfig.quickNotePath = nil
        }
        let removedIDs = Set(libraryConfig.quickNoteSessions.filter {
            $0.relativePath == path || $0.relativePath.hasPrefix(path + "/")
        }.map(\.id))
        libraryConfig.quickNoteSessions.removeAll {
            $0.relativePath == path || $0.relativePath.hasPrefix(path + "/")
        }
        if let active = libraryConfig.activeQuickNoteSessionID, removedIDs.contains(active) {
            libraryConfig.activeQuickNoteSessionID = libraryConfig.quickNoteSessions.first?.id
        }
        libraryConfig.favoritePaths.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        libraryConfig.recentPaths.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        try write(libraryConfig, to: libraryConfigURL)
    }

    func importBackground(from sourceURL: URL) throws -> String {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let relativePath = ".repotra/backgrounds/\(UUID().uuidString.lowercased()).\(fileExtension)"
        let destination = rootURL.appending(path: relativePath)
        try fileManager.copyItem(at: sourceURL, to: destination)
        return relativePath
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func remap(_ paths: [String], from oldPath: String, to newPath: String) -> [String] {
        paths.map { path in
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { return path }
            return newPath + String(path.dropFirst(oldPath.count))
        }
    }
}
