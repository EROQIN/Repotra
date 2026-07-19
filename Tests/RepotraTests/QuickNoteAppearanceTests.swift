import Foundation
@testable import Repotra
import Testing

@Suite("Quick note appearance")
struct QuickNoteAppearanceTests {
    @Test("appearance round trips through the compatible v1 format")
    func appearanceRoundTrip() throws {
        var appearance = QuickNoteAppearance.standard
        appearance.textColor = .hex("#E64A19FF")
        appearance.background.kind = .gradient
        appearance.background.primaryColor = .hex("#102030FF")
        appearance.background.secondaryColor = .hex("#405060FF")
        appearance.opacity = 0.55

        let data = try JSONEncoder().encode(
            QuickNoteAppearanceConfiguration(schemaVersion: 1, appearance: appearance)
        )
        let decoded = try JSONDecoder().decode(QuickNoteAppearanceConfiguration.self, from: data)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.appearance == appearance)
    }

    @Test("normalization clamps values and repairs invalid colors")
    func normalization() {
        var appearance = QuickNoteAppearance.standard
        appearance.fontSize = .infinity
        appearance.opacity = -4
        appearance.cornerRadius = 100
        appearance.textColor = .hex("not-a-color")
        appearance.borderColor = "broken"

        let normalized = appearance.normalized()

        #expect(normalized.fontSize == QuickNoteAppearance.standard.fontSize)
        #expect(normalized.opacity == 0.35)
        #expect(normalized.cornerRadius == 28)
        #expect(normalized.textColor == .systemText)
        #expect(normalized.borderColor == "#00000026")
    }

    @Test("draft edits preview immediately and cancel restores committed values")
    @MainActor
    func draftCancel() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let controller = QuickNoteAppearanceController(store: fixture.store)
        await controller.loadIfNeeded()

        controller.beginEditing()
        controller.updateDraft {
            $0.textColor = .hex("#FF0000FF")
            $0.background.kind = .solid
            $0.background.primaryColor = .hex("#102030FF")
        }

        #expect(controller.preview.textColor == .hex("#FF0000FF"))
        #expect(controller.committed == .standard)
        controller.cancel()
        #expect(controller.preview == .standard)
        #expect(controller.draft == nil)
        #expect((await fixture.store.load()).appearance == .standard)
    }

    @Test("sequential color edits keep all channels independent")
    @MainActor
    func sequentialColorEditsKeepChannelsIndependent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let controller = QuickNoteAppearanceController(store: fixture.store)
        await controller.loadIfNeeded()
        controller.beginEditing()

        controller.updateDraft { $0.textColor = .hex("#FF0000FF") }
        controller.updateDraft {
            $0.background.kind = .solid
            $0.background.primaryColor = .hex("#102030FF")
        }
        controller.updateDraft {
            $0.background.kind = .gradient
            $0.background.secondaryColor = .hex("#405060FF")
        }
        controller.updateDraft {
            $0.hasBorder = true
            $0.borderColor = "#FF00FFFF"
        }

        #expect(controller.preview.textColor == .hex("#FF0000FF"))
        #expect(controller.preview.background.primaryColor == .hex("#102030FF"))
        #expect(controller.preview.background.secondaryColor == .hex("#405060FF"))
        #expect(controller.preview.borderColor == "#FF00FFFF")
    }

    @Test("commit persists the complete draft once")
    @MainActor
    func commitPersistsDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let controller = QuickNoteAppearanceController(store: fixture.store)
        await controller.loadIfNeeded()
        controller.beginEditing()
        controller.updateDraft {
            $0.opacity = 0.6
            $0.textColor = .hex("#E64A19FF")
        }

        #expect(await controller.commit())
        #expect(controller.draft == nil)
        let loaded = await fixture.store.load()
        #expect(loaded.appearance.opacity == 0.6)
        #expect(loaded.appearance.textColor == .hex("#E64A19FF"))
    }

    @Test("failed commit keeps the draft and last committed configuration")
    @MainActor
    func failedCommitKeepsDraft() async throws {
        let fixture = try Fixture(failWrites: true)
        defer { fixture.cleanUp() }
        let controller = QuickNoteAppearanceController(store: fixture.store)
        await controller.loadIfNeeded()
        controller.beginEditing()
        controller.updateDraft { $0.opacity = 0.5 }

        #expect(await controller.commit() == false)
        #expect(controller.draft?.opacity == 0.5)
        #expect(controller.committed == .standard)
        #expect(controller.errorMessage != nil)
        #expect((await fixture.store.load()).appearance == .standard)
    }

    @Test("reset only changes the draft until committed")
    @MainActor
    func resetIsDraftOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var saved = QuickNoteAppearance.standard
        saved.opacity = 0.5
        try await fixture.store.save(saved)
        let controller = QuickNoteAppearanceController(store: fixture.store)
        await controller.loadIfNeeded()

        controller.beginEditing()
        controller.resetDraft()
        #expect(controller.preview == .standard)
        #expect(controller.committed.opacity == 0.5)
        controller.cancel()
        #expect(controller.preview.opacity == 0.5)
    }

    @Test("theme presets preserve common size and opacity controls")
    func themePreset() {
        var appearance = QuickNoteAppearance.standard
        appearance.fontSize = 22
        appearance.opacity = 0.7
        let dark = QuickNoteThemePreset.dark.applying(to: appearance)

        #expect(dark.fontSize == 22)
        #expect(dark.opacity == 0.7)
        #expect(QuickNoteThemePreset.matching(dark) == .dark)
        var customized = dark
        customized.hasBorder = true
        #expect(QuickNoteThemePreset.matching(customized) == .custom)
    }

    @Test("selected background color reaches the renderer")
    func renderedBackgroundKeepsSelectedColor() {
        var background = QuickNoteBackground()
        background.kind = .solid
        background.primaryColor = .hex("#102030FF")
        background.secondaryColor = .hex("#405060FF")

        let rendered = RenderedBackground.quickNote(
            background,
            backgroundsURL: FileManager.default.temporaryDirectory
        )

        if case .solid = rendered.kind {
            #expect(PathUtilities.hexString(rendered.primaryColor, includeAlpha: true) == "#102030FF")
            #expect(PathUtilities.hexString(rendered.secondaryColor, includeAlpha: true) == "#405060FF")
        } else {
            Issue.record("A solid quick-note background must render as a solid color")
        }
    }

    @Test("appearance remains global across store instances")
    func persistsGlobally() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var appearance = QuickNoteAppearance.standard
        appearance.opacity = 0.4
        appearance.textColor = .hex("#E64A19FF")
        try await fixture.store.save(appearance)

        let second = QuickNoteAppearanceStore(
            defaultsSuiteName: fixture.suiteName,
            applicationSupportURL: fixture.root.appending(path: "other-root")
        )
        #expect((await second.load()).appearance == appearance)
    }

    @Test("invalid configuration falls back with a warning")
    func invalidConfiguration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(Data("not-json".utf8), forKey: QuickNoteAppearanceStore.defaultsKey)

        let loaded = await fixture.store.load()
        #expect(loaded.appearance == .standard)
        #expect(loaded.warning != nil)
    }

    @Test("missing background image falls back to the system background")
    func missingBackgroundImage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var appearance = QuickNoteAppearance.standard
        appearance.background.kind = .image
        appearance.background.imageFileName = "missing.png"
        try await fixture.store.save(appearance)

        let loaded = await fixture.store.load()
        #expect(loaded.appearance.background.kind == .system)
        #expect(loaded.appearance.background.imageFileName == nil)
        #expect(loaded.warning != nil)
    }

    @Test("committing image mode without an image uses the system background")
    func emptyImageSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var appearance = QuickNoteAppearance.standard
        appearance.background.kind = .image

        let committed = try await fixture.store.commit(appearance, stagedBackground: nil)

        #expect(committed.background.kind == .system)
        #expect((await fixture.store.load()).appearance.background.kind == .system)
    }

    @Test("staged backgrounds are promoted only on commit")
    func stagedBackgroundCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = fixture.root.appending(path: "source.png")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: source)

        let staged = try await fixture.store.stageBackground(from: source)
        let directory = await fixture.store.backgroundsDirectory()
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: staged.previewRelativePath).path))

        var appearance = QuickNoteAppearance.standard
        appearance.background.kind = .image
        appearance.background.imageFileName = staged.previewRelativePath
        let committed = try await fixture.store.commit(appearance, stagedBackground: staged)

        #expect(committed.background.imageFileName == staged.fileName)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: staged.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: staged.previewRelativePath).path))
    }

    @Test("discard removes a staged background without changing settings")
    func stagedBackgroundCancel() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = fixture.root.appending(path: "source.png")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: source)
        let staged = try await fixture.store.stageBackground(from: source)
        let directory = await fixture.store.backgroundsDirectory()

        await fixture.store.discard(staged)

        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: staged.previewRelativePath).path))
        #expect((await fixture.store.load()).appearance == .standard)
    }
}

private final class Fixture: @unchecked Sendable {
    let suiteName = "RepotraTests.QuickNoteAppearance.\(UUID().uuidString)"
    let root = FileManager.default.temporaryDirectory
        .appending(path: "RepotraAppearance-\(UUID().uuidString)")
    let defaults: UserDefaults
    let store: QuickNoteAppearanceStore

    init(failWrites: Bool = false) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        store = QuickNoteAppearanceStore(
            defaultsSuiteName: suiteName,
            applicationSupportURL: root.appending(path: "app-support"),
            failWrites: failWrites
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
