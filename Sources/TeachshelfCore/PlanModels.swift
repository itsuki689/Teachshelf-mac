import Foundation

public enum PlanOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case activity, fixed
}

public enum PlanRepeatFrequency: String, Codable, CaseIterable, Hashable, Sendable {
    case daily, weekly, monthly
}

public struct PlanRepeatRule: Codable, Hashable, Sendable {
    public var frequency: PlanRepeatFrequency
    public var interval: Int
    /// Inclusive civil day in Asia/Shanghai.
    public var until: Date?
    public init(frequency: PlanRepeatFrequency, interval: Int = 1, until: Date? = nil) {
        self.frequency = frequency; self.interval = interval; self.until = until
    }
}

/// An exception is anchored to the original occurrence, never to its moved date.
/// Execution and deadline overrides are independent.
public enum PlanEditScope: String, Codable, CaseIterable, Hashable, Sendable {
    case thisOccurrence, thisAndFuture, all
}

public enum PlanDetailField: String, Codable, Hashable, Sendable {
    case title, content, kind, courseID, materialIDs, hasExecutionTime, startsAt, endsAt, deadline
    case location, isAllDay, deadlineIsAllDay, showInMonth, completionRequired
}

public struct PlanDetails: Codable, Hashable, Sendable {
    public var title: String
    public var content: String
    public var kind: String
    public var courseID: UUID?
    public var courseNameSnapshot: String?
    public var materialIDs: [UUID]
    public var hasExecutionTime: Bool
    public var startsAt: Date
    public var endsAt: Date?
    public var deadline: Date?
    public var location: String
    public var isAllDay: Bool
    public var deadlineIsAllDay: Bool
    public var showInMonth: Bool
    public var completionRequired: Bool
    /// Nil supports an explicit complete replacement. Repository edits record
    /// only changed fields, so unrelated later group edits still propagate.
    public var overriddenFields: Set<PlanDetailField>?
    public init(_ plan: StudyTask, comparedTo base: StudyTask? = nil) {
        title = plan.title; content = plan.content; kind = plan.kind; courseID = plan.courseID; courseNameSnapshot = plan.courseNameSnapshot
        materialIDs = plan.materialIDs; hasExecutionTime = plan.hasExecutionTime; startsAt = plan.startsAt
        endsAt = plan.endsAt; deadline = plan.deadline; location = plan.location; isAllDay = plan.isAllDay
        deadlineIsAllDay = plan.deadlineIsAllDay; showInMonth = plan.showInMonth; completionRequired = plan.completionRequired
        if let base {
            var fields = Set<PlanDetailField>()
            if plan.title != base.title { fields.insert(.title) }
            if plan.content != base.content { fields.insert(.content) }
            if plan.kind != base.kind { fields.insert(.kind) }
            if plan.courseID != base.courseID { fields.insert(.courseID) }
            if Set(plan.materialIDs) != Set(base.materialIDs) { fields.insert(.materialIDs) }
            if plan.hasExecutionTime != base.hasExecutionTime { fields.insert(.hasExecutionTime) }
            if plan.startsAt != base.startsAt { fields.insert(.startsAt) }
            if plan.endsAt != base.endsAt { fields.insert(.endsAt) }
            if plan.deadline != base.deadline { fields.insert(.deadline) }
            if plan.location != base.location { fields.insert(.location) }
            if plan.isAllDay != base.isAllDay { fields.insert(.isAllDay) }
            if plan.deadlineIsAllDay != base.deadlineIsAllDay { fields.insert(.deadlineIsAllDay) }
            if plan.showInMonth != base.showInMonth { fields.insert(.showInMonth) }
            if plan.completionRequired != base.completionRequired { fields.insert(.completionRequired) }
            overriddenFields = fields
        }
    }
    public func apply(to plan: inout StudyTask) {
        func includes(_ field: PlanDetailField) -> Bool { overriddenFields?.contains(field) ?? true }
        if includes(.title) { plan.title = title }
        if includes(.content) { plan.content = content }
        if includes(.kind) { plan.kind = kind }
        if includes(.courseID) { plan.courseID = courseID; plan.courseNameSnapshot = courseNameSnapshot }
        if includes(.materialIDs) { plan.materialIDs = materialIDs }
        if includes(.hasExecutionTime) { plan.hasExecutionTime = hasExecutionTime }
        if includes(.startsAt) { plan.startsAt = startsAt }
        if includes(.endsAt) { plan.endsAt = endsAt }
        if includes(.deadline) { plan.deadline = deadline }
        if includes(.location) { plan.location = location }
        if includes(.isAllDay) { plan.isAllDay = isAllDay }
        if includes(.deadlineIsAllDay) { plan.deadlineIsAllDay = deadlineIsAllDay }
        if includes(.showInMonth) { plan.showInMonth = showInMonth }
        if includes(.completionRequired) { plan.completionRequired = completionRequired }
    }
}

