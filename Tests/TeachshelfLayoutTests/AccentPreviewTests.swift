import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor struct AccentPreviewTests {
    private func withStore(_ action: (AppStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-accent-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(repository: try LibraryRepository(root: root), remembersLocation: false)
        try action(store)
    }

    @Test func previewAndCancelLeaveTheIndexUntouched() throws {
        try withStore { store in
            let index = store.repository.root.appendingPathComponent("library.json")
            let before = try Data(contentsOf: index)
            let session = try #require(store.beginAccentPreview())
            store.previewAccent("3b72b8", sessionID: session)
            #expect(store.effectiveAccentHex == "#3B72B8")
            #expect(store.state.accentColor == ColorPalette.defaultAccent)
            #expect(try Data(contentsOf: index) == before)
            store.cancelAccentPreview(sessionID: session)
            #expect(store.effectiveAccentHex == ColorPalette.defaultAccent)
            #expect(try Data(contentsOf: index) == before)
        }
    }

    @Test func saveCommitsThePreviewAndPreservesCourseIdentity() throws {
        try withStore { store in
            var course = Course(name: "独立课程色")
            course.colorHex = "#CC7770"
            try store.repository.saveCourse(course); store.reload()
            let session = try #require(store.beginAccentPreview())
            store.previewAccent("#8058A1", sessionID: session)
            #expect(store.saveAccentPreview(sessionID: session))
            #expect(store.accentPreviewID == nil)
            #expect(store.effectiveAccentHex == "#8058A1")
            #expect(store.repository.state.accentColor == "#8058A1")
            #expect(store.state.courses.first?.colorHex == "#CC7770")
        }
    }

    @Test func onlyTheActiveEditorCanChangeOrCancelThePreview() throws {
        try withStore { store in
            let first = try #require(store.beginAccentPreview())
            #expect(store.beginAccentPreview() == nil)
            store.previewAccent("#3B72B8", sessionID: first)
            store.previewAccent("#invalid", sessionID: first)
            #expect(store.effectiveAccentHex == "#3B72B8")
            store.cancelAccentPreview(sessionID: first)
            let second = try #require(store.beginAccentPreview())
            store.previewAccent("#8058A1", sessionID: second)
            store.cancelAccentPreview(sessionID: first)
            store.previewAccent("#000000", sessionID: first)
            #expect(!store.saveAccentPreview(sessionID: first))
            #expect(store.effectiveAccentHex == "#8058A1")
            #expect(store.accentPreviewID == second)
            store.cancelAccentPreview(sessionID: second)
        }
    }

    @Test func displayTonesStayReadableWithoutChangingTheChosenColor() throws {
        let white = try #require(RGBColor(hex: "#FFFFFF"))
        for hex in ["#FFFFFF", "#000000", "#FFFF00", "#39786B", "#8058A1"] {
            for dark in [false, true] {
                let background = try #require(RGBColor(hex: dark ? "#242628" : "#FFFFFF"))
                for increased in [false, true] {
                    let theme = AppTheme(hex: hex, dark: dark, increasedContrast: increased)
                    let minimum = increased ? 7.0 : 4.5
                    #expect(theme.source.hex == hex)
                    #expect(theme.inkRGB.contrastRatio(with: background) >= minimum - 0.0001)
                    #expect(theme.controlRGB.contrastRatio(with: white) >= minimum - 0.0001)
                }
            }
        }
    }
}
