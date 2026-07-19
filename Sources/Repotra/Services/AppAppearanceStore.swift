import CoreGraphics
import Foundation
import ImageIO

struct AppAppearanceLoadResult: Sendable {
    var preferences: AppAppearancePreferences
    var warning: String?
    var requiresSave: Bool
}

struct AppBackgroundImportedAsset: Sendable {
    let fileName: String
    let luminance: Double
}

final class AppAppearanceStore: @unchecked Sendable {
    static let defaultsKey = "Repotra.AppAppearance.v1"

    nonisolated static func defaultBackgroundsURL(fileManager: FileManager = .default) -> URL {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return supportURL
            .appending(path: "Repotra", directoryHint: .isDirectory)
            .appending(path: "MainBackgrounds", directoryHint: .isDirectory)
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let backgroundsURL: URL
    private let failWrites: Bool
    private let failCopies: Bool

    init(
        defaultsSuiteName: String? = nil,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil,
        failWrites: Bool = false,
        failCopies: Bool = false
    ) {
        defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.fileManager = fileManager
        backgroundsURL = applicationSupportURL ?? Self.defaultBackgroundsURL(fileManager: fileManager)
        self.failWrites = failWrites
        self.failCopies = failCopies
    }

    func load() -> AppAppearanceLoadResult {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return AppAppearanceLoadResult(preferences: .standard, warning: nil, requiresSave: false)
        }
        guard let configuration = try? JSONDecoder().decode(AppAppearanceConfiguration.self, from: data),
              configuration.schemaVersion == 1 || configuration.schemaVersion == 2
        else {
            return AppAppearanceLoadResult(
                preferences: .standard,
                warning: "个性化配置无法读取，已恢复默认设置。",
                requiresSave: true
            )
        }

        let decodedPreferences = configuration.preferences
        var preferences = decodedPreferences.normalized()
        var warning: String? = preferences == decodedPreferences
            ? nil
            : "部分个性化设置无效，已恢复为安全值。"
        if preferences.background.kind == .image,
           let fileName = preferences.background.imageFileName,
           !fileExists(for: fileName)
        {
            preferences.background = .standard
            warning = "主页面背景图片不存在，已恢复系统背景。"
        }
        return AppAppearanceLoadResult(
            preferences: preferences,
            warning: warning,
            requiresSave: configuration.schemaVersion == 1 || preferences != decodedPreferences || warning != nil
        )
    }

    func save(_ preferences: AppAppearancePreferences) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        let configuration = AppAppearanceConfiguration(
            schemaVersion: 2,
            preferences: preferences.normalized()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(configuration), forKey: Self.defaultsKey)
    }

    func importBackground(from sourceURL: URL) throws -> AppBackgroundImportedAsset {
        if failCopies { throw CocoaError(.fileWriteUnknown) }
        try fileManager.createDirectory(at: backgroundsURL, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString.lowercased()).\(fileExtension)"
        let destination = backgroundsURL.appending(path: fileName)
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            return AppBackgroundImportedAsset(
                fileName: fileName,
                luminance: Self.averageLuminance(of: destination)
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func removeBackground(fileName: String) {
        guard let url = validatedURL(for: fileName) else { return }
        try? fileManager.removeItem(at: url)
    }

    func backgroundsDirectory() -> URL { backgroundsURL }

    private func fileExists(for fileName: String) -> Bool {
        validatedURL(for: fileName).map { fileManager.fileExists(atPath: $0.path) } ?? false
    }

    private func validatedURL(for fileName: String) -> URL? {
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.contains("..")
        else { return nil }
        return backgroundsURL.appending(path: fileName).standardizedFileURL
    }

    private static func averageLuminance(of url: URL) -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return 0.5 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered else { return 0.5 }
        let alpha = max(Double(pixel[3]) / 255, 0.001)
        let red = min(1, Double(pixel[0]) / 255 / alpha)
        let green = min(1, Double(pixel[1]) / 255 / alpha)
        let blue = min(1, Double(pixel[2]) / 255 / alpha)
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
