import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor struct PlanTimeInteractionTests {
    private let calendar = PlanCalendar.calendar
    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func arrowAndPrecisionCommandsKeepSelectionDeadlineAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-keys-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let plan = StudyTask(title: "午休", startsAt: date(15, 12), deadline: date(15, 22), isAllDay: false,
                             endsAt: date(15, 13), completionRequired: false)
        try repository.savePlan(plan)
        let store = AppStore(repository: repository, remembersLocation: false)
        store.scheduleSelection.setDate(date(15))
        let event = try #require(ScheduleData.planEvents(on: date(15), in: store.state, selection: store.scheduleSelection).first { !$0.isDeadline })
        store.scheduleSelection.selectedEventID = event.id
        ScheduleEventEditing.nudge(event, minutes: 10, store: store, fixedEditing: false)
        let moved = try #require(ScheduleEventEditing.selected(in: store))
        #expect(moved.date == date(15, 12, 10) && moved.endDate == date(15, 13, 10))
        ScheduleEventEditing.nudge(moved, minutes: -1, edge: .start, store: store, fixedEditing: false)
        #expect(ScheduleEventEditing.selected(in: store)?.date == date(15, 12, 9))
        store.undoPlanChange()
        let restored = try #require(ScheduleEventEditing.selected(in: store))
        #expect(restored.date == date(15, 12, 10))
        ScheduleEventEditing.nudge(restored, days: 1, store: store, fixedEditing: false)
        #expect(store.scheduleSelection.selectedDate == date(16))
        #expect(ScheduleEventEditing.selected(in: store)?.date == date(16, 12, 10))
        #expect(store.state.tasks.first?.deadline == date(15, 22))
    }

    @Test func fixedCourseMinuteChangesRequireSwitchAndRemainOneOffAfterReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("course-minutes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let meeting = TimetableMeeting(title: "课程", weeks: [1, 2], weekday: 4, startSection: 1, sectionCount: 2)
        let term = TimetableTerm(name: "秋季", weekOneMonday: date(12), weekCount: 2,
                                 sectionTimes: UndergraduateTimetableDefaults.sectionTimes, meetings: [meeting])
        try repository.saveTimetableTerm(term)
        let store = AppStore(repository: repository, remembersLocation: false)
        store.scheduleSelection.setDate(date(15))
        let event = try #require(ScheduleData.planEvents(on: date(15), in: store.state, selection: store.scheduleSelection).first)
        ScheduleEventEditing.nudge(event, minutes: 10, store: store, fixedEditing: false)
        #expect(store.state.timetableTerms.first?.reschedules.isEmpty == true)
        ScheduleEventEditing.nudge(event, minutes: 10, store: store, fixedEditing: true)
        let changed = try #require(ScheduleData.planEvents(on: date(15), in: store.state, selection: store.scheduleSelection).first)
        #expect(changed.date == date(15, 8, 10) && changed.endDate == date(15, 10))
        #expect(changed.timeLabel == "08:10–10:00")
        #expect(ScheduleData.planEvents(on: date(22), in: store.state, selection: store.scheduleSelection).first?.date == date(22, 8))
        try repository.setTimetableMeetingColor(termID: term.id, meetingID: meeting.id, hex: "#AE567C")
        #expect(try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json"))).timetableTerms.first?.reschedules.first?.meeting.colorHex == "#AE567C")
        #expect(try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json"))).timetableTerms.first?.reschedules.first?.meeting.startMinuteOverride == 490)
    }

    @Test func multiDayPlansCannotBeTruncatedByInlineTimeEditing() {
        let plan = StudyTask(title: "跨天", startsAt: date(15, 23), isAllDay: false, endsAt: date(16, 1))
        let occurrence = PlanCalendar.events(on: date(15), plans: [plan])[0]
        let event = PlanDisplayEvent(source: .plan(occurrence), date: occurrence.date, endDate: occurrence.endDate)
        #expect(ScheduleEventEditing.range(of: event) == nil)
        #expect(!ScheduleEventEditing.canEdit(event, fixedEditing: true))
    }

    @Test func lockedFixedEventsCannotReplaceActivitySelectionAndRelockingClearsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-selection-lock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let activity = StudyTask(title: "自主安排", startsAt: date(15, 12), deadline: date(15, 22), isAllDay: false, endsAt: date(15, 13))
        try repository.savePlan(activity)
        try repository.savePlan(StudyTask(title: "固定活动", startsAt: date(15, 14), isAllDay: false, origin: .fixed, endsAt: date(15, 15)))
        try repository.saveTimetableTerm(TimetableTerm(name: "秋季", weekOneMonday: date(12), weekCount: 2,
            sectionTimes: UndergraduateTimetableDefaults.sectionTimes,
            meetings: [TimetableMeeting(title: "课程", weeks: [1], weekday: 4, startSection: 1, sectionCount: 2)]))
        let store = AppStore(repository: repository, remembersLocation: false)
        let selection = store.scheduleSelection
        selection.setDate(date(15))
        let before = store.state
        let events = ScheduleData.planEvents(on: date(15), in: store.state, selection: selection)
        let manual = try #require(events.first { !$0.isFixed })
        let fixed = events.filter(\.isFixed)
        #expect(fixed.count == 3) // Imported course, fixed activity and generated DDL.
        for event in fixed {
            #expect(ScheduleEventEditing.select(manual, in: store, fixedEditing: false))
            #expect(!ScheduleEventEditing.select(event, in: store, fixedEditing: false))
            #expect(selection.selectedEventID == manual.id)
            #expect(ScheduleEventEditing.select(event, in: store, fixedEditing: true))
            #expect(selection.selectedEventID == event.id)
            selection.timePreview = PlanTimeRange(start: 480, end: 590)
            ScheduleEventEditing.clearLockedSelection(in: store, fixedEditing: false)
            #expect(selection.selectedEventID == nil && selection.timePreview == nil)
        }
        #expect(ScheduleEventEditing.select(manual, in: store, fixedEditing: true))
        ScheduleEventEditing.clearLockedSelection(in: store, fixedEditing: false)
        #expect(selection.selectedEventID == manual.id)
        #expect(store.state == before)
    }

    @Test func anExclusiveMidnightEndDisplaysAs24AndDoesNotSpillIntoTomorrow() {
        let plan = StudyTask(title: "当天结束", startsAt: date(15, 23), isAllDay: false, endsAt: date(16))
        let occurrence = PlanCalendar.events(on: date(15), plans: [plan])[0]
        let event = PlanDisplayEvent(source: .plan(occurrence), date: occurrence.date, endDate: occurrence.endDate)
        #expect(event.timeLabel == "23:00–24:00")
        #expect(ScheduleEventEditing.range(of: event)?.end == 1440)
        #expect(PlanCalendar.events(on: date(16), plans: [plan]).isEmpty)
    }
}
