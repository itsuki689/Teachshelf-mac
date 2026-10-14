import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

struct TimetableLayoutTests {
    @Test func overlapsShareColumnsWhileAdjacentClassesKeepFullWidth() {
        let first = TimetableMeeting(title: "长课程", weeks: [1], weekday: 1, startSection: 1, sectionCount: 4)
        let second = TimetableMeeting(title: "冲突课程", weeks: [1], weekday: 1, startSection: 2, sectionCount: 1)
        let third = TimetableMeeting(title: "复用空列", weeks: [1], weekday: 1, startSection: 3, sectionCount: 1)
        let later = TimetableMeeting(title: "之后课程", weeks: [1], weekday: 1, startSection: 5, sectionCount: 2)
        let placements = TimetableLayout.placements([later, second, first, third])
        #expect(placements.count == 4)
        let a = placements.first { $0.id == first.id }!
        let b = placements.first { $0.id == second.id }!
        let c = placements.first { $0.id == third.id }!
        #expect(a.lane != b.lane)
        #expect(b.lane == c.lane)
        #expect(a.laneCount == 2 && b.laneCount == 2 && c.laneCount == 2)
        #expect(placements.first { $0.id == later.id }?.laneCount == 1)
    }

    @Test func freeTimeDoesNotOccupyAGridCellAndDisplayDoesNotInventClockTimes() {
        let meeting = TimetableMeeting(title: "课程", weeks: [1], weekday: 3, startSection: 3, sectionCount: 2)
        let free = TimetableMeeting(title: "自主研习", weeks: [])
        var term = TimetableTerm(name: "学期", meetings: [meeting, free])
        #expect(TimetableLayout.placements(term.meetings).map(\.id) == [meeting.id])
        #expect(TimetableLayout.timeLabel(meeting, in: term) == nil)
        term.sectionTimes = [.init(section: 3, startMinute: 600, endMinute: 645), .init(section: 4, startMinute: 660, endMinute: 705)]
        #expect(TimetableLayout.timeLabel(meeting, in: term) == "10:00–11:45")
        #expect(TimetableLayout.weeksLabel([5, 1, 2, 3, 5, 7]) == "第 1–3、5、7 周")
    }

    @MainActor @Test func clockInputRejectsIncompleteOrImpossibleTimes() {
        #expect(TimetableSettingsSheet.parseClock("08:00") == 480)
        #expect(TimetableSettingsSheet.parseClock("8:45") == 525)
        #expect(TimetableSettingsSheet.parseClock("24:00") == nil)
        #expect(TimetableSettingsSheet.parseClock("24:00", allowDayEnd: true) == 1440)
        #expect(TimetableSettingsSheet.parseClock("24:01", allowDayEnd: true) == nil)
        #expect(TimetableSettingsSheet.parseClock("08:60") == nil)
        #expect(TimetableSettingsSheet.parseClock("8:5") == nil)
        #expect(TimetableSettingsSheet.parseClock("") == nil)
    }

    @MainActor @Test func openingCourseFromTimetableDoesNotKeepAnIncompatibleSemesterFilter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-course-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root)
        let course = Course(name: "数学", semester: "2026 秋季")
        try repo.saveCourse(course)
        let store = AppStore(repository: repo, remembersLocation: false)
        store.semester = "2025 秋季"
        store.navigate(to: .course(course.id))
        #expect(store.semester == course.semester)
        #expect(store.sidebarCourses.map(\.id) == [course.id])
    }
}
