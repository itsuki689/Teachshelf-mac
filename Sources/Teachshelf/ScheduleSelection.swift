import Combine
import Foundation
import TeachshelfCore

enum ScheduleMode: String, CaseIterable, Identifiable {
    case month, week, agenda

    var id: String { rawValue }
    var title: String {
        switch self {
        case .month: return "月"
        case .week: return "周"
        case .agenda: return "日"
        }
    }
}

enum SchedulePlanFilter: String, CaseIterable, Identifiable {
    case all = "全部计划", pending = "待完成", unplanned = "待安排", completed = "已完成", cancelled = "已取消"
    var id: String { rawValue }
}

/// One civil date drives every schedule view. Academic weeks without a start
/// date remain virtual, so they cannot accidentally acquire real task dates.
@MainActor
final class ScheduleSelection: ObservableObject {
    @Published private(set) var selectedDate: Date
    @Published private(set) var termID: UUID?
    @Published private(set) var floatingWeek = 1
    @Published var courseID: UUID?
    @Published var mode: ScheduleMode
    @Published var showsCourses = true
    @Published var showsTasks = true
    @Published var planFilter: SchedulePlanFilter = .all

    private var calendar: Calendar { TimetableTerm.academicCalendar }

    init(selectedDate: Date = Date(), mode: ScheduleMode = .week) {
        let validDate = selectedDate.timeIntervalSinceReferenceDate.isFinite ? selectedDate : Date()
        self.selectedDate = TimetableTerm.academicCalendar.startOfDay(for: validDate)
        self.mode = mode
    }

    func setDate(_ date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        selectedDate = calendar.startOfDay(for: date)
    }

    func setTerm(_ id: UUID?, in state: LibraryState) {
        termID = state.timetableTerms.first(where: { $0.id == id })?.id
        reconcile(state)
    }

    func setWeek(_ week: Int, in state: LibraryState) {
        guard let term = term(in: state) else { return }
        let clamped = min(max(1, week), max(1, term.weekCount))
        if term.weekOneMonday == nil {
            floatingWeek = clamped
        } else {
            let weekday = (calendar.component(.weekday, from: selectedDate) + 5) % 7 + 1
            if let date = term.date(week: clamped, weekday: weekday) { setDate(date) }
            else if let monday = term.date(week: clamped, weekday: 1) {
                setDate(term.endDate.map { max(monday, $0) } ?? monday)
            }
        }
    }

    func setMode(_ mode: ScheduleMode, in state: LibraryState) {
        self.mode = mode
        reconcile(state)
    }

    func shift(_ offset: Int, in state: LibraryState) {
        if mode == .week, let term = term(in: state), term.weekOneMonday == nil {
            let shifted = floatingWeek.addingReportingOverflow(offset)
            setWeek(shifted.overflow ? (offset > 0 ? Int.max : Int.min) : shifted.partialValue, in: state)
            return
        }
        let component: Calendar.Component = mode == .month ? .month : (mode == .agenda ? .day : .weekOfYear)
        if let date = calendar.date(byAdding: component, value: offset, to: selectedDate) { setDate(date) }
    }

    func today(in state: LibraryState) {
        setDate(Date())
        reconcile(state)
    }

    func reconcile(_ state: LibraryState) {
        if let termID, !state.timetableTerms.contains(where: { $0.id == termID }) { self.termID = nil }
        if mode == .week, termID == nil { termID = bestTerm(in: state)?.id }
        floatingWeek = min(max(1, floatingWeek), max(1, term(in: state)?.weekCount ?? 1))
        if let courseID, !filteredCourses(in: state).contains(where: { $0.id == courseID }) { self.courseID = nil }
    }

    func term(in state: LibraryState) -> TimetableTerm? {
        state.timetableTerms.first(where: { $0.id == termID })
    }

    func week(in state: LibraryState) -> Int? {
        guard let term = term(in: state) else { return nil }
        if term.weekOneMonday == nil { return min(max(1, floatingWeek), max(1, term.weekCount)) }
        return term.week(containing: selectedDate)
    }

    func filteredCourses(in state: LibraryState) -> [Course] {
        let selectedTerm = term(in: state)
        let linkedCourseIDs = Set((selectedTerm?.meetings.compactMap(\.courseID) ?? []) +
                                  (selectedTerm?.reschedules.compactMap(\.meeting.courseID) ?? []))
        return state.courses.filter { selectedTerm == nil || $0.semester == selectedTerm?.name || linkedCourseIDs.contains($0.id) }
            .sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
            }
    }

    private func bestTerm(in state: LibraryState) -> TimetableTerm? {
        let sorted = state.timetableTerms.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedDescending
        }
        return sorted.first(where: { $0.week(containing: selectedDate) != nil }) ?? sorted.first
    }
}

@MainActor
enum ScheduleData {
    private static var calendar: Calendar { TimetableTerm.academicCalendar }

    static func tasks(on day: Date, in state: LibraryState, selection: ScheduleSelection) -> [StudyTask] {
        guard selection.showsTasks else { return [] }
        let hasSelectedTerm = selection.term(in: state) != nil
        let courseIDs = Set(selection.filteredCourses(in: state).map(\.id))
        return state.tasks.filter { task in
            !task.isArchived && task.showOnCalendar &&
            (selection.courseID == nil || task.courseID == selection.courseID) &&
            (!hasSelectedTerm || task.courseID.map(courseIDs.contains) != false) &&
            calendar.isDate(task.deadline ?? task.startsAt, inSameDayAs: day)
        }.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            let firstDate = $0.deadline ?? $0.startsAt, secondDate = $1.deadline ?? $1.startsAt
            if firstDate != secondDate { return firstDate < secondDate }
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    static func classes(on day: Date, in state: LibraryState, selection: ScheduleSelection) -> [TimetableCalendar.DayClass] {
        guard selection.showsCourses else { return [] }
        let terms = state.timetableTerms.filter { selection.termID == nil || $0.id == selection.termID }
        return TimetableCalendar.classes(on: day, terms: terms, courseID: selection.courseID)
    }

    static func weekDays(in state: LibraryState, selection: ScheduleSelection) -> [Date] {
        if let term = selection.term(in: state), term.weekOneMonday == nil { return [] }
        let day = calendar.startOfDay(for: selection.selectedDate)
        let offset = (calendar.component(.weekday, from: day) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -offset, to: day) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    static func agendaDays(selection: ScheduleSelection) -> [Date] {
        [selection.selectedDate]
    }

    /// These are explicitly undated items, never events projected onto a day.
    static func freeMeetings(in state: LibraryState, selection: ScheduleSelection) -> [TimetableMeeting] {
        guard selection.showsCourses, let term = selection.term(in: state) else { return [] }
        let week = selection.week(in: state)
        return term.meetings.filter { meeting in
            !meeting.isScheduled && (selection.courseID == nil || meeting.courseID == selection.courseID) &&
            (meeting.weeks.isEmpty || week.map(meeting.weeks.contains) == true)
        }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }
}
