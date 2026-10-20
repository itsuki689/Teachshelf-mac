import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
final class TimetableCancellationTests {
    private var folders: [URL] = []
    deinit { for folder in folders { try? FileManager.default.removeItem(at: folder) } }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TimetableCancellationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private func course(classroom: String = "仙Ⅰ-101", code: String = "CS002", start: Int = 3) -> UndergraduateCourse {
        UndergraduateCourse(name: code == "OTHER" ? "大学英语" : "计算系统基础 II", classroom: classroom, classNumber: code, teacher: "教师",
                            weeks: Array(1...12), weekday: 2, startSection: start, timeCount: 1)
    }

    private func schedule(_ courses: [UndergraduateCourse]) -> UndergraduateSchedule {
        UndergraduateSchedule(name: "2026 秋季", courses: courses)
    }

    private func fixture() throws -> (LibraryRepository, TimetableTerm, TimetableMeeting, TimetableMeeting) {
        let repo = try LibraryRepository(root: folder())
        _ = try repo.importUndergraduateTimetable(schedule([course(), course(code: "OTHER", start: 1)]))
        var term = try #require(repo.state.timetableTerms.first)
        term.weekOneMonday = try date("2026-08-23T16:00:00Z")
        try repo.saveTimetableTerm(term)
        return (repo, term, term.meetings[0], term.meetings[1])
    }