public struct PlanException: Codable, Hashable, Sendable {
    public var originalDate: Date
    public var details: PlanDetails?
    public var startsAt: Date?
    public var endsAt: Date?
    public var deadline: Date?
    public var completedAt: Date?
    public var completedOverride: Bool?
    public var cancelledAt: Date?
    public var location: String?
    public init(originalDate: Date, startsAt: Date? = nil, endsAt: Date? = nil, deadline: Date? = nil, completedAt: Date? = nil, cancelledAt: Date? = nil, location: String? = nil, details: PlanDetails? = nil, completedOverride: Bool? = nil) {
        self.originalDate = originalDate; self.details = details; self.startsAt = startsAt; self.endsAt = endsAt
        self.deadline = deadline; self.completedAt = completedAt; self.cancelledAt = cancelledAt; self.location = location
        self.completedOverride = completedOverride
    }
}

public struct PlanOccurrence: Identifiable, Hashable, Sendable {
    /// Effective snapshot, including the occurrence's move/completion/cancellation.
    public var task: StudyTask
    public var originalDate: Date
    /// Clipped to the queried civil day for a multi-day execution.
    public var date: Date
    public var endDate: Date?
    public var isDeadline: Bool
    public var isAllDay: Bool
    public var id: String { "\(task.id.uuidString)-\(task.repeatRule == nil ? "once" : String(originalDate.timeIntervalSinceReferenceDate))-\(isDeadline ? "ddl" : "execution")" }
    public var isFixed: Bool { isDeadline || task.origin == .fixed }
    public var origin: PlanOrigin { isFixed ? .fixed : .activity }
    public init(task: StudyTask, originalDate: Date, date: Date, endDate: Date? = nil, isDeadline: Bool, isAllDay: Bool) {
        self.task = task; self.originalDate = originalDate; self.date = date
        self.endDate = endDate; self.isDeadline = isDeadline; self.isAllDay = isAllDay
    }
}

