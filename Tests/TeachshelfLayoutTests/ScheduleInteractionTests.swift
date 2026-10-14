import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor struct ScheduleInteractionTests {
    private let calendar = TimetableTerm.academicCalendar
    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    @Test func dropsRespectTheLastTeachingDayAndKeepMultiSectionCoursesInsideTheGrid() {
        let term = TimetableTerm(name: "秋季", weekOneMonday: date(8, 24), weekCount: 18, endDate: date(12, 25))
        let days = (21...27).map { date(12, $0) }
        var grid = ScheduleDragGrid(labelWidth: 82, columnWidth: 90, rowHeight: 65, sectionCount: 11, days: days)
        let friday = grid.target(at: CGPoint(x: 82 + 4 * 90 + 10, y: 710), grabOffsetY: 5, duration: 3, term: term)
        #expect(friday?.date == date(12, 25))
        #expect(friday?.startSection == 9)
        #expect(friday?.sectionCount == 3)
        #expect(grid.target(at: CGPoint(x: 82 + 5 * 90 + 10, y: 100), grabOffsetY: 5, duration: 2, term: term) == nil)
        #expect(grid.target(at: CGPoint(x: 40, y: 100), grabOffsetY: 5, duration: 2, term: term) == nil)
        #expect(grid.target(at: CGPoint(x: CGFloat.infinity, y: 100), grabOffsetY: 5, duration: 2, term: term) == nil)
        grid.visibleRect = CGRect(x: 0, y: 130, width: grid.width, height: 200)
        #expect(grid.target(at: CGPoint(x: 100, y: 100), grabOffsetY: 5, duration: 2, term: term) == nil)
        #expect(grid.target(at: CGPoint(x: 100, y: 200), grabOffsetY: 5, duration: 2, term: term) != nil)
        #expect(grid.target(at: CGPoint(x: 100, y: 400), grabOffsetY: 5, duration: 2, term: term) == nil)
    }

    @Test func selectingTheLastWeekFromASundayClampsToTheConfirmedFriday() {
        var state = LibraryState()
        state.timetableTerms = [TimetableTerm(name: "秋季", weekOneMonday: date(8, 24), weekCount: 18, endDate: date(12, 25))]
        let selection = ScheduleSelection(selectedDate: date(10, 18))
        selection.reconcile(state)
        selection.setWeek(18, in: state)
        #expect(selection.selectedDate == date(12, 25))
        #expect(selection.week(in: state) == 18)
    }

    @Test func movingToTheSameCoursesNextWeekKeepsTwoEventsAndSeparateConflictLanes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Schedule-interaction-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let meeting = TimetableMeeting(title: "计算系统基础", weeks: [8, 9], weekday: 2, startSection: 3, sectionCount: 2)
        let term = TimetableTerm(name: "秋季", weekOneMonday: date(8, 24), weekCount: 18, endDate: date(12, 25), meetings: [meeting])
        try repository.saveTimetableTerm(term)
        let originalID = try #require(TimetableCalendar.classes(on: date(10, 13), terms: [term]).first?.id)
        try repository.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: date(10, 13),
            to: date(10, 20), startSection: 3, sectionCount: 2, classroom: "临时教室")
        let events = TimetableCalendar.classes(on: date(10, 20), terms: repository.state.timetableTerms)
        #expect(events.count == 2)
        #expect(Set(events.map(\.id)).count == 2)
        #expect(events.first(where: { $0.rescheduleID != nil })?.id == originalID)
        let placements = ScheduleDragLayout.placements(events, dayIndex: 1)
        #expect(Set(placements.map(\.lane)) == [0, 1])
        #expect(placements.allSatisfy { $0.laneCount == 2 })
    }

    @Test func undoRestoresTheTimetableWhileKeepingLaterCourseEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Schedule-undo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        var course = Course(name: "数学", semester: "秋季")
        try repository.saveCourse(course)
        let meeting = TimetableMeeting(courseID: course.id, title: course.name, weeks: [8, 9], weekday: 2, startSection: 3, sectionCount: 2)
        let term = TimetableTerm(name: "秋季", weekOneMonday: date(8, 24), meetings: [meeting])
        try repository.saveTimetableTerm(term)
        let store = AppStore(repository: repository, remembersLocation: false)
        #expect(store.changeTimetable(termID: term.id, label: "移动课程") {
            try $0.rescheduleTimetableClass(termID: term.id, meetingID: meeting.id, originalDate: date(10, 13),
                to: date(10, 14), startSection: 5, sectionCount: 2, classroom: "新教室")
        })
        course.name = "保留用户修改后的课程名"
        try repository.saveCourse(course); store.reload()
        #expect(store.canUndoTimetableChange)
        store.undoTimetableChange()
        #expect(repository.state.timetableTerms == [term])
        #expect(repository.state.courses == [course])
        #expect(!store.canUndoTimetableChange)
    }

    @Test func laterSemesterChangesPreventAnOldUndoFromOverwritingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Schedule-undo-conflict-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let meeting = TimetableMeeting(title: "数学", weeks: [8, 9], weekday: 2, startSection: 3, sectionCount: 2)
        let term = TimetableTerm(name: "秋季", weekOneMonday: date(8, 24), meetings: [meeting])
        try repository.saveTimetableTerm(term)
        let store = AppStore(repository: repository, remembersLocation: false)
        #expect(store.changeTimetable(termID: term.id, label: "移除时段") {
            try $0.deleteTimetableMeeting(termID: term.id, meetingID: meeting.id)
        })
        var updated = try #require(repository.state.timetableTerms.first)
        updated.weekCount = 21
        try repository.saveTimetableTerm(updated); store.reload()
        #expect(!store.canUndoTimetableChange)
        store.undoTimetableChange()
        #expect(repository.state.timetableTerms == [updated])
    }
}
