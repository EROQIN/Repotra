import AppKit
import Foundation
import ImageIO
@testable import Repotra
import Testing
import UniformTypeIdentifiers

@Suite("Application personalization", .serialized)
struct AppAppearanceTests {
    @Test("hover feedback keeps selected and disabled priorities deterministic")
    func hoverFeedbackStates() {
        #expect(RepotraHoverFeedbackResolver.fill(
            isEnabled: true, isSelected: false, isPressed: false, isHovering: true
        ) == .primary(0.05))
        #expect(RepotraHoverFeedbackResolver.fill(
            isEnabled: true, isSelected: false, isPressed: true, isHovering: true
        ) == .primary(0.09))
        #expect(RepotraHoverFeedbackResolver.fill(
            isEnabled: true, isSelected: true, isPressed: false, isHovering: true
        ) == .accent(0.14))
        #expect(RepotraHoverFeedbackResolver.fill(
            isEnabled: false, isSelected: true, isPressed: true, isHovering: true
        ) == .clear)
    }

    @Test("schema v2 preferences round trip through the global store")
    func roundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var preferences = AppAppearancePreferences.standard
        preferences.interfaceTheme = .dark
        preferences.accent = .purple
        preferences.editorFontFamily = "Menlo"
        preferences.editorFontSize = 19
        preferences.editorReadingWidth = 840
        preferences.background.kind = .gradient
        preferences.background.primaryColor = "#123456FF"
        preferences.background.secondaryColor = "#ABCDEF80"
        preferences.background.textColorMode = .manual
        preferences.background.manualTextColor = "#FFEEDDFF"

        try fixture.store.save(preferences)

        let loaded = fixture.makeStore().load()
        #expect(loaded.preferences == preferences)
        let data = try #require(fixture.defaults.data(forKey: AppAppearanceStore.defaultsKey))
        #expect(try JSONDecoder().decode(AppAppearanceConfiguration.self, from: data).schemaVersion == 2)
    }

    @Test("schema v1 canvas migrates without losing neighboring preferences")
    func legacyMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(Data(
            """
            {"schemaVersion":1,"preferences":{"interfaceTheme":"dark","accent":"indigo","editorFontFamily":"Menlo","editorFontSize":18,"editorReadingWidth":840,"editorCanvas":"warm"}}
            """.utf8
        ), forKey: AppAppearanceStore.defaultsKey)

        let loaded = fixture.store.load()

        #expect(loaded.requiresSave)
        #expect(loaded.preferences.interfaceTheme == .dark)
        #expect(loaded.preferences.accent == .indigo)
        #expect(loaded.preferences.editorFontFamily == "Menlo")
        #expect(loaded.preferences.editorCanvas == .warm)
        #expect(loaded.preferences.background.kind == .solid)
    }

    @Test("normalization repairs background values independently")
    func normalization() {
        var preferences = AppAppearancePreferences.standard
        preferences.editorFontFamily = "Missing Typeface"
        preferences.editorFontSize = .infinity
        preferences.editorReadingWidth = 2_000
        preferences.accent = .cyan
        preferences.background.kind = .gradient
        preferences.background.primaryColor = "invalid"
        preferences.background.secondaryColor = "#abcdef"
        preferences.background.manualTextColor = "#01020304"
        preferences.background.imageOverlayOpacity = 9

        let normalized = preferences.normalized(availableFontFamilies: ["Menlo"])

        #expect(normalized.editorFontFamily == "SF Pro")
        #expect(normalized.editorFontSize == 16)
        #expect(normalized.editorReadingWidth == 960)
        #expect(normalized.accent == .cyan)
        #expect(normalized.background.primaryColor == "#FFFFFFFF")
        #expect(normalized.background.secondaryColor == "#ABCDEFFF")
        #expect(normalized.background.manualTextColor == "#01020304")
        #expect(normalized.background.imageOverlayOpacity == 0.7)
    }

    @Test("automatic and manual editor colors follow the configured background")
    func resolvedTextColor() {
        var background = AppBackgroundConfiguration.standard
        background.kind = .solid
        background.primaryColor = "#FFFFFFFF"
        #expect(AppBackgroundConfiguration.relativeLuminance(
            of: PathUtilities.hexString(background.resolvedTextColor, includeAlpha: true)
        ) < 0.1)

        background.kind = .gradient
        background.primaryColor = "#000000FF"
        background.secondaryColor = "#101010FF"
        #expect(AppBackgroundConfiguration.relativeLuminance(
            of: PathUtilities.hexString(background.resolvedTextColor, includeAlpha: true)
        ) > 0.7)

        background.textColorMode = .manual
        background.manualTextColor = "#CC3300FF"
        #expect(PathUtilities.hexString(background.resolvedTextColor, includeAlpha: true) == "#CC3300FF")
    }

    @Test("an invalid field does not discard valid neighboring fields")
    func fieldLevelFallback() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(Data(
            """
            {"schemaVersion":1,"preferences":{"interfaceTheme":"future","accent":"indigo","editorFontFamily":"Menlo","editorFontSize":"broken","editorReadingWidth":840,"editorCanvas":"warm"}}
            """.utf8
        ), forKey: AppAppearanceStore.defaultsKey)

        let loaded = fixture.store.load().preferences

        #expect(loaded.interfaceTheme == .system)
        #expect(loaded.accent == .indigo)
        #expect(loaded.editorFontFamily == "Menlo")
        #expect(loaded.editorFontSize == 16)
        #expect(loaded.editorReadingWidth == 840)
        #expect(loaded.editorCanvas == .warm)
    }

    @Test("corrupt configuration falls back without touching quick-note appearance")
    func corruptConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(Data("not-json".utf8), forKey: AppAppearanceStore.defaultsKey)
        fixture.defaults.set(Data("quick-note-data".utf8), forKey: QuickNoteAppearanceStore.defaultsKey)

        let loaded = fixture.store.load()

        #expect(loaded.preferences == .standard)
        #expect(loaded.warning != nil)
        #expect(fixture.defaults.data(forKey: QuickNoteAppearanceStore.defaultsKey) == Data("quick-note-data".utf8))
    }

    @Test("a missing imported image falls back to the system background")
    func missingImage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var preferences = AppAppearancePreferences.standard
        preferences.background.kind = .image
        preferences.background.imageFileName = "missing.png"
        try fixture.store.save(preferences)

        let loaded = fixture.store.load()

        #expect(loaded.preferences.background == .standard)
        #expect(loaded.warning != nil)
        #expect(loaded.requiresSave)
    }

    @Test("controller updates persist immediately and reset to defaults")
    @MainActor
    func controllerUpdates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let controller = AppAppearanceController(store: fixture.store)

        controller.update {
            $0.interfaceTheme = .dark
            $0.accent = .orange
            $0.editorCanvas = .paper
            $0.editorReadingWidth = 800
        }

        #expect(controller.preferences.interfaceTheme == .dark)
        #expect(fixture.store.load().preferences == controller.preferences)
        controller.reset()
        #expect(controller.preferences == .standard)
        #expect(fixture.store.load().preferences == .standard)
    }

    @Test("image import records luminance and replacing or leaving image mode cleans old files")
    @MainActor
    func imageLifecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let white = try fixture.makeImage(named: "white.png", color: .white)
        let black = try fixture.makeImage(named: "black.png", color: .black)
        let controller = AppAppearanceController(store: fixture.store)

        await controller.importBackground(from: white)
        let firstName = try #require(controller.preferences.background.imageFileName)
        #expect(controller.preferences.background.imageLuminance ?? 0 > 0.9)
        #expect(fixture.backgroundExists(firstName))

        await controller.importBackground(from: black)
        let secondName = try #require(controller.preferences.background.imageFileName)
        #expect(secondName != firstName)
        #expect(!fixture.backgroundExists(firstName))
        #expect(fixture.backgroundExists(secondName))
        #expect(controller.preferences.background.imageLuminance ?? 1 < 0.05)

        controller.update { $0.background.kind = .solid }
        #expect(controller.preferences.background.imageFileName == nil)
        #expect(!fixture.backgroundExists(secondName))
    }

    @Test("failed image persistence removes the staged asset and keeps valid preferences")
    @MainActor
    func failedImagePersistence() async throws {
        let fixture = try Fixture(failWrites: true)
        defer { fixture.cleanUp() }
        let source = try fixture.makeImage(named: "source.png", color: .white)
        let controller = AppAppearanceController(store: fixture.store)

        await controller.importBackground(from: source)

        #expect(controller.preferences == .standard)
        #expect(controller.errorMessage != nil)
        #expect(try fixture.backgroundFiles().isEmpty)
    }

    @Test("failed persistence keeps the last valid preferences")
    @MainActor
    func failedWrite() throws {
        let fixture = try Fixture(failWrites: true)
        defer { fixture.cleanUp() }
        let controller = AppAppearanceController(store: fixture.store)

        controller.update { $0.accent = .purple }

        #expect(controller.preferences == .standard)
        #expect(controller.errorMessage != nil)
        #expect(fixture.store.load().preferences == .standard)
    }
}

