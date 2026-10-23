import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
struct ThemeTests {
    @Test func hexInputNormalizesAndRejectsMalformedValues() throws {
        for value in ["39786b", "#39786b", " \n#39786B\t", "abcdef", "#ABCDEF"] {
            let color = try #require(RGBColor(hex: value))
            #expect(color.hex == (value.lowercased().contains("39786b") ? "#39786B" : "#ABCDEF"))
        }
        for value in ["", "#", "###39786B", "##39786B", "#123", "1234567", "#1234567", "#12 345", "#12GG45", "39#786B", "３９７８６Ｂ", "#39786B\0"] {
            #expect(RGBColor(hex: value) == nil)
        }
        #expect(ColorPalette.isStoredColor("#abcdef"))
        #expect(!ColorPalette.isStoredColor("abcdef"))
        #expect(!ColorPalette.isStoredColor(" #ABCDEF"))
        #expect(RGBColor(red: -1, green: 2, blue: .nan).hex == "#00FF00")
        #expect(RGBColor(red: .infinity, green: -.infinity, blue: 0.5).hex == "#FF0080")
    }

    @Test func originalThemePresetsRetainNamesAndColors() {
        #expect(ColorPalette.defaultAccent == "#39786B")
        #expect(ColorPalette.themes.map(\.name) == ["松柏绿", "湖水青", "晴空蓝", "靛青", "鸢尾紫", "玫瑰粉", "砖红", "陶土橙", "琥珀金", "橄榄绿", "咖啡棕", "石墨灰"])
        #expect(ColorPalette.themes.map(\.hex) == ["#39786B", "#287D8E", "#3B72B8", "#5555A5", "#8058A1", "#AE567C", "#B2534D", "#AC633C", "#967326", "#6C7E3D", "#826452", "#596574"])
    }

    @Test func contrastAdjustmentKeepsExtremeAccentsReadableInBothAppearances() throws {
        let white = try #require(RGBColor(hex: "#FFFFFF")), black = try #require(RGBColor(hex: "#000000"))
        #expect(white.relativeLuminance == 1)
        #expect(black.relativeLuminance == 0)
        #expect(abs(white.contrastRatio(with: black) - 21) < 0.000001)
        for backgroundHex in ["#FFFFFF", "#F2F2F2", "#1C1C1E", "#000000"] {
            let background = try #require(RGBColor(hex: backgroundHex))
            for accentHex in ["#FFFFFF", "#000000", "#FFFF00", "#00FFFF", "#FF00FF", "#39786B", "#777777"] {
                let accent = try #require(RGBColor(hex: accentHex))
                let adjusted = accent.contrasting(on: background, minimumRatio: 4.5)
                #expect(adjusted.contrastRatio(with: background) >= 4.5)
                if accent.contrastRatio(with: background) >= 4.5 { #expect(adjusted == accent) }
                else {
                    #expect(abs(adjusted.contrastRatio(with: background) - 4.5) < 0.000001)
                    // A step back toward the user's color must fall below the requested ratio.
                    let lessAdjusted = RGBColor(red: adjusted.red + (accent.red - adjusted.red) * 0.0001,
                                                green: adjusted.green + (accent.green - adjusted.green) * 0.0001,
                                                blue: adjusted.blue + (accent.blue - adjusted.blue) * 0.0001)
                    #expect(lessAdjusted.contrastRatio(with: background) < 4.5)
                }
            }
        }
        let gray = try #require(RGBColor(hex: "#777777"))
        #expect(gray.contrasting(on: gray, minimumRatio: 30) == black)
        #expect(gray.contrasting(on: gray, minimumRatio: .infinity) == black)
        #expect(gray.contrasting(on: gray, minimumRatio: .nan) == gray)
        #expect(gray.contrasting(on: gray, minimumRatio: 0) == gray)
    }

    @Test func savedThemeSurvivesReopenWithoutChangingCourseColors() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Library")
        let course = Course(name: "独立课程色", colorHex: "#CC7770")
        do {
            let repository = try LibraryRepository(root: root)
            try repository.saveCourse(course)
            try repository.saveAccentColor("  abcdef\n")
            try repository.saveCourseBorders(false)
            #expect(repository.state.accentColor == "#ABCDEF")
            #expect(!repository.state.showCourseBorders)
        }
        let reopened = try LibraryRepository(root: root)
        #expect(reopened.state.accentColor == "#ABCDEF")
        #expect(!reopened.state.showCourseBorders)
        #expect(reopened.state.courses == [course])
    }

