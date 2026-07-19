import CryptoKit
import Foundation
import UniformTypeIdentifiers

actor LibraryStore {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    func bootstrap() throws -> LibrarySnapshot {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LibraryError.missingItem(rootURL.path)
        }
        try fileManager.createDirectory(at: rootURL.appending(path: ".repotra"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootURL.appending(path: ".repotra/backgrounds"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootURL.appending(path: "assets"), withIntermediateDirectories: true)
        return try snapshot()
    }

    func snapshot(excludingRootPaths excludedRootPaths: Set<String> = []) throws -> LibrarySnapshot {
        try LibrarySnapshot(
            rootURL: rootURL,
            roots: scanDirectory(rootURL, relativePath: "").filter { !excludedRootPaths.contains($0.relativePath) }
        )
    }

    func noteExists(at relativePath: String) -> Bool {
        guard let url = try? validatedURL(for: relativePath) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func directoryExists(at relativePath: String) -> Bool {
        guard let url = try? validatedURL(for: relativePath) else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func readNote(at relativePath: String) throws -> NoteSnapshot {
        let url = try validatedMarkdownURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw LibraryError.missingItem(relativePath)
        }
        let data = try Data(contentsOf: url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return NoteSnapshot(
            relativePath: relativePath,
            content: String(decoding: data, as: UTF8.self),
            fingerprint: PathUtilities.fingerprint(data: data),
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast
        )
    }

    func saveNote(
        at relativePath: String,
        content: String,
        expectedFingerprint: String?,
        overwrite: Bool = false
    ) throws -> NoteSaveOutcome {
        let url = try validatedMarkdownURL(for: relativePath)
        if fileManager.fileExists(atPath: url.path) {
            let diskSnapshot = try readNote(at: relativePath)
            if !overwrite, let expectedFingerprint, diskSnapshot.fingerprint != expectedFingerprint {
                return .conflict(diskSnapshot)
            }
        } else if expectedFingerprint != nil, !overwrite {
            return .missing
        }

        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(content.utf8)
        try data.write(to: url, options: [.atomic])
        return try .saved(readNote(at: relativePath))
    }

    func createNote(in directory: String?, title: String = "Untitled") throws -> String {
        let parentURL = try validatedDirectoryURL(for: directory ?? "")
        let base = PathUtilities.sanitizedFilename(title)
        var candidate = parentURL.appendingPathComponent(base).appendingPathExtension("md")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parentURL.appendingPathComponent("\(base) \(counter)").appendingPathExtension("md")
            counter += 1
        }
        try Data().write(to: candidate, options: [.atomic])
        return makeRelativePath(for: candidate)
    }

    func createFolder(in directory: String?, title: String = "New Folder") throws -> String {
        let parentURL = try validatedDirectoryURL(for: directory ?? "")
        let base = PathUtilities.sanitizedFilename(title, fallback: "New Folder")
        var candidate = parentURL.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parentURL.appendingPathComponent("\(base) \(counter)", isDirectory: true)
            counter += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        return makeRelativePath(for: candidate)
    }

    func renameItem(at relativePath: String, to newName: String) throws -> String {
        switch try renameNoteItem(at: relativePath, to: newName, resolution: nil) {
        case let .renamed(result):
            return result.newPath
        case let .conflict(existingPath):
            throw LibraryError.itemAlreadyExists((existingPath as NSString).lastPathComponent)
        }
    }

    func renameNoteItem(
        at relativePath: String,
        to newName: String,
        resolution: RenameConflictResolution?
    ) throws -> LibraryRenameOutcome {
        let source = try validatedURL(for: relativePath)
        guard fileManager.fileExists(atPath: source.path) else { throw LibraryError.missingItem(relativePath) }
        let targetName = PathUtilities.renameTargetName(
            currentName: source.lastPathComponent,
            proposedName: newName
        )
        guard targetName != source.lastPathComponent else {
            return .renamed(LibraryRenameResult(newPath: relativePath, replacedPath: nil, recoveryURL: nil))
        }
        let requestedDestination = source.deletingLastPathComponent().appendingPathComponent(targetName)
        var destination = requestedDestination
        var replacedPath: String?
        var recoveryURL: URL?

        if fileManager.fileExists(atPath: requestedDestination.path) {
            switch resolution {
            case nil:
                return .conflict(existingPath: makeRelativePath(for: requestedDestination))
            case .keepBoth:
                destination = availableRenameURL(for: requestedDestination)
            case .replace:
                replacedPath = makeRelativePath(for: requestedDestination)
                var resultingURL: NSURL?
                try fileManager.trashItem(at: requestedDestination, resultingItemURL: &resultingURL)
                recoveryURL = resultingURL as URL?
            }
        }

        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            if let recoveryURL, replacedPath != nil,
               !fileManager.fileExists(atPath: requestedDestination.path) {
                try? fileManager.moveItem(at: recoveryURL, to: requestedDestination)
            }
            throw error
        }
        return .renamed(LibraryRenameResult(
            newPath: makeRelativePath(for: destination),
            replacedPath: replacedPath,
            recoveryURL: recoveryURL
        ))
    }

    func moveItem(at relativePath: String, into directory: String) throws -> String {
        let source = try validatedURL(for: relativePath)
        guard fileManager.fileExists(atPath: source.path) else {
            throw LibraryError.missingItem(relativePath)
        }
        let destinationDirectory = try validatedDirectoryURL(for: directory)
        if source.deletingLastPathComponent().standardizedFileURL == destinationDirectory.standardizedFileURL {
            return relativePath
        }
        let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw LibraryError.itemAlreadyExists(source.lastPathComponent)
        }
        try fileManager.moveItem(at: source, to: destination)
        return makeRelativePath(for: destination)
    }

    func trashItem(at relativePath: String) throws {
        let url = try validatedURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path) else { throw LibraryError.missingItem(relativePath) }
        _ = try fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    func importImage(from sourceURL: URL) throws -> String {
        let data = try Data(contentsOf: sourceURL)
        let rawExtension = sourceURL.pathExtension.lowercased()
        let fileExtension = rawExtension.isEmpty ? "png" : rawExtension
        return try importImage(data: data, fileExtension: fileExtension)
    }

    func importImage(data: Data, fileExtension: String = "png") throws -> String {
        let cleanExtension = PathUtilities.sanitizedFilename(fileExtension, fallback: "png").lowercased()
        let filename = "\(UUID().uuidString.lowercased()).\(cleanExtension)"
        let url = rootURL.appending(path: "assets/\(filename)")
        try data.write(to: url, options: [.atomic])
        return "assets/\(filename)"
    }

    private func scanDirectory(_ directoryURL: URL, relativePath: String) throws -> [NoteNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        )
        var nodes: [NoteNode] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if name == ".repotra" || name == "assets" || values.isHidden == true || name.hasPrefix(".") {
                continue
            }
            let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            if values.isDirectory == true {
                let children = try scanDirectory(url, relativePath: childPath)
                nodes.append(NoteNode(relativePath: childPath, name: name, isDirectory: true, children: children))
            } else if values.isRegularFile == true, url.pathExtension.lowercased() == "md" {
                nodes.append(NoteNode(relativePath: childPath, name: name, isDirectory: false, children: nil))
            }
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func availableRenameURL(for requestedURL: URL) -> URL {
        let fileExtension = requestedURL.pathExtension
        let base = requestedURL.deletingPathExtension().lastPathComponent
        var counter = 2
        var candidate: URL
        repeat {
            let name = "\(base) \(counter)"
            candidate = requestedURL.deletingLastPathComponent().appendingPathComponent(name)
            if !fileExtension.isEmpty { candidate.appendPathExtension(fileExtension) }
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }

    private func validatedMarkdownURL(for relativePath: String) throws -> URL {
        let url = try validatedURL(for: relativePath)
        guard url.pathExtension.lowercased() == "md" else { throw LibraryError.unsupportedFile }
        return url
    }

    private func validatedDirectoryURL(for relativePath: String) throws -> URL {
        let url = try validatedURL(for: relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LibraryError.missingItem(relativePath)
        }
        return url
    }

    private func validatedURL(for relativePath: String) throws -> URL {
        if relativePath == ".repotra" || relativePath.hasPrefix(".repotra/") {
            throw LibraryError.reservedPath
        }
        let url = rootURL.appending(path: relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url == rootURL || url.path.hasPrefix(rootPath) else { throw LibraryError.invalidPath }
        return url
    }

    private func makeRelativePath(for url: URL) -> String {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(rootPath.count))
    }
}