    @Test func cancellationAffectsOnlyOneOccurrenceAndRestoreIsIdempotent() throws {
        let (repo, original, meeting, other) = try fixture()
        let occurrence = try date("2026-10-13T03:00:00Z") // Week 8, Tuesday in Shanghai.
        let midnight = try date("2026-10-12T16:00:00Z")
        try repo.cancelTimetableClass(termID: original.id, meetingID: meeting.id, on: occurrence, reason: "  本次停课  ")
        var term = try #require(repo.state.timetableTerms.first)
        let cancellation = try #require(term.cancellations.first)
        #expect(term.cancellations.count == 1)
        #expect(cancellation.date == midnight)
        #expect(cancellation.title == meeting.title)
        #expect(cancellation.reason == "本次停课")
        #expect(term.meetings == original.meetings)
        #expect(term.isCancelled(meeting, on: midnight))
        #expect(term.isCancelled(meeting, on: midnight.addingTimeInterval(86_399)))
        #expect(!term.isCancelled(meeting, on: midnight.addingTimeInterval(-1)))
        #expect(!term.isCancelled(meeting, on: midnight.addingTimeInterval(7 * 86_400)))
        #expect(!term.isCancelled(other, on: occurrence))
        #expect(other.courseID != meeting.courseID)
        let index = repo.root.appendingPathComponent("library.json"), backup = repo.root.appendingPathComponent("library.json.bak")
        let bytes = try Data(contentsOf: index), backupBytes = try Data(contentsOf: backup)
        try repo.cancelTimetableClass(termID: original.id, meetingID: meeting.id, on: midnight, reason: "重复操作")
        #expect(repo.state.timetableTerms.first?.cancellations == [cancellation])
        #expect(try Data(contentsOf: index) == bytes)
        #expect(try Data(contentsOf: backup) == backupBytes)
        try repo.restoreTimetableClass(termID: original.id, cancellationID: cancellation.id)
        term = try #require(repo.state.timetableTerms.first)
        #expect(term.cancellations.isEmpty)
        #expect(!term.isCancelled(meeting, on: occurrence))
        #expect(term.meetings == original.meetings)
        let restored = try Data(contentsOf: index)
        try repo.restoreTimetableClass(termID: original.id, cancellationID: cancellation.id)
        #expect(try Data(contentsOf: index) == restored)
        let savedBackup = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: backup))
        #expect(savedBackup.timetableTerms.first?.cancellations == [cancellation])
    }

    @Test func cancellationRequiresAnExistingScheduledOccurrenceAndNeverChangesInvalidInput() throws {
        let (repo, original, meeting, _) = try fixture()
        let occurrence = try date("2026-10-13T03:00:00Z")
        let free = TimetableMeeting(title: "自由课程", weeks: [])
        var term = original; term.meetings.append(free)
        term.meetings[0].weeks = [8]
        try repo.saveTimetableTerm(term)
        let undated = TimetableTerm(name: "未设置日期", meetings: [TimetableMeeting(title: "待定日期课", weeks: [1], weekday: 2, startSection: 1, sectionCount: 1)])
        try repo.saveTimetableTerm(undated)
        let before = repo.state, index = repo.root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: index)
        for invalidDate in [try date("2026-10-12T03:00:00Z"), try date("2026-10-20T03:00:00Z"), try date("2027-10-12T03:00:00Z"), Date(timeIntervalSinceReferenceDate: .infinity), Date(timeIntervalSinceReferenceDate: .nan)] {
            #expect(throws: (any Error).self) { try repo.cancelTimetableClass(termID: term.id, meetingID: meeting.id, on: invalidDate) }
        }
        #expect(throws: (any Error).self) { try repo.cancelTimetableClass(termID: term.id, meetingID: free.id, on: occurrence) }
        #expect(throws: (any Error).self) { try repo.cancelTimetableClass(termID: term.id, meetingID: UUID(), on: occurrence) }
        #expect(throws: (any Error).self) { try repo.cancelTimetableClass(termID: UUID(), meetingID: meeting.id, on: occurrence) }
        #expect(throws: (any Error).self) { try repo.cancelTimetableClass(termID: undated.id, meetingID: undated.meetings[0].id, on: occurrence) }
        #expect(throws: (any Error).self) { try repo.restoreTimetableClass(termID: UUID(), cancellationID: UUID()) }
        #expect(repo.state == before)
        #expect(try Data(contentsOf: index) == bytes)
        #expect(!undated.isCancelled(undated.meetings[0], on: Date(timeIntervalSinceReferenceDate: .nan)))
    }

    @Test func reimportRemapsUniqueChangedSessionsAndRetainsDetachedHistory() throws {
        let (repo, original, meeting, other) = try fixture()
        let occurrence = try date("2026-10-13T03:00:00Z")
        try repo.cancelTimetableClass(termID: original.id, meetingID: meeting.id, on: occurrence, reason: "停课通知")
        try repo.cancelTimetableClass(termID: original.id, meetingID: other.id, on: occurrence, reason: "另一课堂")
        let cancellations = try #require(repo.state.timetableTerms.first?.cancellations)
        let originalCourses = repo.state.courses
        var updated = course(classroom: "仙Ⅰ-202"); updated.teacher = "更新教师"
        _ = try repo.importUndergraduateTimetable(schedule([updated]))
        let term = try #require(repo.state.timetableTerms.first), replacement = try #require(term.meetings.first)
        #expect(replacement.id != meeting.id)
        #expect(replacement.courseID == meeting.courseID)
        #expect(term.cancellations.count == 2)
        #expect(term.cancellations[0].id == cancellations[0].id)
        #expect(term.cancellations[0].meetingID == replacement.id)
        #expect(term.cancellations[0].date == cancellations[0].date)
        #expect(term.cancellations[0].reason == "停课通知")
        #expect(term.cancellations[1] == cancellations[1])
        #expect(term.isCancelled(replacement, on: occurrence))
        #expect(repo.state.courses == originalCourses)
        if let courseID = replacement.courseID { try repo.deleteCourse(id: courseID) }
        #expect(repo.state.timetableTerms.first?.cancellations == term.cancellations)
        try repo.restoreTimetableClass(termID: term.id, cancellationID: cancellations[1].id)
        #expect(repo.state.timetableTerms.first?.cancellations.map(\.id) == [cancellations[0].id])
    }

    @Test func ambiguousSessionChangesDoNotApplyAnExceptionToTheWrongClassroom() throws {
        let (repo, original, meeting, _) = try fixture()
        let occurrence = try date("2026-10-13T03:00:00Z")
        try repo.cancelTimetableClass(termID: original.id, meetingID: meeting.id, on: occurrence)
        let cancellation = try #require(repo.state.timetableTerms.first?.cancellations.first)
        _ = try repo.importUndergraduateTimetable(schedule([course(classroom: "仙Ⅰ-102"), course(classroom: "仙Ⅰ-103")]))
        let term = try #require(repo.state.timetableTerms.first)
        #expect(term.cancellations == [cancellation])
        #expect(term.meetings.count == 2)
        #expect(term.meetings.allSatisfy { !term.isCancelled($0, on: occurrence) })
    }

    @Test func cancellationValidationRejectsMalformedRecordsButPreservesOrphanHistory() throws {
        let (repo, original, meeting, _) = try fixture()
        let day = try date("2026-10-12T16:00:00Z")
        let valid = TimetableCancellation(meetingID: UUID(), date: day, title: "保留的旧课堂", reason: "重导后历史")
        var orphan = original; orphan.cancellations = [valid]
        try repo.saveTimetableTerm(orphan)
        let before = repo.state, index = repo.root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: index)
        var duplicate = orphan; duplicate.cancellations.append(valid)
        var invalidTitle = orphan; invalidTitle.cancellations = [.init(meetingID: meeting.id, date: day, title: " \n ")]
        var invalidDate = orphan; invalidDate.cancellations = [.init(meetingID: meeting.id, date: Date(timeIntervalSinceReferenceDate: .infinity), title: meeting.title)]
        for malformed in [duplicate, invalidTitle, invalidDate] {
            #expect(throws: (any Error).self) { try repo.saveTimetableTerm(malformed) }
        }
        let other = TimetableTerm(name: "另一学期", cancellations: [valid])
        #expect(throws: (any Error).self) { try repo.saveTimetableTerm(other) }
        #expect(repo.state == before)
        #expect(try Data(contentsOf: index) == bytes)
    }

    @Test func missingCancellationFieldDecodesAsEmptyButExplicitNullIsRejected() throws {
        let term = TimetableTerm(name: "旧版学期")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(term)) as? [String: Any])
        object.removeValue(forKey: "cancellations")
        let decoded = try JSONDecoder().decode(TimetableTerm.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.cancellations.isEmpty)
        object["cancellations"] = NSNull()
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TimetableTerm.self, from: JSONSerialization.data(withJSONObject: object)) }
        object.removeValue(forKey: "cancellations"); object.removeValue(forKey: "meetings")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TimetableTerm.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func versionTwoMigrationWaitsForFirstMutationAndPreservesTheOriginalBackup() throws {
        let root = try folder(), index = root.appendingPathComponent("library.json")
        let meeting = TimetableMeeting(title: "计算系统基础 II", weeks: [8], weekday: 2, startSection: 3, sectionCount: 2)
        let term = TimetableTerm(name: "2026 秋季", weekOneMonday: try date("2026-08-23T16:00:00Z"), meetings: [meeting])
        var state = LibraryState(); state.schemaVersion = 2; state.timetableTerms = [term]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var terms = try #require(object["timetableTerms"] as? [[String: Any]])
        terms[0].removeValue(forKey: "cancellations"); object["timetableTerms"] = terms
        let original = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try original.write(to: index)
        do {
            let repo = try LibraryRepository(root: root)
            #expect(repo.state.schemaVersion == 6)
            #expect(repo.state.timetableTerms.first?.cancellations.isEmpty == true)
            #expect(try Data(contentsOf: index) == original)
        }
        do {
            let repo = try LibraryRepository(root: root)
            try repo.cancelTimetableClass(termID: term.id, meetingID: meeting.id, on: try date("2026-10-13T03:00:00Z"))
            #expect(repo.state.schemaVersion == 6)
            #expect(try Data(contentsOf: root.appendingPathComponent("library.json.bak")) == original)
        }
        let reopened = try LibraryRepository(root: root)
        #expect(reopened.state.timetableTerms.first?.cancellations.count == 1)
        #expect(reopened.state.timetableTerms.first?.meetings == [meeting])
        let persisted = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: index))
        #expect(persisted.schemaVersion == 6)
        #expect(persisted == reopened.state)
    }

    @Test func failedCancellationWriteRollsBackWithoutChangingRecurringSessions() throws {
        let (repo, term, meeting, _) = try fixture()
        let before = repo.state, index = repo.root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: index)
        let backup = repo.root.appendingPathComponent("library.json.bak")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try repo.cancelTimetableClass(termID: term.id, meetingID: meeting.id, on: try date("2026-10-13T03:00:00Z"))
        }
        #expect(repo.state == before)
        #expect(try Data(contentsOf: index) == bytes)
    }
}