private final class Fixture {
    let suiteName = "RepotraTests.AppAppearance.\(UUID().uuidString)"
    let defaults: UserDefaults
    let rootURL: URL
    let backgroundsURL: URL
    let store: AppAppearanceStore

    init(failWrites: Bool = false, failCopies: Bool = false) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "RepotraAppearanceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        backgroundsURL = rootURL.appending(path: "MainBackgrounds", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        store = AppAppearanceStore(
            defaultsSuiteName: suiteName,
            applicationSupportURL: backgroundsURL,
            failWrites: failWrites,
            failCopies: failCopies
        )
    }

    func makeStore() -> AppAppearanceStore {
        AppAppearanceStore(defaultsSuiteName: suiteName, applicationSupportURL: backgroundsURL)
    }

    func makeImage(named name: String, color: NSColor) throws -> URL {
        let url = rootURL.appending(path: name)
        let converted = try #require(color.usingColorSpace(.deviceRGB))
        let pixel = Data([
            UInt8((converted.redComponent * 255).rounded()),
            UInt8((converted.greenComponent * 255).rounded()),
            UInt8((converted.blueComponent * 255).rounded()),
            255,
        ])
        let provider = try #require(CGDataProvider(data: pixel as CFData))
        let image = try #require(CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    func backgroundExists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: backgroundsURL.appending(path: fileName).path)
    }

    func backgroundFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: backgroundsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: backgroundsURL,
            includingPropertiesForKeys: nil
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}
