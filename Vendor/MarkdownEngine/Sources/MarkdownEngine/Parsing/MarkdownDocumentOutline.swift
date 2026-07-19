import Foundation

/// A source-preserving heading entry suitable for an outline inspector.
public struct MarkdownOutlineItem: Identifiable, Hashable, Sendable {
    public let id: Int
    public let level: Int
    public let title: String
    public let sourceRange: NSRange

    public init(id: Int, level: Int, title: String, sourceRange: NSRange) {
        self.id = id
        self.level = level
        self.title = title
        self.sourceRange = sourceRange
    }
}

public enum MarkdownDocumentOutline {
    /// Extracts ATX headings while retaining their UTF-16 source positions.
    public static func parse(_ source: String) -> [MarkdownOutlineItem] {
        let nsSource = source as NSString
        var result: [MarkdownOutlineItem] = []
        var cursor = 0
        var insideFence = false

        while cursor < nsSource.length {
            let lineRange = nsSource.lineRange(for: NSRange(location: cursor, length: 0))
            var line = nsSource.substring(with: lineRange)
            line = line.trimmingCharacters(in: .newlines)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
            } else if !insideFence {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if (1 ... 6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                    var title = String(trimmed.dropFirst(hashes + 1))
                    title = title.replacingOccurrences(
                        of: #"[ \t]+#+[ \t]*$"#,
                        with: "",
                        options: .regularExpression
                    )
                    if !title.isEmpty {
                        result.append(.init(
                            id: lineRange.location,
                            level: hashes,
                            title: title,
                            sourceRange: NSRange(location: lineRange.location, length: lineRange.length)
                        ))
                    }
                }
            }
            cursor = NSMaxRange(lineRange)
        }
        return result
    }
}
