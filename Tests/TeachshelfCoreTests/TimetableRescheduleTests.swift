import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
final class TimetableRescheduleTests {
    private var folders: [URL] = []
    private let calendar = TimetableTerm.academicCalendar
    deinit { for folder in folders { try? FileManager.default.removeItem(at: folder) } }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TimetableRescheduleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }
    private func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private func course(_ name: String = "计算系统基础 II", code: String = "CS002", start: Int = 3, room: String = "仙Ⅰ-101", weeks: [Int] = Array(1...18)) -> UndergraduateCourse {
        UndergraduateCourse(name: name, classroom: room, classNumber: code, teacher: "教师", weeks: weeks, weekday: 2, startSection: start, timeCount: 1)
    }
    private func schedule(_ courses: [UndergraduateCourse]) -> UndergraduateSchedule { .init(name: "2026 秋季", courses: courses) }
    private func fixture() throws -> (LibraryRepository, TimetableTerm, TimetableMeeting, TimetableMeeting) {
        let repo = try LibraryRepository(root: folder())
        _ = try repo.importUndergraduateTimetable(schedule([course(), course("大学英语", code: "EN001", start: 1)]))
        var term = try #require(repo.state.timetableTerms.first)
        term.weekOneMonday = date(8, 24); term.weekCount = 18; term.endDate = date(12, 25)
        term.sectionTimes = UndergraduateTimetableDefaults.sectionTimes
        try repo.saveTimetableTerm(term)
        return (repo, term, term.meetings[0], term.meetings[1])
    }

    @Test func oneOccurrenceMovesAndRepeatedDraggingKeepsItsIdentityAndOrigin() throws {
        let (repo, original, meeting, other) = try fixture()
        let origin = date(10, 13), firstTarget = date(10, 14), nextTarget = date(10, 15)
        let originalOccurrence = try #require(original.occurrences(on: origin).first { $0.meeting.id == meeting.id })
        try repo.rescheduleTimetableClass(termID: original.id, meetingID: meeting.id, originalDate: origin.addingTimeInterval(1), to: firstTarget.addingTimeInterval(3600), startSection: 5, sectionCount: 3, classroom: "  仙Ⅱ-201  ")
        var term = try #require(repo.state.timetableTerms.first)
        let move = try #require(term.reschedules.first)
        let moved = try #require(term.occurrences(on: firstTarget).first)
        #expect(term.meetings == original.meetings)
        #expect(term.occurrences(on: origin).map(\.meeting.id) == [other.id])
        #expect(moved.id == originalOccurrence.id)
        #expect(moved.originalDate == origin && moved.date == firstTarget)
        #expect(moved.meeting.id == meeting.id && moved.meeting.weekday == 3)
        #expect(moved.meeting.startSection == 5 && moved.meeting.sectionCount == 3)
        #expect(moved.meeting.classroom == "仙Ⅱ-201")
        try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: origin, to: nextTarget, startSection: 7, sectionCount: 2, classroom: "仙Ⅲ-301")
        term = try #require(repo.state.timetableTerms.first)
        #expect(term.reschedules.count == 1)
        #expect(term.reschedules[0].id == move.id)
        #expect(term.reschedules[0].originalDate == origin)
        #expect(term.occurrences(on: firstTarget).isEmpty)
        #expect(term.occurrences(on: nextTarget).first?.id == originalOccurrence.id)
        let bytes = try Data(contentsOf: repo.root.appendingPathComponent("library.json"))
        try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: origin, to: nextTarget, startSection: 7, sectionCount: 2, classroom: "仙Ⅲ-301")
        #expect(try Data(contentsOf: repo.root.appendingPathComponent("library.json")) == bytes)
    }

    @Test func movingToAnotherWeekPreservesBothOccurrencesOfTheSameMeeting() throws {
        let (repo, term, meeting, _) = try fixture()
        let origin = date(10, 13), target = date(10, 20)
        try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: origin, to: target, startSection: 3, sectionCount: 2, classroom: meeting.classroom)
        let updated = try #require(repo.state.timetableTerms.first)
        let occurrences = updated.occurrences(on: target).filter { $0.meeting.id == meeting.id }
        #expect(occurrences.count == 2)
        #expect(Set(occurrences.map(\.id)).count == 2)
        #expect(Set(occurrences.map(\.originalDate)) == Set([origin, target]))
        #expect(occurrences.filter { $0.rescheduleID != nil }.count == 1)
        #expect(updated.occurrences(on: origin).allSatisfy { $0.meeting.id != meeting.id })
    }

    @Test func cancellingAMovedClassSavesAndRestoresItsArrangementBeforeRestoringThePattern() throws {
        let (repo, original, meeting, _) = try fixture()
        let origin = date(10, 13), target = date(10, 14)
        try repo.rescheduleTimetableClass(termID: original.id, meetingID: meeting.id, originalDate: origin, to: target, startSection: 5, sectionCount: 2, classroom: "临时教室")
        let move = try #require(repo.state.timetableTerms.first?.reschedules.first)
        try repo.cancelTimetableClass(termID: original.id, meetingID: meeting.id, on: origin, reason: "调课后停课")
        var term = try #require(repo.state.timetableTerms.first)
        let cancellation = try #require(term.cancellations.first)
        #expect(term.reschedules.isEmpty)
        #expect(cancellation.savedReschedule == move)
        #expect(term.occurrences(on: target).isEmpty)
        #expect(term.occurrences(on: origin).allSatisfy { $0.meeting.id != meeting.id })
        #expect(throws: (any Error).self) {
            try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: origin, to: target, startSection: 1, sectionCount: 2, classroom: "")
        }
        try repo.restoreTimetableClass(termID: term.id, cancellationID: cancellation.id)
        term = try #require(repo.state.timetableTerms.first)
        #expect(term.reschedules == [move])
        #expect(term.occurrences(on: target).first?.rescheduleID == move.id)
        try repo.restoreTimetableReschedule(termID: term.id, rescheduleID: move.id)
        term = try #require(repo.state.timetableTerms.first)
        #expect(term.reschedules.isEmpty)
        #expect(term.occurrences(on: target).isEmpty)
        #expect(term.occurrences(on: origin).contains { $0.meeting.id == meeting.id && $0.rescheduleID == nil })
    }

    @Test func classroomAndLengthCanChangeInPlaceAndReturningToTheMasterRemovesTheOverride() throws {
        let (repo, term, meeting, _) = try fixture()
        let origin = date(10, 13)
        try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: origin, to: origin, startSection: meeting.startSection, sectionCount: 1, classroom: "改教室")
        var updated = try #require(repo.state.timetableTerms.first)
        #expect(updated.occurrences(on: origin).filter { $0.meeting.id == meeting.id }.count == 1)
        #expect(updated.reschedules.first?.meeting.sectionCount == 1)
        try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: origin, to: origin, startSection: meeting.startSection, sectionCount: meeting.sectionCount, classroom: meeting.classroom)
        updated = try #require(repo.state.timetableTerms.first)
        #expect(updated.reschedules.isEmpty)
        #expect(updated.occurrences(on: origin).first { $0.meeting.id == meeting.id }?.meeting == meeting)
    }

    @Test func wholeSessionEditsPreserveIdentityAndDeleteKeepsCoursesFilesTasksAndUndoSnapshot() throws {
        let (repo, original, meeting, other) = try fixture()
        let source = repo.root.appendingPathComponent("课程笔记.txt")
        try Data("课程资料".utf8).write(to: source)
        _ = try repo.importFiles(urls: [source], courseID: meeting.courseID, category: "笔记", copy: true)
        try repo.saveTask(StudyTask(title: "相关作业", courseID: meeting.courseID))
        try repo.rescheduleTimetableClass(termID: original.id, meetingID: meeting.id, originalDate: date(10, 13), to: date(10, 14), startSection: 5, sectionCount: 2, classroom: "移动教室")
        var edited = meeting; edited.weekday = 4; edited.startSection = 7; edited.classroom = "新固定教室"
        try repo.updateTimetableMeeting(termID: original.id, meeting: edited)
        var term = try #require(repo.state.timetableTerms.first)
        #expect(term.meetings.first { $0.id == meeting.id } == edited)
        #expect(term.reschedules.first?.meeting.classroom == "移动教室")
        #expect(term.occurrences(on: date(10, 15)).allSatisfy { $0.meeting.id != meeting.id })
        #expect(term.occurrences(on: date(10, 22)).contains { $0.meeting.id == meeting.id && $0.rescheduleID == nil })
        let beforeDelete = repo.state
        try repo.deleteTimetableMeeting(termID: term.id, meetingID: meeting.id)
        term = try #require(repo.state.timetableTerms.first)
        #expect(term.meetings == [other])
        #expect(term.reschedules.isEmpty)
        #expect(repo.state.courses == beforeDelete.courses)
        #expect(repo.state.materials == beforeDelete.materials)
        #expect(repo.state.tasks == beforeDelete.tasks)
        #expect(try Data(contentsOf: repo.resolveURL(beforeDelete.materials[0])) == Data("课程资料".utf8))
        try repo.saveTimetableTerm(beforeDelete.timetableTerms[0]) // AppStore undo restores this exact snapshot.
        #expect(repo.state == beforeDelete)
    }

    @Test func reimportRetainsEndDateAndRemapsMovesIncludingSavedCancellationSnapshots() throws {
        let (repo, original, meeting, other) = try fixture()
        let origin = date(10, 13), target = date(10, 14)
        try repo.rescheduleTimetableClass(termID: original.id, meetingID: meeting.id, originalDate: origin, to: target, startSection: 5, sectionCount: 2, classroom: "本地教室")
        try repo.rescheduleTimetableClass(termID: original.id, meetingID: other.id, originalDate: origin, to: target, startSection: 1, sectionCount: 2, classroom: "英语教室")
        try repo.cancelTimetableClass(termID: original.id, meetingID: other.id, on: origin)
        let before = try #require(repo.state.timetableTerms.first)
        _ = try repo.importUndergraduateTimetable(schedule([course(room: "教务新教室"), course("大学英语", code: "EN001", start: 1, room: "英语新教室")]))
        let after = try #require(repo.state.timetableTerms.first)
        let newMeeting = try #require(after.meetings.first { $0.courseCode == "CS002" })
        let newOther = try #require(after.meetings.first { $0.courseCode == "EN001" })
        #expect(after.weekCount == 18 && after.endDate == date(12, 25))
        #expect(after.reschedules[0].id == before.reschedules[0].id)
        #expect(after.reschedules[0].meetingID == newMeeting.id)
        #expect(after.reschedules[0].meeting.id == newMeeting.id)
        #expect(after.reschedules[0].meeting.classroom == "本地教室")
        #expect(after.cancellations[0].meetingID == newOther.id)
        #expect(after.cancellations[0].savedReschedule?.meetingID == newOther.id)
        try repo.restoreTimetableClass(termID: after.id, cancellationID: after.cancellations[0].id)
        #expect(repo.state.timetableTerms.first?.occurrences(on: target).count == 2)
    }

    @Test func changingTheFixedWeekdayKeepsIndividualMovesAndCancellationsOnTheirAcademicWeeks() throws {
        let (repo, original, meeting, _) = try fixture()
        try repo.rescheduleTimetableClass(termID: original.id, meetingID: meeting.id, originalDate: date(10, 13), to: date(10, 14), startSection: 5, sectionCount: 2, classroom: "第八周临时教室")
        try repo.cancelTimetableClass(termID: original.id, meetingID: meeting.id, on: date(10, 20))
        try repo.rescheduleTimetableClass(termID: original.id, meetingID: meeting.id, originalDate: date(10, 27), to: date(10, 28), startSection: 7, sectionCount: 1, classroom: "第十周临时教室")
        try repo.cancelTimetableClass(termID: original.id, meetingID: meeting.id, on: date(10, 27))
        var edited = meeting; edited.weekday = 4
        try repo.updateTimetableMeeting(termID: original.id, meeting: edited)
        let term = try #require(repo.state.timetableTerms.first)
        #expect(term.reschedules[0].originalDate == date(10, 15))
        #expect(term.reschedules[0].date == date(10, 14))
        #expect(term.occurrences(on: date(10, 14)).filter { $0.meeting.id == meeting.id }.count == 1)
        #expect(term.occurrences(on: date(10, 15)).allSatisfy { $0.meeting.id != meeting.id })
        #expect(term.cancellations[0].date == date(10, 22))
        #expect(term.occurrences(on: date(10, 22)).allSatisfy { $0.meeting.id != meeting.id })
        let savedCancellation = term.cancellations[1]
        #expect(savedCancellation.date == date(10, 29))
        #expect(savedCancellation.savedReschedule?.originalDate == date(10, 29))
        #expect(savedCancellation.savedReschedule?.date == date(10, 28))
        try repo.restoreTimetableClass(termID: term.id, cancellationID: savedCancellation.id)
        let restored = try #require(repo.state.timetableTerms.first)
        #expect(restored.occurrences(on: date(10, 28)).filter { $0.meeting.id == meeting.id }.count == 1)
        #expect(restored.occurrences(on: date(10, 29)).allSatisfy { $0.meeting.id != meeting.id })
    }

    @Test func orphanMovesRemainVisibleCanMoveAgainAndCanBeCancelledAndFullyRestored() throws {
        let (repo, original, meeting, _) = try fixture()
        let origin = date(10, 13), target = date(10, 14)
        try repo.rescheduleTimetableClass(termID: original.id, meetingID: meeting.id, originalDate: origin, to: target, startSection: 5, sectionCount: 2, classroom: "保留本地教室")
        _ = try repo.importUndergraduateTimetable(schedule([course("大学英语", code: "EN001", start: 1)]))
        var term = try #require(repo.state.timetableTerms.first)
        #expect(!term.meetings.contains { $0.id == meeting.id })
        #expect(term.occurrences(on: target).first?.meeting.title == meeting.title)
        try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: origin, to: date(10, 15), startSection: 7, sectionCount: 1, classroom: "再次移动")
        let moved = try #require(repo.state.timetableTerms.first?.reschedules.first)
        try repo.cancelTimetableClass(termID: term.id, meetingID: meeting.id, on: origin)
        term = try #require(repo.state.timetableTerms.first)
        #expect(term.reschedules.isEmpty)
        let cancellation = try #require(term.cancellations.first)
        #expect(cancellation.savedReschedule == moved)
        try repo.restoreTimetableClass(termID: term.id, cancellationID: cancellation.id)
        #expect(repo.state.timetableTerms.first?.reschedules == [moved])
        #expect(repo.state.timetableTerms.first?.occurrences(on: date(10, 15)).first?.meeting.classroom == "再次移动")
    }

    @Test func deletingACourseDetachesActiveAndSavedMoveSnapshotsWithoutLosingLocalArrangements() throws {
        let (repo, term, meeting, _) = try fixture()
        try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: date(10, 13), to: date(10, 14), startSection: 5, sectionCount: 2, classroom: "第一周安排")
        try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: date(10, 20), to: date(10, 21), startSection: 7, sectionCount: 2, classroom: "第二周安排")
        try repo.cancelTimetableClass(termID: term.id, meetingID: meeting.id, on: date(10, 20))
        try repo.deleteCourse(id: #require(meeting.courseID))
        let updated = try #require(repo.state.timetableTerms.first)
        #expect(updated.reschedules.count == 1)
        #expect(updated.reschedules[0].meeting.courseID == nil)
        #expect(updated.cancellations[0].savedReschedule?.meeting.courseID == nil)
        #expect(updated.occurrences(on: date(10, 14)).first?.meeting.classroom == "第一周安排")
        try repo.restoreTimetableClass(termID: term.id, cancellationID: updated.cancellations[0].id)
        #expect(repo.state.timetableTerms.first?.occurrences(on: date(10, 21)).first?.meeting.classroom == "第二周安排")
    }

    @Test func semesterEndIncludesFridayAndExcludesTheFinalWeekendAcrossAllDateAPIs() throws {
        let (repo, original, _, _) = try fixture()
        var term = original
        term.meetings.append(TimetableMeeting(title: "最后一周周六课", weeks: [18], weekday: 6, startSection: 1, sectionCount: 1))
        term.meetings.append(TimetableMeeting(title: "最后一周周五课", weeks: [18], weekday: 5, startSection: 1, sectionCount: 1))
        term.endDate = date(12, 25, hour: 20)
        try repo.saveTimetableTerm(term)
        term = try #require(repo.state.timetableTerms.first)
        #expect(term.endDate == date(12, 25))
        #expect(term.week(containing: date(12, 25, hour: 23)) == 18)
        #expect(term.week(containing: date(12, 26)) == nil)
        #expect(term.date(week: 18, weekday: 5) == date(12, 25))
        #expect(term.date(week: 18, weekday: 6) == nil)
        #expect(term.date(week: 18, weekday: 7) == nil)
        #expect(term.occurrences(on: date(12, 25)).map(\.meeting.title) == ["最后一周周五课"])
        #expect(term.occurrences(on: date(12, 26)).isEmpty)
    }

    @Test func invalidTargetsSemesterEndsAndMalformedOverridesRollbackWithoutWrites() throws {
        let (repo, term, meeting, _) = try fixture()
        let before = repo.state, index = repo.root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: index)
        for target in [date(8, 23), date(12, 26), Date(timeIntervalSinceReferenceDate: .nan)] {
            #expect(throws: (any Error).self) { try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: date(10, 13), to: target, startSection: 3, sectionCount: 2, classroom: "") }
        }
        for sections in [(0, 2), (30, 2), (1, 0), (Int.max, Int.max)] {
            #expect(throws: (any Error).self) { try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: date(10, 13), to: date(10, 14), startSection: sections.0, sectionCount: sections.1, classroom: "") }
        }
        #expect(throws: (any Error).self) { try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: date(10, 14), to: date(10, 15), startSection: 3, sectionCount: 2, classroom: "") }
        for end in [date(8, 23), date(12, 18), date(12, 28), Date(timeIntervalSinceReferenceDate: .infinity)] {
            var invalid = term; invalid.endDate = end
            #expect(throws: (any Error).self) { try repo.saveTimetableTerm(invalid) }
        }
        var changed = meeting; changed.startSection = 30
        #expect(throws: (any Error).self) { try repo.updateTimetableMeeting(termID: term.id, meeting: changed) }
        var malformed = term
        malformed.reschedules = [.init(meetingID: meeting.id, originalDate: date(10, 13), date: date(10, 14), meeting: meeting)] // Snapshot weekday must match its target.
        #expect(throws: (any Error).self) { try repo.saveTimetableTerm(malformed) }
        #expect(repo.state == before)
        #expect(try Data(contentsOf: index) == bytes)
    }

    @Test func explicitEighteenWeekEndRejectsOverlongReimportsAndPreservesTheOriginalIndex() throws {
        let (repo, term, _, _) = try fixture()
        let before = repo.state, index = repo.root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: index)
        #expect(throws: (any Error).self) { try repo.importUndergraduateTimetable(schedule([course(weeks: Array(1...20))])) }
        #expect(repo.state == before)
        #expect(repo.state.timetableTerms.first?.endDate == term.endDate)
        #expect(try Data(contentsOf: index) == bytes)
        var withoutStart = term; withoutStart.weekOneMonday = nil
        try repo.saveTimetableTerm(withoutStart)
        #expect(repo.state.timetableTerms.first?.endDate == date(12, 25))
    }

    @Test func duplicateOverridesAreRejectedAndNonMidnightInputIsNormalizedOnTermSave() throws {
        let (repo, term, meeting, _) = try fixture()
        try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: date(10, 13), to: date(10, 14), startSection: 5, sectionCount: 2, classroom: "")
        var updated = try #require(repo.state.timetableTerms.first)
        var duplicate = updated.reschedules[0]; duplicate.id = UUID(); updated.reschedules.append(duplicate)
        #expect(throws: (any Error).self) { try repo.saveTimetableTerm(updated) }
        updated.reschedules.removeLast()
        updated.reschedules[0].date = date(10, 14, hour: 15)
        updated.reschedules[0].originalDate = date(10, 13, hour: 10)
        try repo.saveTimetableTerm(updated)
        let normalized = try #require(repo.state.timetableTerms.first?.reschedules.first)
        #expect(normalized.date == date(10, 14))
        #expect(normalized.originalDate == date(10, 13))
    }

    @Test func versionThreeMigrationDefersWritesAndPreservesMovesAndCancellationsAcrossReopenAndBackup() throws {
        let root = try folder(), index = root.appendingPathComponent("library.json")
        let meeting = TimetableMeeting(title: "计算系统基础 II", weeks: Array(1...18), weekday: 2, startSection: 3, sectionCount: 2)
        let cancellation = TimetableCancellation(meetingID: meeting.id, date: date(10, 13), title: meeting.title)
        let term = TimetableTerm(name: "2026 秋季", weekOneMonday: date(8, 24), weekCount: 18, meetings: [meeting], cancellations: [cancellation])
        var state = LibraryState(); state.schemaVersion = 3; state.timetableTerms = [term]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var terms = try #require(object["timetableTerms"] as? [[String: Any]])
        terms[0].removeValue(forKey: "endDate"); terms[0].removeValue(forKey: "reschedules"); object["timetableTerms"] = terms
        let original = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try original.write(to: index)
        do {
            let repo = try LibraryRepository(root: root)
            #expect(repo.state.schemaVersion == 4)
            #expect(repo.state.timetableTerms[0].endDate == nil && repo.state.timetableTerms[0].reschedules.isEmpty)
            #expect(repo.state.timetableTerms[0].cancellations == [cancellation])
            #expect(try Data(contentsOf: index) == original)
            try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: date(10, 20), to: date(10, 21), startSection: 5, sectionCount: 2, classroom: "迁移后安排")
            #expect(try Data(contentsOf: root.appendingPathComponent("library.json.bak")) == original)
            try repo.saveAppearance("dark")
        }
        let reopened = try LibraryRepository(root: root)
        #expect(reopened.state.schemaVersion == 4)
        #expect(reopened.state.timetableTerms[0].reschedules.count == 1)
        #expect(reopened.state.timetableTerms[0].cancellations == [cancellation])
        let backup = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json.bak")))
        #expect(backup.timetableTerms == reopened.state.timetableTerms)
    }

    @Test func missingNewFieldsDecodeWhileNullRescheduleArraysAreRejected() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(TimetableTerm(name: "旧学期"))) as? [String: Any])
        object.removeValue(forKey: "endDate"); object.removeValue(forKey: "reschedules")
        let decoded = try JSONDecoder().decode(TimetableTerm.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.endDate == nil && decoded.reschedules.isEmpty)
        object["reschedules"] = NSNull()
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TimetableTerm.self, from: JSONSerialization.data(withJSONObject: object)) }
        let cancellation = TimetableCancellation(meetingID: UUID(), date: date(10, 13), title: "旧停课")
        var cancelled = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cancellation)) as? [String: Any])
        cancelled.removeValue(forKey: "savedReschedule")
        let oldCancellation = try JSONDecoder().decode(TimetableCancellation.self, from: JSONSerialization.data(withJSONObject: cancelled))
        #expect(oldCancellation.savedReschedule == nil)
    }

    @Test func failedMovePersistenceLeavesAllRecurringAndLocalArrangementsUnchanged() throws {
        let (repo, term, meeting, _) = try fixture()
        let before = repo.state, index = repo.root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: index)
        let backup = repo.root.appendingPathComponent("library.json.bak")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try repo.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: date(10, 13), to: date(10, 14), startSection: 5, sectionCount: 2, classroom: "") }
        #expect(repo.state == before)
        #expect(try Data(contentsOf: index) == bytes)
    }
}
