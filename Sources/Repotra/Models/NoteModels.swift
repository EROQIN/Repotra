import Foundation

struct NoteNode: Identifiable, Hashable, Sendable {
    let relativePath: String
    let name: String
    let isDirectory: Bool
    var children: [NoteNode]?

    var id: String {
        relativePath
    }

    var title: String {
        isDirectory ? name : (name as NSString).deletingPathExtension
    }
}

struct LibrarySnapshot: Sendable {
    let rootURL: URL
    let roots: [NoteNode]
}

struct NoteSnapshot: Sendable, Equatable {
    let relativePath: String
    let content: String
    let fingerprint: String
    let modifiedAt: Date
}

struct SearchResult: Identifiable, Hashable, Sendable {
    let relativePath: String
    let title: String
    let snippet: String
    let score: Int

    var id: String {
        relativePath
    }
}

struct NoteMetrics: Hashable, Sendable {
    let relativePath: String
    let modifiedAt: Date
    let characterCount: Int
}

enum RenameConflictResolution: Equatable, Sendable {
    case replace
    case keepBoth
}

struct NoteRenameConflict: Identifiable, Equatable, Sendable {
    let sourcePath: String
    let targetPath: String
    let proposedName: String

    var id: String { "\(sourcePath)->\(targetPath)" }
}

enum NoteRenameOutcome: Equatable, Sendable {
    case renamed(String)
    case conflict(NoteRenameConflict)
    case failed(String)

    var succeeded: Bool {
        if case .renamed = self { true } else { false }
    }
}

struct LibraryRenameResult: Sendable {
    let newPath: String
    let replacedPath: String?
    let recoveryURL: URL?
}

enum LibraryRenameOutcome: Sendable {
    case renamed(LibraryRenameResult)
    case conflict(existingPath: String)
}

enum NoteSaveOutcome: Sendable {
    case saved(NoteSnapshot)
    case conflict(NoteSnapshot)
    case missing
}

enum ExternalConflictKind: Sendable, Equatable {
    case modified
    case deleted
}

struct ExternalConflict: Identifiable, Sendable, Equatable {
    let id = UUID()
    let kind: ExternalConflictKind
    let diskSnapshot: NoteSnapshot?
}

enum LibraryError: LocalizedError, Sendable {
    case invalidPath
    case unsupportedFile
    case missingItem(String)
    case itemAlreadyExists(String)
    case reservedPath
    case noLibrary

    var errorDescription: String? {
        switch self {
        case .invalidPath: "路径不在当前资料库中。"
        case .unsupportedFile: "Repotra 仅支持 Markdown 文件。"
        case let .missingItem(path): "找不到项目：\(path)"
        case let .itemAlreadyExists(name): "目标文件夹中已存在“\(name)”。"
        case .reservedPath: ".repotra 是应用保留目录。"
        case .noLibrary: "尚未打开资料库。"
        }
    }
}
