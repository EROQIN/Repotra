import Foundation

actor SearchIndex {
    private struct Entry: Sendable {
        let relativePath: String
        let title: String
        let content: String
        let searchable: String
        let modifiedAt: Date
        let characterCount: Int
    }

    private var entries: [Entry] = []

    func rebuild(rootURL: URL) throws {
        let fileManager = FileManager.default
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            entries = []
            return
        }
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        var next: [Entry] = []
        for case let url as URL in enumerator {
            if url.path.contains("/.repotra/") || url.pathExtension.lowercased() != "md" {
                continue
            }
            let data = try Data(contentsOf: url)
            let content = String(decoding: data, as: UTF8.self)
            let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let relativePath = String(resolvedURL.path.dropFirst(rootPath.count))
            let title = (url.lastPathComponent as NSString).deletingPathExtension
            next.append(Entry(
                relativePath: relativePath,
                title: title,
                content: content,
                searchable: "\(title)\n\(relativePath)\n\(content)".localizedLowercase,
                modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
                characterCount: content.count
            ))
        }
        entries = next
    }

    func metrics() -> [String: NoteMetrics] {
        Dictionary(uniqueKeysWithValues: entries.map { entry in
            (entry.relativePath, NoteMetrics(
                relativePath: entry.relativePath,
                modifiedAt: entry.modifiedAt,
                characterCount: entry.characterCount
            ))
        })
    }

    func query(_ query: String, limit: Int = 100) -> [SearchResult] {
        let terms = query.localizedLowercase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return entries.compactMap { entry -> SearchResult? in
            guard terms.allSatisfy(entry.searchable.contains) else { return nil }
            var score = 0
            let lowerTitle = entry.title.localizedLowercase
            let lowerPath = entry.relativePath.localizedLowercase
            for term in terms {
                if lowerTitle == term {
                    score += 100
                } else if lowerTitle.hasPrefix(term) {
                    score += 50
                } else if lowerTitle.contains(term) {
                    score += 25
                }
                if lowerPath.contains(term) {
                    score += 10
                }
                score += max(1, entry.searchable.components(separatedBy: term).count - 1)
            }
            return SearchResult(
                relativePath: entry.relativePath,
                title: entry.title,
                snippet: Self.snippet(in: entry.content, matching: terms.first ?? ""),
                score: score
            )
        }
        .sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        .prefix(limit)
        .map(\.self)
    }

    private static func snippet(in content: String, matching term: String) -> String {
        let compact = content.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard let range = compact.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(compact.prefix(140))
        }
        let offset = compact.distance(from: compact.startIndex, to: range.lowerBound)
        let startOffset = max(0, offset - 45)
        let start = compact.index(compact.startIndex, offsetBy: startOffset)
        let end = compact.index(start, offsetBy: min(140, compact.distance(from: start, to: compact.endIndex)))
        return (startOffset > 0 ? "…" : "") + compact[start ..< end] + (end < compact.endIndex ? "…" : "")
    }
}
