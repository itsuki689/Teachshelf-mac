import Foundation
import SwiftUI
import TeachshelfCore

@MainActor enum ScheduleEventEditing {
    static func handleKey(_ press: KeyPress, store: AppStore, fixedEditing: Bool) -> KeyPress.Result {
        guard !press.modifiers.contains(.command), !press.modifiers.contains(.control),
              store.scheduleSelection.timePreview == nil,
              let event = selected(in: store), canEdit(event, fixedEditing: fixedEditing) else { return .ignored }
        switch press.key {
        case .upArrow: nudge(event, minutes: -10, store: store, fixedEditing: fixedEditing)
        case .downArrow: nudge(event, minutes: 10, store: store, fixedEditing: fixedEditing)
        case .leftArrow: nudge(event, days: -1, store: store, fixedEditing: fixedEditing)
        case .rightArrow: nudge(event, days: 1, store: store, fixedEditing: fixedEditing)
        default:
            if press.characters == "-" { nudge(event, minutes: -1, store: store, fixedEditing: fixedEditing) }
            else if press.characters == "+" || press.characters == "=" { nudge(event, minutes: 1, store: store, fixedEditing: fixedEditing) }
            else { return .ignored }
        }
        return .handled
    }

    static func selected(in store: AppStore) -> PlanDisplayEvent? {
        let selection = store.scheduleSelection
        return ScheduleData.weekDays(in: store.state, selection: selection).flatMap {
            ScheduleData.planEvents(on: $0, in: store.state, selection: selection)
        }.first { $0.id == selection.selectedEventID }
    }

    static func range(of event: PlanDisplayEvent) -> PlanTimeRange? {
        guard !event.isAllDay, !event.isDeadline else { return nil }
        let begin: Date, end: Date
        switch event.source {
        case .plan(let occurrence):
            begin = occurrence.task.startsAt
            end = occurrence.task.endsAt ?? begin.addingTimeInterval(1800)
        case .course:
            guard let endDate = event.endDate else { return nil }
            begin = event.date; end = endDate
        }
        let day = PlanCalendar.calendar.startOfDay(for: event.date)
        let startMinute = Int((begin.timeIntervalSince(day) / 60).rounded())
        let endMinute = Int((end.timeIntervalSince(day) / 60).rounded())
        return PlanTimeRange(start: startMinute, end: endMinute)
    }

    static func canEdit(_ event: PlanDisplayEvent, fixedEditing: Bool) -> Bool {
        range(of: event) != nil && canSelect(event, fixedEditing: fixedEditing)
    }

    static func canSelect(_ event: PlanDisplayEvent, fixedEditing: Bool) -> Bool {
        !event.isFixed || fixedEditing
    }

    @discardableResult static func select(_ event: PlanDisplayEvent, in store: AppStore, fixedEditing: Bool) -> Bool {
        guard canSelect(event, fixedEditing: fixedEditing) else { return false }
        let selection = store.scheduleSelection
        selection.timePreview = nil
        selection.setDate(event.date)
        selection.selectedEventID = event.id
        return true
    }

    static func clearLockedSelection(in store: AppStore, fixedEditing: Bool) {
        guard let event = selected(in: store), !canSelect(event, fixedEditing: fixedEditing) else { return }
        store.scheduleSelection.selectedEventID = nil
        store.scheduleSelection.timePreview = nil
    }

    @discardableResult static func apply(_ range: PlanTimeRange, to event: PlanDisplayEvent, on day: Date,
                                         store: AppStore, fixedEditing: Bool) -> Bool {
        guard !store.isBusy, canEdit(event, fixedEditing: fixedEditing) else { return false }
        if PlanCalendar.calendar.isDate(day, inSameDayAs: event.date), range == Self.range(of: event) { return false }
        let saved: Bool
        switch event.source {
        case .plan(let occurrence):
            saved = store.changePlan(id: occurrence.task.id, label: "调整《\(event.title)》本次时间") {
                try $0.setPlanOccurrenceTime(id: occurrence.task.id, originalDate: occurrence.originalDate, day: day, range: range)
            }
        case .course(let course):
            saved = store.changeTimetable(termID: course.termID, label: "调整《\(event.title)》本次时间") {
                try $0.rescheduleTimetableClass(termID: course.termID, meetingID: course.meeting.id,
                    originalDate: course.originalDate, to: day, startSection: course.meeting.startSection,
                    sectionCount: course.meeting.sectionCount, classroom: course.meeting.classroom,
                    startMinute: range.start, endMinute: range.end)
            }
        }
        if saved {
            store.scheduleSelection.setDate(day)
            store.scheduleSelection.selectedEventID = event.id
        }
        return saved
    }

    static func nudge(_ event: PlanDisplayEvent, minutes: Int = 0, days: Int = 0,
                       edge: PlanTimeEdge? = nil, store: AppStore, fixedEditing: Bool) {
        guard let current = range(of: event), canEdit(event, fixedEditing: fixedEditing) else { return }
        let updated: PlanTimeRange?
        if let edge {
            let value = (edge == .start ? current.start : current.end) + minutes
            updated = current.resized(edge, to: value, snapping: 1)
        } else { updated = current.shifted(by: minutes) }
        guard let updated,
              let day = PlanCalendar.calendar.date(byAdding: .day, value: days, to: event.date) else { return }
        apply(updated, to: event, on: day, store: store, fixedEditing: fixedEditing)
    }
}
