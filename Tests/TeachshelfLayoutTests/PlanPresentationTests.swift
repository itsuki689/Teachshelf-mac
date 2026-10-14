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
