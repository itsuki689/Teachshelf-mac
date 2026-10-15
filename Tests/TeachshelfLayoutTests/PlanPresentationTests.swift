import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor struct PlanPresentationTests {
    private let calendar = TimetableTerm.academicCalendar
    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func monthDefaultsToDeadlineChildrenWhileWeekKeepsIndependentExecution() {
        let plan = StudyTask(title: "报告", startsAt: date(14, 18), deadline: date(16, 22), isAllDay: false,
                             hasExecutionTime: true, endsAt: date(14, 19), deadlineIsAllDay: false)
        var state = LibraryState(); state.tasks = [plan]
        let selection = ScheduleSelection(selectedDate: date(14))
        #expect(ScheduleData.planEvents(on: date(14), in: state, selection: selection).count == 1)
        #expect(ScheduleData.planEvents(on: date(14), in: state, selection: selection, forMonth: true).isEmpty)
        let due = ScheduleData.planEvents(on: date(16), in: state, selection: selection, forMonth: true)
        #expect(due.count == 1)
        #expect(due.first?.isDeadline == true)
        #expect(due.first?.isFixed == true)
        #expect(due.first?.planOccurrence?.task.id == plan.id)
        state.tasks[0].showInMonth = true
        #expect(ScheduleData.planEvents(on: date(14), in: state, selection: selection, forMonth: true).first?.isFixed == false)
    }

    @Test func importedLessonsOnlyEnterMonthAfterAnExplicitChoice() {
        let meeting = TimetableMeeting(title: "课程", weeks: [1], weekday: 3, startSection: 1, sectionCount: 2)
        let term = TimetableTerm(name: "秋季", weekOneMonday: date(12), meetings: [meeting])
        var state = LibraryState(); state.timetableTerms = [term]
        let selection = ScheduleSelection(selectedDate: date(14)); selection.reconcile(state)
        #expect(ScheduleData.planEvents(on: date(14), in: state, selection: selection).count == 1)
        #expect(ScheduleData.planEvents(on: date(14), in: state, selection: selection, forMonth: true).isEmpty)
        state.timetableTerms[0].meetings[0].showInMonth = true
        #expect(ScheduleData.planEvents(on: date(14), in: state, selection: selection, forMonth: true).first?.isFixed == true)
    }

    @Test func sourceFiltersSeparateAnActivityFromItsFixedDeadline() {
        let plan = StudyTask(title: "空", startsAt: date(14, 12), deadline: date(14, 20), isAllDay: false,
                             endsAt: date(14, 14), completionRequired: false)
        var state = LibraryState(); state.tasks = [plan]
        let selection = ScheduleSelection(selectedDate: date(14))
        selection.showsCourses = false
        let activities = ScheduleData.planEvents(on: date(14), in: state, selection: selection)
        #expect(activities.count == 1 && activities.first?.isDeadline == false)
        selection.showsCourses = true; selection.showsTasks = false
        let fixed = ScheduleData.planEvents(on: date(14), in: state, selection: selection)
        #expect(fixed.count == 1 && fixed.first?.isDeadline == true)
        selection.planFilter = .pending
        #expect(ScheduleData.planEvents(on: date(14), in: state, selection: selection).isEmpty)
    }

    @Test func dayMarkersKeepMultiDayAllDayPlansAndTheirDeadlinesInSeparateGroups() {
        let allDay = StudyTask(title: "全天活动", startsAt: date(14), deadline: date(15),
                               endsAt: date(16), completionRequired: false)
        let timed = StudyTask(title: "午休", startsAt: date(15, 12), isAllDay: false,
                              endsAt: date(15, 13), completionRequired: false)
        var state = LibraryState(); state.tasks = [allDay, timed]
        let selection = ScheduleSelection(selectedDate: date(15))
        let events = ScheduleData.planEvents(on: date(15), in: state, selection: selection)
        #expect(events.filter { $0.daySection == .allDay }.map(\.title) == ["全天活动"])
        #expect(events.filter { $0.daySection == .deadlines }.map(\.title) == ["全天活动"])
        #expect(events.filter { $0.daySection == .timed }.map(\.title) == ["午休"])
        selection.showsCourses = false
        #expect(ScheduleData.planEvents(on: date(15), in: state, selection: selection).allSatisfy { $0.daySection != .deadlines })
        #expect(ScheduleData.planEvents(on: date(16), in: state, selection: selection).isEmpty)
    }

    @Test func clickingDayMarkerKeepsFiltersAndNavigatesToItsSectionOnlyForThatDay() {
        let state = LibraryState()
        let selection = ScheduleSelection(selectedDate: date(14))
        selection.planFilter = .pending
        selection.showAgenda(on: date(15, 23), section: .deadlines, in: state)
        #expect(selection.mode == .agenda)
        #expect(selection.selectedDate == date(15))
        #expect(selection.agendaFocus == .deadlines)
        #expect(selection.planFilter == .pending)
        selection.setDate(date(16))
        #expect(selection.agendaFocus == nil)
        selection.showAgenda(on: date(15), section: .allDay, in: state)
        #expect(selection.agendaFocus == .allDay)
        selection.setMode(.week, in: state)
        #expect(selection.agendaFocus == nil)
    }

    @Test func planUndoPreservesUnrelatedEditsAndRejectsAChangedTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-undo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let plan = StudyTask(title: "原计划", startsAt: date(14, 12), endsAt: date(14, 13))
        let unrelated = StudyTask(title: "另一个计划", startsAt: date(15))
        try repository.saveTask(plan); try repository.saveTask(unrelated)
        let store = AppStore(repository: repository, remembersLocation: false)
        #expect(store.changePlan(id: plan.id, label: "移动计划") {
            try $0.movePlanOccurrence(id: plan.id, originalDate: plan.startsAt, isDeadline: false, to: date(14, 15))
        })
        var later = unrelated; later.title = "后来改名"
        try repository.saveTask(later); store.reload()
        #expect(store.canUndoPlanChange)
        store.undoPlanChange()
        #expect(store.state.tasks.first { $0.id == plan.id }?.startsAt == plan.startsAt)
        #expect(store.state.tasks.first { $0.id == unrelated.id }?.title == "后来改名")
        #expect(store.changePlan(id: plan.id, label: "再次移动") {
            try $0.movePlanOccurrence(id: plan.id, originalDate: plan.startsAt, isDeadline: false, to: date(16, 15))
        })
        var changed = try #require(repository.state.tasks.first { $0.id == plan.id }); changed.title = "后续编辑"
        try repository.saveTask(changed); store.reload()
        #expect(!store.canUndoPlanChange)
    }
    @Test func singleOccurrenceFiltersUseItsEffectiveCourseAndCompletionState() {
        let a = Course(name: "A"), b = Course(name: "B")
        var plan = StudyTask(title: "每周学习", courseID: a.id, startsAt: date(14, 18),
                             endsAt: date(14, 19), repeatRule: .init(frequency: .weekly))
        var changed = plan; changed.courseID = b.id; changed.completionRequired = false
        plan.exceptions = [.init(originalDate: date(21, 18), details: PlanDetails(changed, comparedTo: plan))]
        var state = LibraryState(); state.courses = [a, b]; state.tasks = [plan]
        let selection = ScheduleSelection(selectedDate: date(21))
        selection.courseID = b.id
        #expect(ScheduleData.planEvents(on: date(21), in: state, selection: selection).count == 1)
        selection.courseID = a.id
        #expect(ScheduleData.planEvents(on: date(21), in: state, selection: selection).isEmpty)
        selection.courseID = nil; selection.planFilter = .pending
        #expect(ScheduleData.planEvents(on: date(21), in: state, selection: selection).isEmpty)
        plan.exceptions[0].cancelledAt = Date(); state.tasks = [plan]
        selection.planFilter = .cancelled
        #expect(ScheduleData.planEvents(on: date(14), in: state, selection: selection).isEmpty)
        #expect(ScheduleData.filteredPlans(in: state, selection: selection).count == 1)
    }

}
