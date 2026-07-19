import AppKit
import CryptoKit
import Foundation

enum PathUtilities {
    static func fingerprint(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sanitizedFilename(_ value: String, fallback: String = "Untitled") -> String {
        let invalid = CharacterSet(charactersIn: "/:\0").union(.newlines)
        let pieces = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        let joined = pieces.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? fallback : joined
    }

    static func renameTargetName(currentName: String, proposedName: String) -> String {
        let sanitized = sanitizedFilename(proposedName)
        guard (currentName as NSString).pathExtension.lowercased() == "md" else {
            return sanitized
        }
        return (sanitized as NSString).deletingPathExtension + ".md"
    }

    static func hexColor(_ value: String, fallback: NSColor = .labelColor) -> NSColor {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6 || text.count == 8, let number = UInt64(text, radix: 16) else {
            return fallback
        }
        if text.count == 6 {
            return NSColor(
                red: CGFloat((number >> 16) & 0xFF) / 255,
                green: CGFloat((number >> 8) & 0xFF) / 255,
                blue: CGFloat(number & 0xFF) / 255,
                alpha: 1
            )
        }
        return NSColor(
            red: CGFloat((number >> 24) & 0xFF) / 255,
            green: CGFloat((number >> 16) & 0xFF) / 255,
            blue: CGFloat((number >> 8) & 0xFF) / 255,
            alpha: CGFloat(number & 0xFF) / 255
        )
    }

    static func hexString(_ color: NSColor, includeAlpha: Bool = false) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        if includeAlpha {
            let a = Int(round(rgb.alphaComponent * 255))
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
