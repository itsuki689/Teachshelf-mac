import Foundation
import TeachshelfCore

enum ScheduleDaySection: String, CaseIterable, Identifiable {
    case allDay, deadlines, timed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .allDay: return "全天计划"
        case .deadlines: return "当天截止"
        case .timed: return "时间安排"
        }
    }
}

struct PlanDisplayEvent: Identifiable, Hashable {
    enum Source: Hashable {
        case course(TimetableCalendar.DayClass)
        case plan(PlanOccurrence)
    }
    let source: Source
    let date: Date
    let endDate: Date?
    var id: String {
        switch source { case .course(let event): return "course-\(event.id)"; case .plan(let event): return "plan-\(event.id)" }
    }
    var title: String {
        switch source { case .course(let event): return event.meeting.title; case .plan(let event): return event.task.title }
    }
    var isDeadline: Bool { if case .plan(let event) = source { return event.isDeadline }; return false }
    var isFixed: Bool { if case .plan(let event) = source { return event.isFixed }; return true }
    var isAllDay: Bool { if case .plan(let event) = source { return event.isAllDay }; return false }
    var daySection: ScheduleDaySection { isDeadline ? .deadlines : (isAllDay ? .allDay : .timed) }
    var colorHex: String? {
        switch source { case .plan(let event): return event.task.colorHex; case .course(let event): return event.meeting.colorHex }
    }
    var courseID: UUID? {
        switch source { case .course(let event): return event.meeting.courseID; case .plan(let event): return event.task.courseID }
    }
    var location: String {
        switch source { case .course(let event): return event.meeting.classroom; case .plan(let event): return event.task.location }
    }
    var planOccurrence: PlanOccurrence? { if case .plan(let event) = source { return event }; return nil }
    var isCompleted: Bool { planOccurrence?.task.isCompleted ?? false }
    var completionRequired: Bool { planOccurrence?.task.completionRequired ?? false }
    var timeLabel: String {
        if case .course(let event) = source { return event.timeLabel ?? event.sectionLabel }
        if isDeadline { return isAllDay ? "当日截止" : "\(TimetableCalendar.formatted(date, template: "HHmm")) 截止" }
        if isAllDay { return "全天" }
        let begin = TimetableCalendar.formatted(date, template: "HHmm")
        return endDate.map {
            let nextDay = TimetableCalendar.calendar.date(byAdding: .day, value: 1, to: TimetableCalendar.calendar.startOfDay(for: date))
            return "\(begin)–\($0 == nextDay ? "24:00" : TimetableCalendar.formatted($0, template: "HHmm"))"
        } ?? begin
    }
}

extension ScheduleData {
    static func planEvents(on day: Date, in state: LibraryState, selection: ScheduleSelection,
                           forMonth: Bool = false) -> [PlanDisplayEvent] {
        var result: [PlanDisplayEvent] = []
        if selection.showsCourses && selection.planFilter == .all {
            for event in classes(on: day, in: state, selection: selection) {
                guard let term = state.timetableTerms.first(where: { $0.id == event.termID }) else { continue }
                let master = term.meetings.first { $0.id == event.meeting.id }
                guard !forMonth || (master?.showInMonth ?? event.meeting.showInMonth) == true else { continue }
                let calendar = TimetableTerm.academicCalendar
                let range = event.meeting.timeRange(sectionTimes: term.sectionTimes)
                let date = range.flatMap { calendar.date(byAdding: .minute, value: $0.start, to: calendar.startOfDay(for: day)) } ?? event.day
                let endDate = range.flatMap { calendar.date(byAdding: .minute, value: $0.end, to: calendar.startOfDay(for: day)) }
                result.append(PlanDisplayEvent(source: .course(event), date: date, endDate: endDate))
            }
        }
        for event in PlanCalendar.events(on: day, plans: state.tasks) {
            guard matchesPlan(event.task, in: state, selection: selection) else { continue }
            guard event.isFixed ? selection.showsCourses : selection.showsTasks else { continue }
            guard !forMonth || event.isDeadline || event.task.showInMonth else { continue }
            result.append(PlanDisplayEvent(source: .plan(event), date: event.date, endDate: event.endDate))
        }
        return result.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
    }

    static func filteredPlans(in state: LibraryState, selection: ScheduleSelection) -> [StudyTask] {
        state.tasks.filter { plan in
            matchesPlan(plan, in: state, selection: selection) || plan.exceptions.contains {
                matchesPlan(PlanCalendar.snapshot(of: plan, originalDate: $0.originalDate), in: state, selection: selection)
            }
        }
    }

    private static func matchesPlan(_ plan: StudyTask, in state: LibraryState, selection: ScheduleSelection) -> Bool {
        let courseIDs = Set(selection.filteredCourses(in: state).map(\.id))
            guard !plan.isArchived,
                  selection.courseID == nil || plan.courseID == selection.courseID,
                  selection.term(in: state) == nil || plan.courseID.map(courseIDs.contains) != false else { return false }
            switch selection.planFilter {
            case .all: return true
            case .pending: return plan.completionRequired && !plan.isCompleted && plan.cancelledAt == nil
            case .unplanned: return !plan.hasExecutionTime && plan.cancelledAt == nil
            case .completed: return plan.isCompleted
            case .cancelled: return plan.cancelledAt != nil
            }
    }
}
