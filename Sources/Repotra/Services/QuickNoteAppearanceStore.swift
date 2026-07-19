import Foundation

struct QuickNoteAppearanceLoadResult: Sendable {
    var appearance: QuickNoteAppearance
    var warning: String?
}

struct QuickNoteStagedBackground: Equatable, Sendable {
    let fileName: String
    let previewRelativePath: String
}

actor QuickNoteAppearanceStore {
    static let defaultsKey = "Repotra.QuickNoteAppearance.v1"
    private static let stagingDirectoryName = "Staging"

    nonisolated static func defaultBackgroundsURL(fileManager: FileManager = .default) -> URL {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return supportURL
            .appending(path: "Repotra", directoryHint: .isDirectory)
            .appending(path: "QuickNoteBackgrounds", directoryHint: .isDirectory)
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let backgroundsURL: URL
    private let failWrites: Bool

    private var stagingURL: URL {
        backgroundsURL.appending(path: Self.stagingDirectoryName, directoryHint: .isDirectory)
    }

    init(
        defaultsSuiteName: String? = nil,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil,
        failWrites: Bool = false
    ) {
        defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.fileManager = fileManager
        backgroundsURL = applicationSupportURL ?? Self.defaultBackgroundsURL(fileManager: fileManager)
        self.failWrites = failWrites
    }

    func load() -> QuickNoteAppearanceLoadResult {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return QuickNoteAppearanceLoadResult(appearance: .standard, warning: nil)
        }
        guard let configuration = try? JSONDecoder().decode(
            QuickNoteAppearanceConfiguration.self,
            from: data
        ), configuration.schemaVersion == 1 else {
            return QuickNoteAppearanceLoadResult(
                appearance: .standard,
                warning: "快速笔记外观配置无法读取，已恢复默认设置。"
            )
        }

        var appearance = configuration.appearance.normalized()
        guard appearance.background.kind == .image,
              let imageFileName = appearance.background.imageFileName
        else {
            return QuickNoteAppearanceLoadResult(appearance: appearance, warning: nil)
        }
        guard fileExists(for: imageFileName) else {
            appearance.background.kind = .system
            appearance.background.imageFileName = nil
            return QuickNoteAppearanceLoadResult(
                appearance: appearance,
                warning: "快速笔记背景图片不存在，已恢复为系统背景。"
            )
        }
        return QuickNoteAppearanceLoadResult(appearance: appearance, warning: nil)
    }

    func save(_ appearance: QuickNoteAppearance) throws {
        let normalized = appearance.normalized()
        let data = try encoded(normalized)
        try persist(data)
    }

    func stageBackground(from sourceURL: URL) throws -> QuickNoteStagedBackground {
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString.lowercased()).\(fileExtension)"
        let destination = stagingURL.appending(path: fileName)
        try fileManager.copyItem(at: sourceURL, to: destination)
        return QuickNoteStagedBackground(
            fileName: fileName,
            previewRelativePath: "\(Self.stagingDirectoryName)/\(fileName)"
        )
    }

    func commit(
        _ appearance: QuickNoteAppearance,
        stagedBackground: QuickNoteStagedBackground?
    ) throws -> QuickNoteAppearance {
        var candidate = appearance.normalized()
        if candidate.background.kind == .image,
           candidate.background.imageFileName == nil
        {
            candidate.background.kind = .system
        }
        guard let stagedBackground,
              candidate.background.kind == .image,
              candidate.background.imageFileName == stagedBackground.previewRelativePath
        else {
            if let stagedBackground,
               candidate.background.imageFileName == stagedBackground.previewRelativePath
            {
                candidate.background.imageFileName = nil
            }
            if candidate.background.kind == .image,
               let imageFileName = candidate.background.imageFileName,
               !fileExists(for: imageFileName)
            {
                candidate.background.kind = .system
                candidate.background.imageFileName = nil
            }
            try save(candidate)
            if let stagedBackground { discard(stagedBackground) }
            return candidate
        }

        candidate.background.imageFileName = stagedBackground.fileName
        let data = try encoded(candidate)
        try fileManager.createDirectory(at: backgroundsURL, withIntermediateDirectories: true)
        let source = stagingURL.appending(path: stagedBackground.fileName)
        let destination = backgroundsURL.appending(path: stagedBackground.fileName)
        try fileManager.moveItem(at: source, to: destination)
        do {
            try persist(data)
        } catch {
            try? fileManager.moveItem(at: destination, to: source)
            throw error
        }
        try? removeEmptyStagingDirectory()
        return candidate
    }

    func discard(_ stagedBackground: QuickNoteStagedBackground) {
        let url = stagingURL.appending(path: stagedBackground.fileName)
        try? fileManager.removeItem(at: url)
        try? removeEmptyStagingDirectory()
    }

    func cleanStagingDirectory() {
        try? fileManager.removeItem(at: stagingURL)
    }

    func backgroundsDirectory() -> URL { backgroundsURL }

    func removeBackground(fileName: String) {
        guard let url = validatedCommittedURL(for: fileName) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func encoded(_ appearance: QuickNoteAppearance) throws -> Data {
        let configuration = QuickNoteAppearanceConfiguration(schemaVersion: 1, appearance: appearance)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(configuration)
    }

    private func persist(_ data: Data) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func fileExists(for fileName: String) -> Bool {
        guard let url = validatedCommittedURL(for: fileName) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    private func validatedCommittedURL(for fileName: String) -> URL? {
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.contains("..")
        else { return nil }
        return backgroundsURL.appending(path: fileName).standardizedFileURL
    }

    private func removeEmptyStagingDirectory() throws {
        let contents = try fileManager.contentsOfDirectory(atPath: stagingURL.path)
        if contents.isEmpty { try fileManager.removeItem(at: stagingURL) }
    }
}
