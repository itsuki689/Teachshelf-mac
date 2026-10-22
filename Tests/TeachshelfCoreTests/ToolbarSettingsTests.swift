import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized) struct ToolbarSettingsTests {
    @Test func olderIndexesKeepTheirContentsAndUseTheOriginalFourShortcutsWithoutRewriting() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Library"), index = root.appendingPathComponent("library.json")
        var expected: LibraryState
        do { expected = try populatedLibrary(at: root).state }
        var document = try indexDocument(at: index)
        document.removeValue(forKey: "toolbarSettings")
        let oldBytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try oldBytes.write(to: index)

        let repository = try LibraryRepository(root: root)
        #expect(repository.state.toolbarSettings.actions == [.update, .settings, .importMaterials, .create])
        expected.toolbarSettings = .default
        #expect(repository.state == expected)
        #expect(try Data(contentsOf: index) == oldBytes)
    }

    @Test func aCustomOrderAndAnEmptyCapsuleBothSurviveReopeningWithoutChangingLibraryRecords() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let configurations = [
            ToolbarSettings(actions: [.pendingTasks, .schedule, .importMaterials, .favorites, .homework, .settings]),
            ToolbarSettings(actions: [])
        ]
        for (number, settings) in configurations.enumerated() {
            let root = sandbox.appendingPathComponent("Library-\(number)")
            var expected: LibraryState
            do {
                let repository = try populatedLibrary(at: root)
                expected = repository.state
                expected.toolbarSettings = settings
                try repository.saveToolbarSettings(settings)
                #expect(repository.state == expected)
            }
            let reopened = try LibraryRepository(root: root)
            #expect(reopened.state == expected)
            let document = try indexDocument(at: root.appendingPathComponent("library.json"))
            let encodedSettings = try #require(document["toolbarSettings"] as? [String: Any])
            #expect(encodedSettings["actions"] as? [String] == settings.actions.map(\.rawValue))
        }
    }

    @Test func invalidStoredShortcutsAreRejectedAndTheirOriginalIndexBytesRemainRecoverable() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Library"), index = root.appendingPathComponent("library.json")
        do { _ = try populatedLibrary(at: root) }
        var document = try indexDocument(at: index)
        let invalid: [Any] = [
            ["actions": ["futureAction"]],
            ["actions": [ToolbarAction.settings.rawValue, ToolbarAction.settings.rawValue]],
            ["actions": Array(ToolbarAction.allCases.prefix(7)).map(\.rawValue)],
            ["actions": NSNull()],
            NSNull()
        ]
        for value in invalid {
            document["toolbarSettings"] = value
            let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try bytes.write(to: index)
            #expect(throws: LibraryError.self) { try LibraryRepository(root: root) }
            #expect(try Data(contentsOf: index) == bytes)
        }
    }

    @Test func invalidAndFailedWritesPreserveTheCurrentShortcutsRecordsAndIndex() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repository = try populatedLibrary(at: sandbox.appendingPathComponent("Library"))
        try repository.saveToolbarSettings(ToolbarSettings(actions: [.schedule, .settings, .pendingTasks]))
        let before = repository.state, index = repository.root.appendingPathComponent("library.json")
        let backup = repository.root.appendingPathComponent("library.json.bak")
        let bytes = try Data(contentsOf: index), backupBytes = try Data(contentsOf: backup)
        for settings in [
            ToolbarSettings(actions: [.settings, .settings]),
            ToolbarSettings(actions: Array(ToolbarAction.allCases.prefix(7)))
        ] {
            #expect(throws: LibraryError.self) { try repository.saveToolbarSettings(settings) }
            #expect(repository.state == before)
            #expect(try Data(contentsOf: index) == bytes)
            #expect(try Data(contentsOf: backup) == backupBytes)
        }

        // A valid edit must also remain atomic if replacing the index backup fails.
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try repository.saveToolbarSettings(ToolbarSettings(actions: [])) }
        #expect(repository.state == before)
        #expect(try Data(contentsOf: index) == bytes)
    }

    @Test func backupRestoreAndMigrationCarryTheCapsuleOrderTogetherWithCourseAndPlanData() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repository = try populatedLibrary(at: sandbox.appendingPathComponent("Library"))
        let settings = ToolbarSettings(actions: [.recent, .allMaterials, .pendingTasks, .importMaterials, .create, .settings])
        try repository.saveToolbarSettings(settings)
        let original = repository.state
        let backup = sandbox.appendingPathComponent("Workspace.teachshelfbackup")
        try repository.backup(to: backup)
        let backupDocument = try indexDocument(at: backup.appendingPathComponent("library.json"))
        let encodedSettings = try #require(backupDocument["toolbarSettings"] as? [String: Any])
        #expect(encodedSettings["actions"] as? [String] == settings.actions.map(\.rawValue))

        try repository.saveToolbarSettings(ToolbarSettings(actions: []))
        var changedCourse = try #require(original.courses.first)
        changedCourse.name = "备份之后的课程修改"
        try repository.saveCourse(changedCourse)
        try repository.saveTask(StudyTask(title: "备份之后新增的计划"))
        try repository.restore(from: backup)
        #expect(repository.state == original)

        let destination = sandbox.appendingPathComponent("Migrated")
        try repository.copyLibrary(to: destination)
        let migrated = try LibraryRepository(root: destination)
        #expect(migrated.state == original)
    }

    private func populatedLibrary(at root: URL) throws -> LibraryRepository {
        let repository = try LibraryRepository(root: root)
        let course = Course(name: "保留课程资料", semester: "2026 秋季", teacher: "原有教师", colorHex: "#8058A1")
        try repository.saveCourse(course)
        try repository.saveTask(StudyTask(title: "保留课程计划", content: "原有备注", courseID: course.id,
                                         startsAt: Date(timeIntervalSince1970: 1_800_000_000),
                                         deadline: Date(timeIntervalSince1970: 1_800_086_400)))
        return repository
    }

    private func indexDocument(at index: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
    }

    private func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-toolbar-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
