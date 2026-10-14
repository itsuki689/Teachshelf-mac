import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

struct TimetableCalendarTests {
    private let calendar = TimetableTerm.academicCalendar
    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func coursesAppearOnlyOnTheirActualWeekAndWeekday() {
        let meeting = TimetableMeeting(title: "高等数学", weeks: [1, 3], weekday: 1, startSection: 3, sectionCount: 2)
        let term = TimetableTerm(name: "2026 秋季", weekOneMonday: date(2026, 9, 7), weekCount: 4, meetings: [meeting])
        #expect(TimetableCalendar.classes(on: date(2026, 9, 7), terms: [term]).map(\.meeting.id) == [meeting.id])
        #expect(TimetableCalendar.classes(on: date(2026, 9, 8), terms: [term]).isEmpty)
        #expect(TimetableCalendar.classes(on: date(2026, 9, 14), terms: [term]).isEmpty)
        #expect(TimetableCalendar.classes(on: date(2026, 9, 21), terms: [term]).count == 1)
        #expect(TimetableCalendar.classes(on: date(2026, 9, 6), terms: [term]).isEmpty)
        #expect(TimetableCalendar.classes(on: date(2026, 10, 5), terms: [term]).isEmpty)
    }

    @Test func missingSemesterDateAndFreeTimeNeverProduceCalendarEvents() {
        let scheduled = TimetableMeeting(title: "大学英语", weeks: [1], weekday: 1, startSection: 1, sectionCount: 1)
        let free = TimetableMeeting(title: "自主学习", weeks: [1], weekday: 0, startSection: 1, sectionCount: 1)
        let noSection = TimetableMeeting(title: "体育待安排", weeks: [1], weekday: 1)
        let unknownDate = TimetableTerm(name: "未设置开学日期", meetings: [scheduled])
        let term = TimetableTerm(name: "秋季", weekOneMonday: date(2026, 9, 7), meetings: [free, noSection])
        #expect(TimetableCalendar.classes(on: date(2026, 9, 7), terms: [unknownDate, term]).isEmpty)
    }

    @Test func sessionsStayDistinctAndCourseFilterAppliesAcrossTerms() {
        let firstID = UUID(), secondID = UUID()
        let late = TimetableMeeting(courseID: firstID, title: "数学习题课", weeks: [1], weekday: 1, startSection: 7, sectionCount: 1)
        let early = TimetableMeeting(courseID: firstID, title: "高等数学", weeks: [1], weekday: 1, startSection: 1, sectionCount: 2)
        let other = TimetableMeeting(courseID: secondID, title: "大学英语", weeks: [1], weekday: 1, startSection: 3, sectionCount: 2)
        let first = TimetableTerm(name: "主修", weekOneMonday: date(2026, 9, 7), meetings: [late, early])
        let second = TimetableTerm(name: "辅修", weekOneMonday: date(2026, 9, 7), meetings: [other])
        let events = TimetableCalendar.classes(on: date(2026, 9, 7), terms: [first, second])
        #expect(events.map(\.meeting.id) == [early.id, other.id, late.id])
        #expect(Set(events.map(\.id)).count == 3)
        #expect(TimetableCalendar.classes(on: date(2026, 9, 7), terms: [first, second], courseID: firstID).map(\.meeting.id) == [early.id, late.id])
    }

    @Test func actualClockTimeRequiresBothSectionBoundaries() {
        let meeting = TimetableMeeting(title: "线性代数", weeks: [1], weekday: 1, startSection: 3, sectionCount: 2)
        let times = [TimetableSectionTime(section: 3, startMinute: 610, endMinute: 660),
                     TimetableSectionTime(section: 4, startMinute: 670, endMinute: 720)]
        #expect(TimetableCalendar.timeLabel(for: meeting, sectionTimes: times) == "10:10–12:00")
        #expect(TimetableCalendar.timeLabel(for: meeting, sectionTimes: Array(times.prefix(1))) == nil)
        #expect(TimetableCalendar.timeLabel(for: meeting, sectionTimes: []) == nil)
        let term = TimetableTerm(name: "秋季", weekOneMonday: date(2026, 9, 7), sectionTimes: times, meetings: [meeting])
        let event = TimetableCalendar.classes(on: date(2026, 9, 7), terms: [term]).first
        #expect(event?.sectionLabel == "第 3–4 节")
        #expect(event?.timeLabel == "10:10–12:00")
    }

    @Test func aSingleCancellationIsExcludedWithoutHidingOtherWeeksOrSameDayClasses() {
        let lecture = TimetableMeeting(title: "计算系统基础 II", weeks: [8, 9], weekday: 2, startSection: 3, sectionCount: 2)
        let evening = TimetableMeeting(title: "晚间课程", weeks: [8, 9], weekday: 2, startSection: 9, sectionCount: 3)
        var term = TimetableTerm(name: "2026 秋季", weekOneMonday: date(2026, 8, 24), meetings: [lecture, evening])
        term.cancellations = [TimetableCancellation(meetingID: lecture.id, date: date(2026, 10, 13), title: lecture.title)]
        #expect(TimetableCalendar.classes(on: date(2026, 10, 13, hour: 12), terms: [term]).map(\.meeting.id) == [evening.id])
        #expect(TimetableCalendar.classes(on: date(2026, 10, 20), terms: [term]).map(\.meeting.id) == [lecture.id, evening.id])
        term.cancellations = []
        #expect(TimetableCalendar.classes(on: date(2026, 10, 13), terms: [term]).map(\.meeting.id) == [lecture.id, evening.id])
    }

    @Test func dateProjectionUsesNanjingCivilDayRatherThanUTC() {
        let monday = date(2026, 9, 7)
        let term = TimetableTerm(name: "秋季", weekOneMonday: monday, meetings: [
            TimetableMeeting(title: "早课", weeks: [1], weekday: 1, startSection: 1, sectionCount: 1)
        ])
        // Monday 00:00 in Nanjing is still Sunday in UTC and in the Americas.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(utc.component(.weekday, from: monday) == 1)
        #expect(TimetableCalendar.classes(on: monday.addingTimeInterval(60), terms: [term]).count == 1)
        #expect(TimetableCalendar.classes(on: monday.addingTimeInterval(-60), terms: [term]).isEmpty)
    }
}