/// Pure, time-zone-stable projection. DDL children are derived from their parent,
/// so they cannot become stale or survive deletion of the parent.
public enum PlanCalendar {
    public static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 2
        return value
    }

    public static func events(on day: Date, plans: [StudyTask]) -> [PlanOccurrence] {
        guard day.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let cal = calendar, start = cal.startOfDay(for: day)
        guard let next = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        var result: [PlanOccurrence] = []
        for plan in plans where plan.showOnCalendar && !plan.isArchived && !plan.isCancelled {
            let anchor = anchor(for: plan)
            var candidates = Set<Date>()
            if plan.repeatRule == nil { candidates.insert(anchor) }
            else {
                if plan.hasExecutionTime {
                    let length = max(0, (plan.endsAt ?? plan.startsAt).timeIntervalSince(plan.startsAt))
                    let earliest = start.addingTimeInterval(-length)
                    candidates.formUnion(anchors(for: plan, from: earliest, through: next))
                }
                if let deadline = plan.deadline {
                    let days = cal.dateComponents([.day], from: cal.startOfDay(for: anchor), to: cal.startOfDay(for: deadline)).day ?? 0
                    if let shifted = cal.date(byAdding: .day, value: -days, to: start),
                       let shiftedEnd = cal.date(byAdding: .day, value: 1, to: shifted) {
                        candidates.formUnion(anchors(for: plan, from: shifted, through: shiftedEnd))
                    }
                }
            }
            // A moved occurrence can be arbitrarily far from its nominal day.
            candidates.formUnion(plan.exceptions.map(\.originalDate))
            for original in candidates.sorted() {
                guard isOccurrenceAnchor(original, for: plan) else { continue }
                let effective = snapshot(of: plan, originalDate: original)
                guard !effective.isCancelled else { continue }
                if effective.hasExecutionTime {
                    let begin = effective.startsAt, end = effective.endsAt
                    let intersects = end.map { $0 > begin ? begin < next && $0 > start : begin >= start && begin < next } ?? (begin >= start && begin < next)
                    if intersects {
                        result.append(PlanOccurrence(task: effective, originalDate: original, date: max(start, begin), endDate: end.map { min($0, next) }, isDeadline: false, isAllDay: effective.isAllDay))
                    }
                }
                if let due = effective.deadline, due >= start && due < next {
                    result.append(PlanOccurrence(task: effective, originalDate: original, date: due, isDeadline: true, isAllDay: effective.deadlineIsAllDay))
                }
            }
        }
        return result.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.isDeadline != $1.isDeadline { return $0.isDeadline }
            if $0.task.title != $1.task.title { return $0.task.title.localizedStandardCompare($1.task.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    public static func anchor(for plan: StudyTask) -> Date {
        plan.hasExecutionTime ? plan.startsAt : (plan.deadline ?? plan.startsAt)
    }

    public static func snapshot(of plan: StudyTask, originalDate: Date) -> StudyTask {
        var result = plan
        let base = anchor(for: plan), cal = calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: base), to: cal.startOfDay(for: originalDate)).day ?? 0
        func shifted(_ date: Date) -> Date { cal.date(byAdding: .day, value: days, to: date) ?? date }
        result.startsAt = shifted(plan.startsAt); result.endsAt = plan.endsAt.map(shifted)
        result.deadline = plan.deadline.map(shifted)
        if let change = plan.exceptions.first(where: { $0.originalDate == originalDate }) {
            change.details?.apply(to: &result)
            result.startsAt = change.startsAt ?? result.startsAt
            result.endsAt = change.endsAt ?? result.endsAt
            result.deadline = change.deadline ?? result.deadline
            result.completedAt = change.completedOverride == false ? nil : (change.completedAt ?? result.completedAt)
            result.cancelledAt = change.cancelledAt ?? result.cancelledAt
            result.location = change.location ?? result.location
        }
        return result
    }

    public static func isOccurrenceAnchor(_ date: Date, for plan: StudyTask) -> Bool {
        let base = anchor(for: plan)
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        guard let rule = plan.repeatRule else { return date == base }
        guard (1...366).contains(rule.interval), date >= base else { return false }
        let index = indexNear(date, base: base, rule: rule)
        guard index >= 0, occurrenceDate(index: index, base: base, rule: rule) == date else { return false }
        if let until = rule.until, calendar.startOfDay(for: date) > calendar.startOfDay(for: until) { return false }
        return true
    }

    private static func anchors(for plan: StudyTask, from: Date, through: Date) -> [Date] {
        guard let rule = plan.repeatRule, (1...366).contains(rule.interval) else { return [] }
        let base = anchor(for: plan)
        let first = max(0, indexNear(from, base: base, rule: rule) - 1)
        let last = max(first, indexNear(through, base: base, rule: rule) + 1)
        // Validation bounds execution duration; this is also defensive for direct callers.
        guard last - first <= 10_000 else { return [] }
        return (first...last).compactMap { index in
            guard let date = occurrenceDate(index: index, base: base, rule: rule), date >= from, date <= through else { return nil }
            if let until = rule.until, calendar.startOfDay(for: date) > calendar.startOfDay(for: until) { return nil }
            return date
        }
    }

    static func indexNear(_ day: Date, base: Date, rule: PlanRepeatRule) -> Int {
        let cal = calendar
        switch rule.frequency {
        case .daily, .weekly:
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: base), to: cal.startOfDay(for: day)).day ?? 0
            return days / (rule.interval * (rule.frequency == .weekly ? 7 : 1))
        case .monthly:
            let a = cal.dateComponents([.year, .month], from: base), b = cal.dateComponents([.year, .month], from: day)
            return (((b.year ?? 0) - (a.year ?? 0)) * 12 + (b.month ?? 1) - (a.month ?? 1)) / rule.interval
        }
    }

    static func occurrenceDate(index: Int, base: Date, rule: PlanRepeatRule) -> Date? {
        guard index >= 0, index <= 1_000_000 else { return nil }
        if index == 0 { return base }
        let cal = calendar
        switch rule.frequency {
        case .daily: return cal.date(byAdding: .day, value: index * rule.interval, to: base)
        case .weekly: return cal.date(byAdding: .day, value: index * rule.interval * 7, to: base)
        case .monthly:
            let original = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: base)
            var first = original; first.day = 1
            guard let monthStart = cal.date(from: first), let month = cal.date(byAdding: .month, value: index * rule.interval, to: monthStart), let range = cal.range(of: .day, in: .month, for: month) else { return nil }
            var target = cal.dateComponents([.year, .month], from: month)
            target.day = min(original.day ?? 1, range.count)
            target.hour = original.hour; target.minute = original.minute; target.second = original.second; target.nanosecond = original.nanosecond
            return cal.date(from: target)
        }
    }
}