    @Test func transitionDefaultsPreserveOldIndexesAndInvalidStoredPreferencesAreRejected() throws {
        #expect(AppearanceTransitionSettings.default.isEnabled)
        #expect(AppearanceTransitionSettings.default.direction == .top)
        #expect(AppearanceTransitionSettings.default.speed == 1)
        #expect(AppearanceTransitionSettings.default.colorMode == .solid)
        #expect(AppearanceTransitionSettings.default.isValid)
        #expect(AppearanceTransitionSettings.rainbowHexes.count == 10)
        #expect(Set(AppearanceTransitionSettings.rainbowHexes).count == 10)
        #expect(AppearanceTransitionSettings.rainbowHexes.allSatisfy(ColorPalette.isStoredColor))

        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let index = root.appendingPathComponent("library.json")
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryState())) as? [String: Any])
        encoded.removeValue(forKey: "appearanceTransition")
        let oldBytes = try JSONSerialization.data(withJSONObject: encoded)
        try oldBytes.write(to: index)
        do {
            let repository = try LibraryRepository(root: root)
            #expect(repository.state.appearanceTransition == .default)
            #expect(repository.state.schemaVersion == 8)
            #expect(try Data(contentsOf: index) == oldBytes)
        }

        let valid = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppearanceTransitionSettings.default)) as? [String: Any])
        let invalidFields: [(String, Any)] = [
            ("isEnabled", NSNull()), ("isEnabled", "false"), ("isEnabled", 0),
            ("speed", 0.49), ("speed", 2.1), ("colorHex", "#123"),
            ("colorHex", " 808080"), ("direction", "diagonal"), ("colorMode", "gradient")
        ]
        var invalidValues: [Any] = invalidFields.map { key, value in
            var settings = valid; settings[key] = value; return settings
        }
        invalidValues.append(NSNull())
        for invalid in invalidValues {
            encoded["appearanceTransition"] = invalid
            let bytes = try JSONSerialization.data(withJSONObject: encoded)
            try bytes.write(to: index)
            #expect(throws: LibraryError.self) { try LibraryRepository(root: root) }
            #expect(try Data(contentsOf: index) == bytes)
        }
    }

    @Test func olderTransitionPreferencesDefaultToEnabledWithoutLosingCustomizations() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let index = root.appendingPathComponent("library.json")
        let expected = AppearanceTransitionSettings(direction: .bottom, speed: 1.7, colorMode: .rainbow, colorHex: "#8058A1")
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryState())) as? [String: Any])
        var settings = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        settings.removeValue(forKey: "isEnabled")
        encoded["appearanceTransition"] = settings
        let oldBytes = try JSONSerialization.data(withJSONObject: encoded)
        try oldBytes.write(to: index)

        let repository = try LibraryRepository(root: root)
        #expect(repository.state.appearanceTransition == expected)
        #expect(try Data(contentsOf: index) == oldBytes)
        try repository.saveAppearanceTransition(expected)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        let savedSettings = try #require(saved["appearanceTransition"] as? [String: Any])
        #expect(savedSettings["isEnabled"] as? Bool == true)
    }

    @Test func transitionPreferencesSurviveReopenAndOnlyChangeTheirOwnFields() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Library")
        var expected = LibraryState()
        do {
            let repository = try LibraryRepository(root: root)
            let course = Course(name: "保留课程", colorHex: "#8058A1")
            try repository.saveCourse(course)
            try repository.saveTask(StudyTask(title: "保留计划", courseID: course.id))
            expected = repository.state
            let settings = AppearanceTransitionSettings(isEnabled: false, direction: .right, speed: 2, colorMode: .rainbow, colorHex: " abcdef\n")
            try repository.saveAppearanceTransition(settings)
            var saved = settings; saved.colorHex = "#ABCDEF"
            expected.appearanceTransition = saved
            #expect(repository.state == expected)
        }
        let reopened = try LibraryRepository(root: root)
        #expect(reopened.state == expected)
        #expect(reopened.state.schemaVersion == 8)
    }

    @Test func invalidTransitionInputAndFailedSavesPreservePreferencesAndIndex() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repository = try LibraryRepository(root: sandbox.appendingPathComponent("Library"))
        try repository.saveAccentColor("#8058A1")
        let before = repository.state
        let index = repository.root.appendingPathComponent("library.json")
        let bytes = try Data(contentsOf: index)
        for speed in [Double.nan, .infinity, -.infinity, -1, 0, 0.49, 2.01] {
            #expect(throws: LibraryError.self) {
                try repository.saveAppearanceTransition(AppearanceTransitionSettings(speed: speed))
            }
            #expect(repository.state == before)
            #expect(try Data(contentsOf: index) == bytes)
        }
        for color in ["", "#123", "#GGG000", "##808080"] {
            #expect(throws: LibraryError.self) {
                try repository.saveAppearanceTransition(AppearanceTransitionSettings(colorHex: color))
            }
            #expect(repository.state == before)
            #expect(try Data(contentsOf: index) == bytes)
        }
        let backup = repository.root.appendingPathComponent("library.json.bak")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try repository.saveAppearanceTransition(AppearanceTransitionSettings(isEnabled: false, direction: .bottom, speed: 0.5, colorMode: .rainbow))
        }
        #expect(repository.state == before)
        #expect(try Data(contentsOf: index) == bytes)
    }

    @Test func invalidColorsAndFailedSavesPreserveThemeAndIndex() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repository = try LibraryRepository(root: sandbox.appendingPathComponent("Library"))
        try repository.saveAccentColor("#8058A1")
        let before = repository.state, index = repository.root.appendingPathComponent("library.json")
        let bytes = try Data(contentsOf: index)
        for value in ["#123", "#GGG000", "##000000", ""] {
            #expect(throws: LibraryError.self) { try repository.saveAccentColor(value) }
            #expect(repository.state == before)
            #expect(try Data(contentsOf: index) == bytes)
        }
        let backup = repository.root.appendingPathComponent("library.json.bak")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try repository.saveAccentColor("#3B72B8") }
        #expect(throws: (any Error).self) { try repository.saveCourseBorders(false) }
        #expect(repository.state == before)
        #expect(try Data(contentsOf: index) == bytes)
    }

    @Test func backupRestoreAndMigrationPreserveThemePreferences() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repository = try LibraryRepository(root: sandbox.appendingPathComponent("Library"))
        try repository.saveAccentColor("#AE567C")
        try repository.saveCourseBorders(false)
        try repository.saveAppearance("dark")
        try repository.saveAppearanceTransition(AppearanceTransitionSettings(isEnabled: false, direction: .left, speed: 0.8,
                                                                          colorMode: .rainbow, colorHex: "#8058A1"))
        let original = repository.state
        let backup = sandbox.appendingPathComponent("Theme.teachshelfbackup")
        try repository.backup(to: backup)
        try repository.saveAccentColor("#967326")
        try repository.saveCourseBorders(true)
        try repository.saveAppearance("light")
        try repository.saveAppearanceTransition(.default)
        try repository.restore(from: backup)
        #expect(repository.state == original)
        let destination = sandbox.appendingPathComponent("Migrated")
        try repository.copyLibrary(to: destination)
        let migrated = try LibraryRepository(root: destination)
        #expect(migrated.state == original)
    }

    @Test func failedRestoreKeepsCurrentThemePreferences() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repository = try LibraryRepository(root: sandbox.appendingPathComponent("Library"))
        try repository.saveAccentColor("#AE567C")
        try repository.saveCourseBorders(false)
        let backup = sandbox.appendingPathComponent("Theme.teachshelfbackup")
        try repository.backup(to: backup)
        try repository.saveAccentColor("#967326")
        try repository.saveCourseBorders(true)
        let before = repository.state
        let index = repository.root.appendingPathComponent("library.json")
        let bytes = try Data(contentsOf: index)
        let indexBackup = repository.root.appendingPathComponent("library.json.bak")
        try FileManager.default.removeItem(at: indexBackup)
        try FileManager.default.createDirectory(at: indexBackup, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try repository.restore(from: backup) }
        #expect(repository.state == before)
        #expect(try Data(contentsOf: index) == bytes)
    }

    @Test func olderIndexDefaultsOnlyNewPreferenceAndStillRequiresOriginalFields() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryState())) as? [String: Any])
        encoded.removeValue(forKey: "showCourseBorders")
        let index = root.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: encoded).write(to: index)
        do {
            let repository = try LibraryRepository(root: root)
            #expect(repository.state.showCourseBorders)
            try repository.saveCourseBorders(false)
        }
        for key in ["schemaVersion", "courses", "materials", "tasks", "customCategories", "accentColor", "appearance"] {
            var missing = encoded
            missing.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: missing)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(LibraryState.self, from: data) }
        }
        encoded["showCourseBorders"] = NSNull()
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: encoded)) }
    }

    @Test func invalidStoredAccentIsRejectedWithoutOverwritingIndex() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let index = root.appendingPathComponent("library.json")
        for color in ["39786B", " #39786B", "#39786B ", "#39GG6B", "#123"] {
            var state = LibraryState()
            state.accentColor = color
            let bytes = try JSONEncoder().encode(state)
            try bytes.write(to: index)
            #expect(throws: LibraryError.self) { try LibraryRepository(root: root) }
            #expect(try Data(contentsOf: index) == bytes)
        }
        var valid = LibraryState()
        valid.accentColor = "#abcdef"
        try JSONEncoder().encode(valid).write(to: index)
        #expect(try LibraryRepository(root: root).state.accentColor == "#abcdef")
    }

    private func makeSandbox() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TeachshelfThemeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
