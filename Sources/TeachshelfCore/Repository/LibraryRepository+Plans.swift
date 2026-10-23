import Foundation

extension LibraryRepository {
    public func saveTask(_ task: StudyTask) throws {
        try commit { state in
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("请输入待办标题。") }
            if let existing = state.tasks.first(where: { $0.id == task.id }), existing.isArchived {
                throw LibraryError.invalidInput("归档待办为只读，请先恢复后再编辑。")
            }
            var task = task
            if let courseID = task.courseID { task.courseNameSnapshot = state.courses.first { $0.id == courseID }?.name }
            task.materialIDs = Array(Set(task.materialIDs)).sorted { $0.uuidString < $1.uuidString }
            if let index = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[index] = task }
            else { state.tasks.append(task) }
        }
    }
    public func setTaskCompleted(id: UUID, completed: Bool) throws {
        try commit { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("待办") }
            guard !state.tasks[index].isArchived else { throw LibraryError.invalidInput("归档待办为只读，请先恢复后再修改完成状态。") }
            state.tasks[index].completedAt = completed ? (state.tasks[index].completedAt ?? Date()) : nil
        }
    }
    public func archiveTask(id: UUID) throws {
        try commit { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("待办") }
            if state.tasks[index].isArchived { return }
            let timestamp = Date()
            guard state.tasks[index].startsAt <= timestamp else { throw LibraryError.invalidInput("开始时间尚未到，无法归档此待办。") }
            if let completed = state.tasks[index].completedAt, completed > timestamp { throw LibraryError.invalidInput("完成时间晚于当前归档时间，无法归档此待办。") }
            state.tasks[index].completedAt = state.tasks[index].completedAt ?? timestamp
            state.tasks[index].archivedAt = timestamp
        }
    }
    public func restoreTask(id: UUID) throws {
        try commit { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("待办") }
            state.tasks[index].archivedAt = nil
        }
    }
    public func deleteTasks(ids: Set<UUID>) throws {
        try withLock {
            let removed = snapshot.tasks.filter { ids.contains($0.id) }
            if removed.isEmpty { return }
            try commit { $0.tasks.removeAll { ids.contains($0.id) } }
            deletedTaskBatches.append(removed)
        }
    }
    public func undoTaskDeletion() throws {
        try withLock {
            guard let batch = deletedTaskBatches.last else { return }
            try commit { state in
                let courseIDs = Set(state.courses.map(\.id)), materialIDs = Set(state.materials.map(\.id))
                for var task in batch where !state.tasks.contains(where: { $0.id == task.id }) {
                    if let id = task.courseID, !courseIDs.contains(id) { task.courseID = nil }
                    task.materialIDs.removeAll { !materialIDs.contains($0) }
                    for e in task.exceptions.indices {
                        if let id = task.exceptions[e].details?.courseID, !courseIDs.contains(id) { task.exceptions[e].details?.courseID = nil }
                        task.exceptions[e].details?.materialIDs.removeAll { !materialIDs.contains($0) }
                    }
                    state.tasks.append(task)
                }
            }
            deletedTaskBatches.removeLast()
        }
    }

    /// Restores only changed records; unrelated later edits remain intact.
    public func restorePlanChanges(before: [StudyTask], after: [StudyTask]) throws {
        try commit { state in
            let ids = Set(before.map(\.id)).union(after.map(\.id))
            guard Set(before.map(\.id)).count == before.count, Set(after.map(\.id)).count == after.count else {
                throw LibraryError.invalidInput("撤销记录包含重复计划。")
            }
            let expected = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
            let current = Dictionary(uniqueKeysWithValues: state.tasks.filter { ids.contains($0.id) }.map { ($0.id, $0) })
            guard current == expected else { throw LibraryError.invalidInput("这些计划后来已被修改，无法撤销。") }
            state.tasks.removeAll { ids.contains($0.id) }
            state.tasks.append(contentsOf: before)
        }
    }

    public func movePlanOccurrence(id: UUID, originalDate: Date, isDeadline: Bool, to date: Date) throws {
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state)
            let parent = state.tasks[index]
            try Self.requireOccurrence(originalDate, of: parent)
            let current = PlanCalendar.snapshot(of: parent, originalDate: originalDate)
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw LibraryError.invalidInput("计划时间无效。") }
            if isDeadline {
                guard current.deadline != nil else { throw LibraryError.invalidInput("该计划没有截止时间。") }
                if parent.repeatRule == nil { state.tasks[index].deadline = date }
                else { Self.editException(in: &state.tasks[index], on: originalDate) { $0.deadline = date } }
            } else {
                guard current.hasExecutionTime else { throw LibraryError.invalidInput("该计划尚未安排执行时间。") }
                let end = current.endsAt.map { date.addingTimeInterval($0.timeIntervalSince(current.startsAt)) }
                if parent.repeatRule == nil { state.tasks[index].startsAt = date; state.tasks[index].endsAt = end }
                else { Self.editException(in: &state.tasks[index], on: originalDate) { $0.startsAt = date; $0.endsAt = end } }
            }
        }
    }

    public func setPlanOccurrenceTime(id: UUID, originalDate: Date, day: Date, range: PlanTimeRange) throws {
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state), parent = state.tasks[index]
            try Self.requireOccurrence(originalDate, of: parent)
            let current = PlanCalendar.snapshot(of: parent, originalDate: originalDate)
            guard current.hasExecutionTime, !current.isAllDay, day.timeIntervalSinceReferenceDate.isFinite else {
                throw LibraryError.invalidInput("请选择有具体时段的计划。")
            }
            let midnight = PlanCalendar.calendar.startOfDay(for: day)
            let start = midnight.addingTimeInterval(Double(range.start) * 60)
            let end = midnight.addingTimeInterval(Double(range.end) * 60)
            if parent.repeatRule == nil { state.tasks[index].startsAt = start; state.tasks[index].endsAt = end }
            else { Self.editException(in: &state.tasks[index], on: originalDate) { $0.startsAt = start; $0.endsAt = end } }
        }
    }

    public func setPlanOccurrenceCompleted(id: UUID, originalDate: Date, completed: Bool) throws {
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state), parent = state.tasks[index]
            try Self.requireOccurrence(originalDate, of: parent)
            if parent.repeatRule == nil { state.tasks[index].completedAt = completed ? (parent.completedAt ?? Date()) : nil }
            else {
                Self.editException(in: &state.tasks[index], on: originalDate) {
                    $0.completedAt = completed ? ($0.completedAt ?? Date()) : nil
                    $0.completedOverride = completed
                }
            }
        }
    }

    public func setPlanOccurrenceCancelled(id: UUID, originalDate: Date, cancelled: Bool) throws {
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state), parent = state.tasks[index]
            try Self.requireOccurrence(originalDate, of: parent)
            if parent.repeatRule == nil { state.tasks[index].cancelledAt = cancelled ? (parent.cancelledAt ?? Date()) : nil }
            else {
                guard parent.cancelledAt == nil else { throw LibraryError.invalidInput("整组计划已取消，请先恢复整组。") }
                Self.editException(in: &state.tasks[index], on: originalDate) { $0.cancelledAt = cancelled ? ($0.cancelledAt ?? Date()) : nil }
            }
        }
    }

    /// Clears one occurrence's overrides, restoring its original arrangement.
    public func restorePlanOccurrence(id: UUID, originalDate: Date) throws {
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state)
            try Self.requireOccurrence(originalDate, of: state.tasks[index])
            if state.tasks[index].repeatRule == nil {
                state.tasks[index].cancelledAt = nil; state.tasks[index].completedAt = nil
            } else { state.tasks[index].exceptions.removeAll { $0.originalDate == originalDate } }
        }
    }

    public func savePlan(_ task: StudyTask, originalDate: Date? = nil, scope: PlanEditScope = .all) throws {
        if scope == .all {
            try commit { state in
                var replacement = Self.normalizedPlan(task, in: state)
                if let index = state.tasks.firstIndex(where: { $0.id == task.id }) {
                    guard !state.tasks[index].isArchived else { throw LibraryError.invalidInput("归档计划为只读，请先恢复。") }
                    let previous = state.tasks[index]
                    replacement.exceptions = Self.remappedPlanExceptions(task.exceptions, from: previous, to: task)
                    if previous.deadline != nil && task.deadline == nil {
                        for e in replacement.exceptions.indices {
                            replacement.exceptions[e].deadline = nil
                            replacement.exceptions[e].details?.deadline = nil
                        }
                    }
                    if previous.hasExecutionTime && !task.hasExecutionTime {
                        for e in replacement.exceptions.indices {
                            replacement.exceptions[e].startsAt = nil; replacement.exceptions[e].endsAt = nil
                            replacement.exceptions[e].details?.hasExecutionTime = false
                        }
                    }
                    state.tasks[index] = replacement
                } else { state.tasks.append(replacement) }
            }
            return
        }
        try commit { state in
            let index = try Self.editablePlanIndex(task.id, in: state), parent = state.tasks[index]
            guard let originalDate else { throw LibraryError.invalidInput("请选择要调整的这次计划。") }
            try Self.requireOccurrence(originalDate, of: parent)
            guard parent.repeatRule != nil else {
                var replacement = task; replacement.id = parent.id; replacement.exceptions = []
                state.tasks[index] = Self.normalizedPlan(replacement, in: state); return
            }
            if scope == .thisOccurrence {
                var nominal = parent; nominal.exceptions = []
                let base = PlanCalendar.snapshot(of: nominal, originalDate: originalDate)
                var details = PlanDetails(Self.normalizedPlan(task, in: state), comparedTo: base)
                details.materialIDs = Array(Set(details.materialIDs)).sorted { $0.uuidString < $1.uuidString }
                Self.editException(in: &state.tasks[index], on: originalDate) {
                    $0.details = details; $0.startsAt = nil; $0.endsAt = nil; $0.deadline = nil; $0.location = nil
                    $0.completedAt = task.completedAt; $0.cancelledAt = task.cancelledAt
                    $0.completedOverride = task.completedAt != base.completedAt ? task.completedAt != nil : nil
                }
            } else {
                let base = PlanCalendar.anchor(for: parent)
                if originalDate == base {
                    var replacement = task; replacement.id = parent.id
                    replacement = Self.normalizedPlan(replacement, in: state)
                    replacement.exceptions = Self.remappedPlanExceptions(parent.exceptions.filter { $0.originalDate != originalDate }, from: parent, to: replacement)
                    state.tasks[index] = replacement
                } else {
                    var future = Self.normalizedPlan(task, in: state)
                    future.id = UUID(); future.exceptions = []
                    if let oldRule = parent.repeatRule, let newRule = future.repeatRule {
                        let sourceIndex = PlanCalendar.indexNear(originalDate, base: base, rule: oldRule)
                        let newBase = PlanCalendar.anchor(for: future)
                        for old in parent.exceptions where old.originalDate > originalDate {
                            let offset = PlanCalendar.indexNear(old.originalDate, base: base, rule: oldRule) - sourceIndex
                            guard let newOriginal = PlanCalendar.occurrenceDate(index: offset, base: newBase, rule: newRule), PlanCalendar.isOccurrenceAnchor(newOriginal, for: future) else { continue }
                            var remapped = old; remapped.originalDate = newOriginal
                            future.exceptions.append(remapped)
                        }
                    }
                    Self.truncatePlan(&state.tasks[index], before: originalDate)
                    state.tasks.append(future)
                }
            }
        }
    }

    public func cancelPlan(id: UUID, originalDate: Date? = nil, scope: PlanEditScope = .all) throws {
        guard scope == .all || originalDate != nil else { throw LibraryError.invalidInput("请选择要取消的这次计划。") }
        if scope == .thisOccurrence, let originalDate { try setPlanOccurrenceCancelled(id: id, originalDate: originalDate, cancelled: true); return }
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state)
            if scope == .thisAndFuture, let originalDate, state.tasks[index].repeatRule != nil {
                try Self.requireOccurrence(originalDate, of: state.tasks[index])
                if originalDate == PlanCalendar.anchor(for: state.tasks[index]) { state.tasks[index].cancelledAt = Date() }
                else {
                    let parent = state.tasks[index]
                    var nominal = parent; nominal.exceptions = []
                    var future = PlanCalendar.snapshot(of: nominal, originalDate: originalDate)
                    future.id = UUID(); future.cancelledAt = Date()
                    future.exceptions = []
                    if let rule = parent.repeatRule {
                        let sourceIndex = PlanCalendar.indexNear(originalDate, base: PlanCalendar.anchor(for: parent), rule: rule)
                        for old in parent.exceptions where old.originalDate >= originalDate {
                            let offset = PlanCalendar.indexNear(old.originalDate, base: PlanCalendar.anchor(for: parent), rule: rule) - sourceIndex
                            if let next = PlanCalendar.occurrenceDate(index: offset, base: PlanCalendar.anchor(for: future), rule: rule) {
                                var copy = old; copy.originalDate = next; future.exceptions.append(copy)
                            }
                        }
                    }
                    Self.truncatePlan(&state.tasks[index], before: originalDate)
                    state.tasks.append(future)
                }
            } else { state.tasks[index].cancelledAt = Date() }
        }
    }

    public func deletePlan(id: UUID, originalDate: Date? = nil, scope: PlanEditScope = .all) throws {
        guard scope == .all || originalDate != nil else { throw LibraryError.invalidInput("请选择要移除的这次计划。") }
        if scope == .all { try deleteTasks(ids: [id]); return }
        if scope == .thisOccurrence, let originalDate { try setPlanOccurrenceCancelled(id: id, originalDate: originalDate, cancelled: true); return }
        try commit { state in
            let index = try Self.editablePlanIndex(id, in: state)
            guard let originalDate else { throw LibraryError.invalidInput("请选择要移除的这次计划。") }
            try Self.requireOccurrence(originalDate, of: state.tasks[index])
            if state.tasks[index].repeatRule == nil || originalDate == PlanCalendar.anchor(for: state.tasks[index]) { state.tasks.remove(at: index) }
            else { Self.truncatePlan(&state.tasks[index], before: originalDate) }
        }
    }

    private static func editablePlanIndex(_ id: UUID, in state: LibraryState) throws -> Int {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("计划") }
        guard !state.tasks[index].isArchived else { throw LibraryError.invalidInput("归档计划为只读，请先恢复。") }
        return index
    }
    private static func requireOccurrence(_ date: Date, of plan: StudyTask) throws {
        guard PlanCalendar.isOccurrenceAnchor(date, for: plan) else { throw LibraryError.invalidInput("找不到该次计划，重复规则可能已经改变。") }
    }
    private static func normalizedPlan(_ plan: StudyTask, in state: LibraryState) -> StudyTask {
        var result = plan
        if let hex = result.colorHex, let color = RGBColor(hex: hex) { result.colorHex = color.hex }
        result.materialIDs = Array(Set(result.materialIDs)).sorted { $0.uuidString < $1.uuidString }
        if let id = result.courseID { result.courseNameSnapshot = state.courses.first { $0.id == id }?.name }
        return result
    }
    private static func editException(in plan: inout StudyTask, on date: Date, _ action: (inout PlanException) -> Void) {
        let index = plan.exceptions.firstIndex { $0.originalDate == date }
        var exception = index.map { plan.exceptions[$0] } ?? PlanException(originalDate: date)
        action(&exception)
        if let index { plan.exceptions[index] = exception } else { plan.exceptions.append(exception) }
        plan.exceptions.sort { $0.originalDate < $1.originalDate }
    }
    private static func truncatePlan(_ plan: inout StudyTask, before date: Date) {
        plan.repeatRule?.until = PlanCalendar.calendar.date(byAdding: .day, value: -1, to: PlanCalendar.calendar.startOfDay(for: date))
        plan.exceptions.removeAll { $0.originalDate >= date }
    }

    private static func remappedPlanExceptions(_ exceptions: [PlanException], from old: StudyTask, to new: StudyTask) -> [PlanException] {
        guard let oldRule = old.repeatRule, let newRule = new.repeatRule else { return [] }
        let oldBase = PlanCalendar.anchor(for: old), newBase = PlanCalendar.anchor(for: new)
        return exceptions.compactMap { exception in
            let index = PlanCalendar.indexNear(exception.originalDate, base: oldBase, rule: oldRule)
            guard let date = PlanCalendar.occurrenceDate(index: index, base: newBase, rule: newRule), PlanCalendar.isOccurrenceAnchor(date, for: new) else { return nil }
            var copy = exception; copy.originalDate = date
            return copy
        }
    }
    static func validatePlan(_ task: StudyTask, courseIDs: Set<UUID>, materialIDs: Set<UUID>) throws {
        if let hex = task.colorHex, RGBColor(hex: hex) == nil { throw LibraryError.invalidInput("计划颜色须为六位 HEX 颜色。") }
        guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("计划名称不能为空。") }
        guard [task.startsAt, task.endsAt, task.deadline, task.completedAt, task.archivedAt, task.cancelledAt, task.repeatRule?.until].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryError.invalidInput("计划包含无效日期。")
        }
        if task.hasExecutionTime, let end = task.endsAt {
            guard end >= task.startsAt, end.timeIntervalSince(task.startsAt) <= 3660 * 86400 else { throw LibraryError.invalidInput("执行结束时间须在开始之后，且跨度不能超过十年。") }
        }
        if let archived = task.archivedAt {
            guard let completed = task.completedAt, completed <= archived else { throw LibraryError.invalidInput("归档计划必须已完成，且完成时间不能晚于归档时间。") }
        }
        if let id = task.courseID, !courseIDs.contains(id) { throw LibraryError.invalidInput("计划关联的课程不存在。") }
        guard task.materialIDs.allSatisfy(materialIDs.contains) else { throw LibraryError.invalidInput("计划关联的资料不存在。") }
        if let rule = task.repeatRule {
            guard (1...366).contains(rule.interval), task.hasExecutionTime || task.deadline != nil else { throw LibraryError.invalidInput("重复间隔须为1至366，且需要执行时间或截止时间。") }
            if let until = rule.until, PlanCalendar.calendar.startOfDay(for: until) < PlanCalendar.calendar.startOfDay(for: PlanCalendar.anchor(for: task)) { throw LibraryError.invalidInput("重复结束日期不能早于首次安排。") }
        } else if !task.exceptions.isEmpty { throw LibraryError.invalidInput("非重复计划不能包含单次例外。") }
        guard task.exceptions.count <= 10_000, Set(task.exceptions.map(\.originalDate)).count == task.exceptions.count else { throw LibraryError.invalidInput("重复计划例外过多或包含重复日期。") }
        for exception in task.exceptions {
            guard [exception.originalDate, exception.startsAt, exception.endsAt, exception.deadline, exception.completedAt, exception.cancelledAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }), PlanCalendar.isOccurrenceAnchor(exception.originalDate, for: task) else { throw LibraryError.invalidInput("计划的单次调整不属于当前重复规则。") }
            var effective = PlanCalendar.snapshot(of: task, originalDate: exception.originalDate)
            effective.repeatRule = nil; effective.exceptions = []; effective.archivedAt = nil
            try validatePlan(effective, courseIDs: courseIDs, materialIDs: materialIDs)
        }
    }
}
