import AppKit
import Markdown

struct MarkdownRenderOptions: Equatable {
    var fontFamily: String?
    var fontSize: CGFloat
    var textColor: NSColor

    static let standard = MarkdownRenderOptions(fontFamily: nil, fontSize: 16, textColor: .labelColor)
}

@MainActor
struct RenderedSegment {
    let sourceRange: NSRange
    let displayRange: NSRange
    let isActive: Bool
    let rawSource: String
}

@MainActor
struct RenderedDocument {
    let attributedString: NSAttributedString
    let segments: [RenderedSegment]
    let activeSourceRange: NSRange

    var displayLength: Int {
        segments.map { NSMaxRange($0.displayRange) }.max() ?? attributedString.length
    }

    func segment(atDisplayLocation location: Int) -> RenderedSegment? {
        segments.first { NSLocationInRange(min(location, max(0, displayLength - 1)), $0.displayRange) }
    }
}

@MainActor
final class MarkdownRenderEngine {
    private var options = MarkdownRenderOptions.standard
    private var bodyFont: NSFont {
        if let family = options.fontFamily, let font = NSFont(name: family, size: options.fontSize) {
            return font
        }
        return NSFont.systemFont(ofSize: options.fontSize)
    }

    private var sourceFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: max(12, options.fontSize - 1), weight: .regular)
    }

    func render(
        source: String,
        activeLocation: Int,
        rootURL: URL?,
        options: MarkdownRenderOptions = .standard
    ) -> RenderedDocument {
        self.options = options
        // Parsing through swift-markdown keeps GFM validation in the editing path. The
        // block ranges stay source-based so rendering never serializes the AST back.
        _ = Document(parsing: source)
        let sourceText = source as NSString
        let blocks = blockRanges(in: sourceText)
        let activeRange = blocks.first(where: { range in
            NSLocationInRange(min(activeLocation, max(0, sourceText.length - 1)), range)
                || (activeLocation == sourceText.length && NSMaxRange(range) == sourceText.length)
        }) ?? blocks.first ?? NSRange(location: 0, length: sourceText.length)

        let output = NSMutableAttributedString()
        var segments: [RenderedSegment] = []
        for range in blocks {
            let raw = sourceText.substring(with: range)
            let isActive = NSEqualRanges(range, activeRange)
            let rendered = isActive ? renderSource(raw) : renderBlock(raw, rootURL: rootURL)
            let displayRange = NSRange(location: output.length, length: rendered.length)
            output.append(rendered)
            segments.append(RenderedSegment(
                sourceRange: range,
                displayRange: displayRange,
                isActive: isActive,
                rawSource: raw
            ))
        }
        if output.length == 0 {
            output.append(NSAttributedString(string: "", attributes: baseAttributes(font: sourceFont)))
        }
        return RenderedDocument(attributedString: output, segments: segments, activeSourceRange: activeRange)
    }

    func sourceLocation(for displayLocation: Int, segment: RenderedSegment) -> Int {
        guard segment.displayRange.length > 0 else { return segment.sourceRange.location }
        let relative = max(0, min(segment.displayRange.length, displayLocation - segment.displayRange.location))
        let ratio = Double(relative) / Double(segment.displayRange.length)
        return segment.sourceRange.location + Int(Double(segment.sourceRange.length) * ratio)
    }

    private func blockRanges(in source: NSString) -> [NSRange] {
        guard source.length > 0 else { return [NSRange(location: 0, length: 0)] }
        var ranges: [NSRange] = []
        var cursor = 0
        var blockStart = 0
        var inFence = false
        while cursor < source.length {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            let line = source.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
            }
            cursor = NSMaxRange(lineRange)
            if line.isEmpty, !inFence {
                ranges.append(NSRange(location: blockStart, length: cursor - blockStart))
                blockStart = cursor
            }
        }
        if blockStart < source.length {
            ranges.append(NSRange(location: blockStart, length: source.length - blockStart))
        }
        return ranges.isEmpty ? [NSRange(location: 0, length: source.length)] : ranges
    }

    private func renderSource(_ raw: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: raw, attributes: baseAttributes(font: sourceFont))
        applyPattern(#"(?m)^(#{1,6}|>|[-+*]|\d+\.|```|~~~)(?=\s|$)"#, to: result, attributes: [
            .foregroundColor: NSColor.controlAccentColor,
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
        ])
        applyPattern(#"(\*\*|__|\*|_|~~|`|\[|\]|\(|\))"#, to: result, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return result
    }

    private func renderBlock(_ raw: String, rootURL: URL?) -> NSAttributedString {
        let trailingNewlines = String(raw.reversed().prefix { $0 == "\n" }.reversed())
        let core = raw.trimmingCharacters(in: .newlines)
        if core.isEmpty {
            return NSAttributedString(string: raw, attributes: baseAttributes(font: bodyFont))
        }
        if core.hasPrefix("```") || core.hasPrefix("~~~") {
            var lines = core.components(separatedBy: .newlines)
            if !lines.isEmpty {
                lines.removeFirst()
            }
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true
                || lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") == true
            {
                lines.removeLast()
            }
            let result = NSMutableAttributedString(
                string: lines.joined(separator: "\n") + trailingNewlines,
                attributes: baseAttributes(font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
            )
            result.addAttributes([
                .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.7),
                .foregroundColor: NSColor.labelColor,
            ], range: NSRange(location: 0, length: result.length))
            return result
        }
        if isTable(core) {
            return renderTable(core, trailingNewlines: trailingNewlines)
        }

        var cleaned = core
        var attributes = baseAttributes(font: bodyFont)
        if let heading = cleaned.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
            let level = heading.1.count
            cleaned = String(heading.2)
            attributes[.font] = NSFont.systemFont(ofSize: max(options.fontSize + 3, options.fontSize + 15 - CGFloat(level * 3)), weight: level <= 2 ? .bold : .semibold)
        } else if cleaned.range(of: #"^\s*([-*_])(?:\s*\1){2,}\s*$"#, options: .regularExpression) != nil {
            cleaned = "────────────────────────"
            attributes[.foregroundColor] = NSColor.separatorColor
        } else {
            cleaned = cleaned.replacingOccurrences(of: #"(?m)^\s*>\s?"#, with: "│ ", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"(?m)^\s*[-+*]\s+\[ \]\s+"#, with: "☐  ", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"(?m)^\s*[-+*]\s+\[[xX]\]\s+"#, with: "☑  ", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"(?m)^\s*[-+*]\s+"#, with: "•  ", options: .regularExpression)
        }
        let result = NSMutableAttributedString(string: cleaned + trailingNewlines, attributes: attributes)
        renderImages(in: result, rootURL: rootURL)
        renderLinks(in: result)
        renderDelimited(#"\*\*(.+?)\*\*"#, markerLength: 2, attributes: [.font: NSFont.systemFont(ofSize: options.fontSize, weight: .bold)], in: result)
        renderDelimited(#"__(.+?)__"#, markerLength: 2, attributes: [.font: NSFont.systemFont(ofSize: options.fontSize, weight: .bold)], in: result)
        renderDelimited(#"~~(.+?)~~"#, markerLength: 2, attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue], in: result)
        renderDelimited(#"(?<!\*)\*([^*\n]+?)\*(?!\*)"#, markerLength: 1, attributes: [.font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)], in: result)
        renderDelimited(#"`([^`\n]+)`"#, markerLength: 1, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.25),
        ], in: result)
        return result
    }

    private func renderLinks(in text: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) else { return }
        for match in regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            let label = (text.string as NSString).substring(with: match.range(at: 1))
            let destination = (text.string as NSString).substring(with: match.range(at: 2))
            let replacement = NSMutableAttributedString(string: label, attributes: baseAttributes(font: bodyFont))
            replacement.addAttributes([
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: destination,
            ], range: NSRange(location: 0, length: replacement.length))
            text.replaceCharacters(in: match.range, with: replacement)
        }
    }

    private func renderImages(in text: NSMutableAttributedString, rootURL: URL?) {
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) else { return }
        for match in regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            let alt = (text.string as NSString).substring(with: match.range(at: 1))
            let path = (text.string as NSString).substring(with: match.range(at: 2))
            guard let rootURL else { continue }
            let url = path.hasPrefix("file:") ? URL(string: path) : rootURL.appending(path: path.removingPercentEncoding ?? path)
            guard let url, let image = NSImage(contentsOf: url) else { continue }
            let attachment = NSTextAttachment()
            let maxWidth: CGFloat = 620
            let scale = min(1, maxWidth / max(image.size.width, 1))
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            let replacement = NSMutableAttributedString(attachment: attachment)
            if !alt.isEmpty {
                replacement.append(NSAttributedString(string: "\n\(alt)", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            text.replaceCharacters(in: match.range, with: replacement)
        }
    }

    private func renderDelimited(
        _ pattern: String,
        markerLength _: Int,
        attributes: [NSAttributedString.Key: Any],
        in text: NSMutableAttributedString
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let content = (text.string as NSString).substring(with: match.range(at: 1))
            let replacement = NSMutableAttributedString(string: content, attributes: baseAttributes(font: bodyFont))
            replacement.addAttributes(attributes, range: NSRange(location: 0, length: replacement.length))
            text.replaceCharacters(in: match.range, with: replacement)
        }
    }

    private func isTable(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return false }
        return lines[0].contains("|")
            && lines[1].range(of: #"^\s*\|?\s*:?-{3,}"#, options: .regularExpression) != nil
    }

    private func renderTable(_ text: String, trailingNewlines: String) -> NSAttributedString {
        let lines = text.components(separatedBy: .newlines)
        let dataLines = lines.enumerated().filter { $0.offset != 1 }.map(\.element)
        let rows = dataLines.map { line in
            line.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let rendered = rows.map { $0.joined(separator: "\t│\t") }.joined(separator: "\n") + trailingNewlines
        let result = NSMutableAttributedString(
            string: rendered,
            attributes: baseAttributes(font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
        )
        if let firstLine = rendered.range(of: "\n") {
            let length = rendered.distance(from: rendered.startIndex, to: firstLine.lowerBound)
            result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold), range: NSRange(location: 0, length: length))
        }
        result.addAttribute(.backgroundColor, value: NSColor.controlBackgroundColor.withAlphaComponent(0.65), range: NSRange(location: 0, length: result.length))
        return result
    }

    private func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 7
        return [
            .font: font,
            .foregroundColor: options.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    private func applyPattern(
        _ pattern: String,
        to text: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)) {
            text.addAttributes(attributes, range: match.range)
        }
    }
}
