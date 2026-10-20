import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
final class TimetableTests {
    private var folders: [URL] = []
    deinit { for folder in folders { try? FileManager.default.removeItem(at: folder) } }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TimetableTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }
    private func course(weeks: [Int] = [1, 2, 3, 4], weekday: Int? = 1, start: Int = 1, offset: Int = 1, classroom: String = "仙Ⅰ-101", code: String = "MATH001") -> UndergraduateCourse {
        UndergraduateCourse(name: "高等数学", classroom: classroom, classNumber: code, teacher: "张老师", weeks: weeks,
            weekday: weekday, startSection: start, timeCount: offset, examTime: "另行通知", info: "教学备注")
    }
    private func schedule(_ courses: [UndergraduateCourse], name: String = "2026–2027 学年第一学期") -> UndergraduateSchedule {
        UndergraduateSchedule(name: name, courses: courses)
    }
    private func academicDate(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try #require(formatter.date(from: text))
    }

    @Test func importsOffsetsFreeTimeAndDistinctSessionsWhileCollapsingExactDuplicates() throws {
        let repo = try LibraryRepository(root: folder())
        let first = course(weeks: [3, 1, 3]), laterRoom = course(weeks: [1, 3], classroom: "仙Ⅰ-102")
        let oneSection = course(weeks: [2, 4], weekday: 4, start: 5, offset: 0)
        let free = UndergraduateCourse(name: "学年论文", weeks: [], weekday: 0)
        let result = try repo.importUndergraduateTimetable(schedule([first, first, laterRoom, oneSection, free]))
        #expect(result.coursesCreated == 2)
        #expect(result.meetingsImported == 4)
        let term = try #require(repo.state.timetableTerms.first)
        #expect(term.id == result.termID)
        #expect(term.weekCount == 20)
        #expect(term.meetings[0].weeks == [1, 3])
        #expect(term.meetings[0].sectionCount == 2)
        #expect(term.meetings[0].endSection == 2)
        #expect(term.meetings[2].sectionCount == 1)
        #expect(term.meetings[2].endSection == 5)
        #expect(term.meetings[2].isScheduled)
        #expect(!term.meetings[3].isScheduled)
        #expect(term.meetings[3].weekday == nil)
        #expect(term.meetings[3].sectionCount == 0)
        #expect(Set(term.meetings.prefix(3).compactMap(\.courseID)).count == 1)
        #expect(term.meetings[0].note == "教学备注\n考试时间：另行通知")
        #expect(first.timeCount == 1 && first.sectionCount == 2)
    }

    @Test func reimportRetainsTermSettingsCourseIdentityUserEditsAndRelatedData() throws {
        let base = try folder(), root = base.appendingPathComponent("Library")
        let repo = try LibraryRepository(root: root)
        let first = try repo.importUndergraduateTimetable(schedule([course()]))
        var term = try #require(repo.state.timetableTerms.first)
        term.weekOneMonday = try academicDate("2026-08-30T16:00:00Z") // Monday in Shanghai
        term.weekCount = 24
        term.sectionTimes = [TimetableSectionTime(section: 1, startMinute: 480, endMinute: 525), TimetableSectionTime(section: 2, startMinute: 535, endMinute: 580)]
        try repo.saveTimetableTerm(term)
        var linked = try #require(repo.state.courses.first)
        linked.name = "自定义课程名"; linked.teacher = "自定义教师"; linked.colorHex = "#8058A1"
        try repo.saveCourse(linked)
        let task = StudyTask(title: "数学作业", courseID: linked.id)
        try repo.saveTask(task)
        let source = base.appendingPathComponent("note.txt")
        try Data("保留笔记".utf8).write(to: source)
        _ = try repo.importFiles(urls: [source], courseID: linked.id, category: "笔记", copy: true)
        let material = try #require(repo.state.materials.first)
        _ = try repo.importUndergraduateTimetable(schedule([course(code: "OTHER")], name: "其他学期"))
        let other = try #require(repo.state.timetableTerms.last)
        var updated = course()
        updated.teacher = "教务系统更新教师"
        let second = try repo.importUndergraduateTimetable(schedule([updated, course(weekday: 3, start: 3)], name: "  \(term.name)  "))
        #expect(second.termID == first.termID)
        #expect(second.coursesCreated == 0)
        #expect(second.meetingsImported == 2)
        let replaced = try #require(repo.state.timetableTerms.first)
        #expect(replaced.weekOneMonday == term.weekOneMonday)
        #expect(replaced.weekCount == 24)
        #expect(replaced.sectionTimes == term.sectionTimes)
        #expect(replaced.meetings.allSatisfy { $0.courseID == linked.id })
        #expect(repo.state.courses.first { $0.id == linked.id } == linked)
        #expect(repo.state.materials == [material])
        #expect(repo.state.tasks.first?.id == task.id)
        #expect(repo.state.timetableTerms.last == other)
        #expect(try Data(contentsOf: repo.resolveURL(material)) == Data("保留笔记".utf8))
    }

    @Test func sameReimportIsStableAndExactExistingCourseIsReused() throws {
        let root = try folder(), repo = try LibraryRepository(root: root)
        let existing = Course(name: "高等数学", semester: "2026–2027 学年第一学期", teacher: "张老师")
        try repo.saveCourse(existing)
        let result = try repo.importUndergraduateTimetable(schedule([course(), course(weekday: 3)]))
        #expect(result.coursesCreated == 0)
        #expect(repo.state.timetableTerms.first?.meetings.allSatisfy { $0.courseID == existing.id } == true)
        let before = repo.state
        let again = try repo.importUndergraduateTimetable(schedule([course(), course(weekday: 3)]))
        #expect(again.coursesCreated == 0)
        #expect(repo.state == before)
        let backup = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json.bak")))
        #expect(backup == before)
    }

    @Test func deletingCourseDetachesSnapshotsAndDeletingTermPreservesCourseFilesAndTasks() throws {
        let repo = try LibraryRepository(root: folder())
        let imported = try repo.importUndergraduateTimetable(schedule([course()]))
        let linked = try #require(repo.state.courses.first)
        try repo.saveTask(StudyTask(title: "课后练习", courseID: linked.id))
        let before = try #require(repo.state.timetableTerms.first?.meetings.first)
        try repo.deleteCourse(id: linked.id)
        var detached = try #require(repo.state.timetableTerms.first?.meetings.first)
        #expect(detached.courseID == nil)
        detached.courseID = before.courseID
        #expect(detached == before)
        #expect(repo.state.tasks.first?.courseID == nil)
        _ = try repo.importUndergraduateTimetable(schedule([course()]))
        #expect(repo.state.courses.count == 1)
        try repo.deleteTimetableTerm(id: imported.termID)
        #expect(repo.state.timetableTerms.isEmpty)
        #expect(repo.state.courses.count == 1)
        #expect(repo.state.tasks.count == 1)
    }

    @Test func legacyLibrariesDecodeAndPersistWithoutSilentlyAcceptingNullTimetables() throws {
        let root = try folder()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryState())) as? [String: Any])
        json["schemaVersion"] = 1
        json.removeValue(forKey: "timetableTerms")
        let index = root.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: json).write(to: index)
        do {
            let repo = try LibraryRepository(root: root)
            #expect(repo.state.timetableTerms.isEmpty)
            _ = try repo.importUndergraduateTimetable(schedule([course()]))
        }
        do {
            let reopened = try LibraryRepository(root: root)
            #expect(reopened.state.timetableTerms.count == 1)
            #expect(reopened.state.timetableTerms.first?.meetings.count == 1)
        }
        json["timetableTerms"] = NSNull()
        try JSONSerialization.data(withJSONObject: json).write(to: index)
        #expect(throws: (any Error).self) { try LibraryRepository(root: root) }
    }

    @Test func versionOneMigrationWaitsForMutationThenWritesProtectedVersionFour() throws {
        let root = try folder(), index = root.appendingPathComponent("library.json")
        let existing = Course(name: "原有课程", semester: "旧学期")
        var legacy = LibraryState(); legacy.schemaVersion = 1; legacy.courses = [existing]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "timetableTerms")
        let original = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try original.write(to: index)
        do {
            let repo = try LibraryRepository(root: root)
            #expect(repo.state.schemaVersion == 6)
            #expect(repo.state.courses == [existing])
            #expect(repo.state.timetableTerms.isEmpty)
            #expect(try Data(contentsOf: index) == original)
        }
        #expect(try Data(contentsOf: index) == original)
        do {
            let repo = try LibraryRepository(root: root)
            _ = try repo.importUndergraduateTimetable(schedule([course()]))
            #expect(repo.state.schemaVersion == 6)
            #expect(repo.state.courses.contains(existing))
            #expect(try Data(contentsOf: root.appendingPathComponent("library.json.bak")) == original)
        }
        let persisted = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: index))
        #expect(persisted.schemaVersion == 6)
        #expect(persisted.timetableTerms.count == 1)
        let reopened = try LibraryRepository(root: root)
        #expect(reopened.state == persisted)
    }

    @Test func futureAndInvalidSchemaVersionsAreRejectedWithoutRewriting() throws {
        let root = try folder(), index = root.appendingPathComponent("library.json")
        for version in [0, 7, Int.max] {
            var state = LibraryState(); state.schemaVersion = version
            let bytes = try JSONEncoder().encode(state)
            try bytes.write(to: index)
            #expect(throws: (any Error).self) { try LibraryRepository(root: root) }
            #expect(try Data(contentsOf: index) == bytes)
        }
    }

    @Test func schoolCalendarUsesShanghaiMondayAndSemesterBounds() throws {
        let monday = try academicDate("2026-08-30T16:00:00Z")
        let term = TimetableTerm(name: "秋季", weekOneMonday: monday, weekCount: 2)
        #expect(term.week(containing: try academicDate("2026-08-30T15:59:59Z")) == nil)
        #expect(term.week(containing: monday) == 1)
        #expect(term.week(containing: try academicDate("2026-09-06T15:59:59Z")) == 1)
        #expect(term.week(containing: try academicDate("2026-09-06T16:00:00Z")) == 2)
        #expect(term.week(containing: try academicDate("2026-09-13T16:00:00Z")) == nil)
        #expect(term.date(week: 2, weekday: 1) == (try academicDate("2026-09-06T16:00:00Z")))
        #expect(term.date(week: 2, weekday: 7) == (try academicDate("2026-09-12T16:00:00Z")))
        #expect(term.date(week: 0, weekday: 1) == nil)
        #expect(term.date(week: 3, weekday: 1) == nil)
        #expect(term.date(week: 1, weekday: 8) == nil)
        #expect(TimetableTerm(name: "未设置").week(containing: monday) == nil)
    }

    @Test func firstMondayIsInferredFromTheScreenshotsEighthAcademicWeekInShanghai() throws {
        let reference = try academicDate("2026-10-14T04:00:00Z") // Screenshot: October 14, academic week 8.
        let expected = try academicDate("2026-08-23T16:00:00Z") // August 24 00:00 in Shanghai.
        let monday = try #require(TimetableTerm.firstMonday(referenceDate: reference, academicWeek: 8))
        #expect(monday == expected)
        let term = TimetableTerm(name: "2026 秋季", weekOneMonday: monday)
        #expect(term.week(containing: reference) == 8)
        #expect(term.date(week: 8, weekday: 3) == (try academicDate("2026-10-13T16:00:00Z")))
        // Sunday in UTC is already Monday in Shanghai; the academic week changes there.
        let shanghaiMonday = try academicDate("2026-10-11T16:00:00Z")
        let previousDay = shanghaiMonday.addingTimeInterval(-1)
        #expect(TimetableTerm.firstMonday(referenceDate: shanghaiMonday, academicWeek: 8) == expected)
        #expect(TimetableTerm.firstMonday(referenceDate: previousDay, academicWeek: 8) == (try academicDate("2026-08-16T16:00:00Z")))
        #expect(TimetableTerm.firstMonday(referenceDate: reference, academicWeek: 1) == shanghaiMonday)
    }

    @Test func firstMondayRejectsInvalidWeeksAndNonfiniteDates() throws {
        let reference = try academicDate("2026-10-14T04:00:00Z")
        for week in [Int.min, -1, 0, 61, Int.max] {
            #expect(TimetableTerm.firstMonday(referenceDate: reference, academicWeek: week) == nil)
        }
        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(TimetableTerm.firstMonday(referenceDate: Date(timeIntervalSinceReferenceDate: interval), academicWeek: 8) == nil)
        }
        let earliest = try #require(TimetableTerm.firstMonday(referenceDate: reference, academicWeek: 60))
        let term = TimetableTerm(name: "较长学期", weekOneMonday: earliest, weekCount: 60)
        #expect(term.week(containing: reference) == 60)
    }

    @Test func explicitlyChosenScreenshotTimesPersistWithoutChangingCourseOrMeetingIdentity() throws {
        let root = try folder()
        var saved: TimetableTerm?
        var originalCourses: [Course] = []
        do {
            let repo = try LibraryRepository(root: root)
            _ = try repo.importUndergraduateTimetable(schedule([course()]))
            let original = try #require(repo.state.timetableTerms.first)
            originalCourses = repo.state.courses
            #expect(original.sectionTimes.isEmpty) // Import does not silently apply the screenshot preset.
            var edited = original
            edited.weekOneMonday = TimetableTerm.firstMonday(referenceDate: try academicDate("2026-10-14T04:00:00Z"), academicWeek: 8)
            edited.sectionTimes = UndergraduateTimetableDefaults.sectionTimes
            try repo.saveTimetableTerm(edited)
            saved = edited
            #expect(repo.state.courses == originalCourses)
            #expect(repo.state.timetableTerms.first?.id == original.id)
            #expect(repo.state.timetableTerms.first?.meetings == original.meetings)
        }
        let reopened = try LibraryRepository(root: root)
        let term = try #require(reopened.state.timetableTerms.first)
        #expect(term == saved)
        #expect(reopened.state.courses == originalCourses)
        #expect(term.sectionTimes.map(\.section) == Array(1...11))
        #expect(term.sectionTimes.map(\.startMinute) == [480, 540, 610, 670, 840, 900, 970, 1030, 1110, 1170, 1230])
        #expect(term.sectionTimes.map(\.endMinute) == [530, 590, 660, 720, 890, 950, 1020, 1080, 1160, 1220, 1280])
    }

    @Test func invalidImportsNeverAlterMetadataOrExistingSemester() throws {
        let root = try folder(), repo = try LibraryRepository(root: root)
        _ = try repo.importUndergraduateTimetable(schedule([course()]))
        let before = repo.state, index = root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: index)
        var invalids = [course(weeks: []), course(weeks: [0]), course(weeks: [61]), course(weekday: 8), course(weekday: nil), course(start: 30, offset: 1), course(offset: -1), course(start: 0), course(start: Int.max)]
        var blank = course(); blank.name = " \n "; invalids.append(blank)
        for invalid in invalids {
            #expect(throws: (any Error).self) { try repo.importUndergraduateTimetable(schedule([invalid])) }
        }
        #expect(throws: (any Error).self) { try repo.importUndergraduateTimetable(schedule([])) }
        #expect(throws: (any Error).self) { try repo.importUndergraduateTimetable(schedule([course()], name: " ")) }
        #expect(repo.state == before)
        #expect(try Data(contentsOf: index) == bytes)
    }

    @Test func malformedPersistedLinksIDsWeeksAndClockSettingsAreRejected() throws {
        let root = try folder(), repo = try LibraryRepository(root: root)
        _ = try repo.importUndergraduateTimetable(schedule([course()]))
        let original = try #require(repo.state.timetableTerms.first)
        var variants: [TimetableTerm] = []
        var changed = original; changed.weekCount = 0; variants.append(changed)
        changed = original; changed.weekCount = 61; variants.append(changed)
        changed = original; changed.weekOneMonday = try academicDate("2026-09-01T00:00:00Z"); variants.append(changed)
        changed = original; changed.meetings.append(changed.meetings[0]); variants.append(changed)
        changed = original; changed.meetings[0].courseID = UUID(); variants.append(changed)
        changed = original; changed.meetings[0].weeks = [1, 1]; variants.append(changed)
        changed = original; changed.sectionTimes = [.init(section: 1, startMinute: 480, endMinute: 525), .init(section: 2, startMinute: 520, endMinute: 570)]; variants.append(changed)
        changed = original; changed.sectionTimes = [.init(section: 2, startMinute: 480, endMinute: 525), .init(section: 1, startMinute: 535, endMinute: 580)]; variants.append(changed)
        changed = original; changed.sectionTimes = [.init(section: 1, startMinute: 1_400, endMinute: 1_450)]; variants.append(changed)
        for invalid in variants { #expect(throws: (any Error).self) { try repo.saveTimetableTerm(invalid) } }
        #expect(repo.state.timetableTerms == [original])
        var conflicting = original; conflicting.id = UUID(); conflicting.meetings = []
        #expect(throws: (any Error).self) { try repo.saveTimetableTerm(conflicting) }
    }

    @Test func failedIndexWriteRollsBackImportedCoursesAndMeetings() throws {
        let root = try folder(), repo = try LibraryRepository(root: root)
        _ = try repo.importUndergraduateTimetable(schedule([course()]))
        let before = repo.state, index = root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: index)
        let backup = root.appendingPathComponent("library.json.bak")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try repo.importUndergraduateTimetable(schedule([course(code: "NEW")], name: "新增学期")) }
        #expect(repo.state == before)
        #expect(try Data(contentsOf: index) == bytes)
    }

    @Test func duplicateTermAndCrossTermMeetingIDsCannotLoadAndOriginalIndexIsPreserved() throws {
        let root = try folder()
        let first = TimetableTerm(name: "第一学期", meetings: [.init(title: "课程", weeks: [1], weekday: 1, startSection: 1, sectionCount: 1)])
        var state = LibraryState()
        state.timetableTerms = [first, first]
        let index = root.appendingPathComponent("library.json")
        var bytes = try JSONEncoder().encode(state)
        try bytes.write(to: index)
        #expect(throws: (any Error).self) { try LibraryRepository(root: root) }
        #expect(try Data(contentsOf: index) == bytes)
        var second = first; second.id = UUID(); second.name = "第二学期"
        state.timetableTerms = [first, second]
        bytes = try JSONEncoder().encode(state)
        try bytes.write(to: index)
        #expect(throws: (any Error).self) { try LibraryRepository(root: root) }
        #expect(try Data(contentsOf: index) == bytes)
    }

    @Test func portalJSONUsesSnakeCaseAndWarningsCanBeAbsent() throws {
        let data = Data(#"{"name":"本科秋季","courses":[{"name":"单节课","class_number":"001","teacher":"教师","weeks":[1,3],"week_time":7,"start_time":5,"time_count":0,"test_time":"期末","test_location":null}]}"#.utf8)
        let decoded = try JSONDecoder().decode(UndergraduateSchedule.self, from: data)
        #expect(decoded.warnings.isEmpty)
        #expect(decoded.courses.first?.classNumber == "001")
        #expect(decoded.courses.first?.endSection == 5)
        #expect(decoded.courses.first?.sectionCount == 1)
        #expect(decoded.courses.first?.displayPeriod == "周日 · 第 5 节")
    }
}
