import Foundation

actor MetadataStore {
    let rootURL: URL
    private let fileManager: FileManager
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
           decoded.schemaVersion == 1
        {
            config = decoded
        } else {
            config = .fresh()
            try write(config, to: libraryConfigURL)
        }

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
    }

    func removeRecords(under path: String) throws {
        stickyFile.stickies = stickyFile.stickies.filter { key, _ in
            key != path && !key.hasPrefix(path + "/")
        }
        try write(stickyFile, to: stickiesURL)
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
}
