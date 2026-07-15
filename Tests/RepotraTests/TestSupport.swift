import Foundation

struct TemporaryLibrary {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "RepotraTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
