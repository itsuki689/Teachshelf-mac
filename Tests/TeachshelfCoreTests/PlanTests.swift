import Foundation
import Testing
@testable import TeachshelfCore

@Suite(.serialized)
final class PlanTests {
    private var folders: [URL] = []
    deinit { for url in folders { try? FileManager.default.removeItem(at: url) } }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func repo() throws -> LibraryRepository {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PlanTests-\(UUID().uuidString)")
        folders.append(url); return try LibraryRepository(root: url)
    }
    private func weekly() -> StudyTask {
        StudyTask(title: "实验报告", startsAt: date("2026-10-12T19:00:00+08:00"), deadline: date("2026-10-16T23:59:00+08:00"), isAllDay: false, endsAt: date("2026-10-12T20:00:00+08:00"), repeatRule: PlanRepeatRule(frequency: .weekly, until: date("2026-11-30T00:00:00+08:00")), deadlineIsAllDay: false)
    }
    @Test func executionAndDDLProjectIndependentlyAndKeepIdentity() throws {
        let repository = try repo()
        let plan = StudyTask(title: "报告", startsAt: date("2026-10-13T19:00:00+08:00"), deadline: date("2026-10-16T23:00:00+08:00"), isAllDay: false, endsAt: date("2026-10-13T20:30:00+08:00"))
        try repository.saveTask(plan)
        let event = PlanCalendar.events(on: plan.startsAt, plans: repository.state.tasks).first!
        #expect(!event.isDeadline && !event.isFixed)
        let due = PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks).first!
        #expect(due.isDeadline && due.isFixed && due.task.id == plan.id)
        let moved = date("2026-10-14T20:00:00+08:00")
        try repository.movePlanOccurrence(id: plan.id, originalDate: event.originalDate, isDeadline: false, to: moved)
        #expect(repository.state.tasks[0].deadline == plan.deadline)
        #expect(repository.state.tasks[0].endsAt == moved.addingTimeInterval(5400))
        #expect(PlanCalendar.events(on: moved, plans: repository.state.tasks)[0].id == event.id)
        let newDue = date("2026-10-17T12:00:00+08:00")
        try repository.movePlanOccurrence(id: plan.id, originalDate: moved, isDeadline: true, to: newDue)
        #expect(repository.state.tasks[0].deadline == newDue)
        #expect(repository.state.tasks[0].startsAt == moved)
        #expect(PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks).isEmpty)
    }
    @Test func futureExecutionAndDeadlineOnlyCanBeCompletedEarlyWithoutInventingTimestamps() throws {
        let repository = try repo()
        let now = Date(), tomorrow = now.addingTimeInterval(86400), nextDay = now.addingTimeInterval(2 * 86400)
        let timed = StudyTask(title: "提前做完报告", startsAt: tomorrow, deadline: nextDay, endsAt: tomorrow.addingTimeInterval(3600))
        let dueOnly = StudyTask(title: "提前报名", startsAt: tomorrow, deadline: nextDay, hasExecutionTime: false)
        try repository.saveTask(timed); try repository.saveTask(dueOnly)
        try repository.setPlanOccurrenceCompleted(id: timed.id, originalDate: timed.startsAt, completed: true)
        try repository.setPlanOccurrenceCompleted(id: dueOnly.id, originalDate: dueOnly.deadline!, completed: true)
        let saved = repository.state.tasks.first { $0.id == timed.id }!
        #expect(saved.completedAt! >= now && saved.completedAt! < tomorrow)
        #expect(PlanCalendar.events(on: tomorrow, plans: [saved])[0].task.isCompleted)
        #expect(PlanCalendar.events(on: nextDay, plans: [saved])[0].task.isCompleted)
        #expect(PlanCalendar.events(on: nextDay, plans: repository.state.tasks).allSatisfy { $0.task.isCompleted })
        #expect(throws: (any Error).self) { try repository.archiveTask(id: timed.id) }
    }
    @Test func deadlineOnlyChildKeepsIdentityWhenItsParentAnchorMoves() throws {
        let repository = try repo()
        let plan = StudyTask(title: "报名", startsAt: date("2026-10-12T00:00:00+08:00"), deadline: date("2026-10-16T23:00:00+08:00"), hasExecutionTime: false)
        try repository.saveTask(plan)
        let before = PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks)[0]
        let moved = date("2026-10-20T20:00:00+08:00")
        try repository.movePlanOccurrence(id: plan.id, originalDate: before.originalDate, isDeadline: true, to: moved)
        let after = PlanCalendar.events(on: moved, plans: repository.state.tasks)[0]
        #expect(before.id == after.id && after.isFixed)
        #expect(PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks).isEmpty)
    }
    @Test func singleFieldOverrideDoesNotFreezeOtherGroupFieldsAndGroupDeadlineRemovalClearsChildren() throws {
        let repository = try repo(), plan = weekly()
        try repository.saveTask(plan)
        var local = PlanCalendar.snapshot(of: plan, originalDate: plan.startsAt)
        local.location = "临时教室"
        try repository.savePlan(local, originalDate: plan.startsAt, scope: .thisOccurrence)
        try repository.movePlanOccurrence(id: plan.id, originalDate: plan.startsAt, isDeadline: true, to: date("2026-12-20T23:00:00+08:00"))
        var group = repository.state.tasks[0]; group.title = "统一新名称"; group.deadline = nil
        try repository.savePlan(group)
        let occurrence = PlanCalendar.events(on: plan.startsAt, plans: repository.state.tasks)[0]
        #expect(occurrence.task.title == "统一新名称")
        #expect(occurrence.task.location == "临时教室")
        #expect(occurrence.task.deadline == nil)
        #expect(PlanCalendar.events(on: date("2026-12-20T23:00:00+08:00"), plans: repository.state.tasks).isEmpty)
    }
    @Test func deadlineOnlyAndUnscheduledPlansAreNotConfused() throws {
        let due = date("2027-01-10T23:59:00+08:00")
        let plan = StudyTask(title: "报名", deadline: due, hasExecutionTime: false)
        #expect(PlanCalendar.events(on: due, plans: [plan]).count == 1)
        #expect(PlanCalendar.events(on: due, plans: [plan])[0].isDeadline)
        var unplanned = plan; unplanned.deadline = nil
        #expect(PlanCalendar.events(on: unplanned.startsAt, plans: [unplanned]).isEmpty)
    }
    @Test func movedRecurringExecutionDoesNotMoveItsDDLOrOtherOccurrences() throws {
        let repository = try repo(), plan = weekly()
        try repository.saveTask(plan)
        let nextMonday = date("2026-10-19T19:00:00+08:00")
        try repository.movePlanOccurrence(id: plan.id, originalDate: plan.startsAt, isDeadline: false, to: nextMonday)
        #expect(PlanCalendar.events(on: plan.startsAt, plans: repository.state.tasks).isEmpty)
        let two = PlanCalendar.events(on: nextMonday, plans: repository.state.tasks).filter { !$0.isDeadline }
        #expect(two.count == 2 && Set(two.map(\.id)).count == 2)
        #expect(two.map(\.originalDate).contains(plan.startsAt))
        #expect(PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks).count == 1)
        let movedDDL = date("2026-12-20T23:59:00+08:00")
        try repository.movePlanOccurrence(id: plan.id, originalDate: plan.startsAt, isDeadline: true, to: movedDDL)
        #expect(PlanCalendar.events(on: movedDDL, plans: repository.state.tasks).count == 1)
        #expect(PlanCalendar.events(on: nextMonday, plans: repository.state.tasks).filter { !$0.isDeadline }.count == 2)
    }
    @Test func completionCancellationAndRestoreApplyToBothChildren() throws {
        let repository = try repo(), plan = weekly()
        try repository.saveTask(plan)
        try repository.setPlanOccurrenceCompleted(id: plan.id, originalDate: plan.startsAt, completed: true)
        #expect(PlanCalendar.events(on: plan.startsAt, plans: repository.state.tasks)[0].task.isCompleted)
        #expect(PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks)[0].task.isCompleted)
        #expect(!PlanCalendar.events(on: date("2026-10-19T19:00:00+08:00"), plans: repository.state.tasks)[0].task.isCompleted)
        try repository.setPlanOccurrenceCancelled(id: plan.id, originalDate: plan.startsAt, cancelled: true)
        #expect(PlanCalendar.events(on: plan.startsAt, plans: repository.state.tasks).isEmpty)
        #expect(PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks).isEmpty)
        try repository.setPlanOccurrenceCancelled(id: plan.id, originalDate: plan.startsAt, cancelled: false)
        #expect(PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks)[0].task.isCompleted)
        try repository.restorePlanOccurrence(id: plan.id, originalDate: plan.startsAt)
        #expect(repository.state.tasks[0].exceptions.isEmpty)
    }
    @Test func monthlyRecurrenceClampsWithoutDriftingAndUntilIsInclusiveShanghai() throws {
        let plan = StudyTask(title: "月末", startsAt: date("2026-01-31T23:30:00+08:00"), repeatRule: PlanRepeatRule(frequency: .monthly, until: date("2026-03-31T00:00:00+08:00")))
        #expect(PlanCalendar.events(on: date("2026-02-28T16:00:00Z"), plans: [plan]).isEmpty) // March 1 in Shanghai.
        #expect(PlanCalendar.events(on: date("2026-02-28T12:00:00+08:00"), plans: [plan])[0].date == date("2026-02-28T23:30:00+08:00"))
        #expect(PlanCalendar.events(on: date("2026-03-31T23:59:00+08:00"), plans: [plan]).count == 1)
        #expect(PlanCalendar.events(on: date("2026-03-28T12:00:00+08:00"), plans: [plan]).isEmpty)
        #expect(PlanCalendar.events(on: date("2026-04-30T12:00:00+08:00"), plans: [plan]).isEmpty)
    }
    @Test func dailyIntervalAndDeadlineOnlyRepeatsUseCivilDays() throws {
        let plan = StudyTask(title: "交记录", startsAt: date("2026-10-01T00:00:00+08:00"), deadline: date("2026-10-13T00:15:00+08:00"), hasExecutionTime: false, repeatRule: PlanRepeatRule(frequency: .daily, interval: 2, until: date("2026-10-17T00:00:00+08:00")))
        #expect(PlanCalendar.events(on: date("2026-10-12T16:20:00Z"), plans: [plan]).count == 1)
        #expect(PlanCalendar.events(on: date("2026-10-14T12:00:00+08:00"), plans: [plan]).isEmpty)
        #expect(PlanCalendar.events(on: date("2026-10-17T12:00:00+08:00"), plans: [plan]).count == 1)
    }
    @Test func multiDayExecutionIsClippedAndMidnightEndDoesNotAddAnExtraDay() throws {
        let plan = StudyTask(title: "活动", startsAt: date("2026-10-12T20:00:00+08:00"), isAllDay: false, endsAt: date("2026-10-14T00:00:00+08:00"))
        let first = PlanCalendar.events(on: plan.startsAt, plans: [plan])[0]
        let second = PlanCalendar.events(on: date("2026-10-13T12:00:00+08:00"), plans: [plan])[0]
        #expect(first.id == second.id)
        #expect(second.date == date("2026-10-13T00:00:00+08:00"))
        #expect(second.endDate == plan.endsAt)
        #expect(PlanCalendar.events(on: plan.endsAt!, plans: [plan]).isEmpty)
    }
    @Test func singleOccurrenceEditAndFutureSplitPreservePriorHistory() throws {
        let repository = try repo(), plan = weekly()
        try repository.saveTask(plan)
        let second = date("2026-10-19T19:00:00+08:00")
        var one = PlanCalendar.snapshot(of: plan, originalDate: second)
        one.title = "仅这次"; one.location = "临时地点"; one.deadline = nil
        try repository.savePlan(one, originalDate: second, scope: .thisOccurrence)
        #expect(repository.state.tasks[0].title == plan.title)
        #expect(PlanCalendar.events(on: second, plans: repository.state.tasks)[0].task.title == "仅这次")
        #expect(PlanCalendar.events(on: date("2026-10-23T23:59:00+08:00"), plans: repository.state.tasks).isEmpty)
        var future = PlanCalendar.snapshot(of: plan, originalDate: second)
        future.title = "以后的计划"; future.location = "新地点"
        try repository.savePlan(future, originalDate: second, scope: .thisAndFuture)
        #expect(repository.state.tasks.count == 2)
        #expect(PlanCalendar.events(on: plan.startsAt, plans: repository.state.tasks)[0].task.title == plan.title)
        #expect(PlanCalendar.events(on: second, plans: repository.state.tasks)[0].task.title == "以后的计划")
        #expect(PlanCalendar.events(on: date("2026-10-26T19:00:00+08:00"), plans: repository.state.tasks).count == 1)
    }
    @Test func removingThisAndFuturePreservesEarlierExecutionAndItsLaterDDL() throws {
        let repository = try repo(), plan = weekly()
        try repository.saveTask(plan)
        try repository.deletePlan(id: plan.id, originalDate: date("2026-10-19T19:00:00+08:00"), scope: .thisAndFuture)
        #expect(PlanCalendar.events(on: plan.startsAt, plans: repository.state.tasks).count == 1)
        #expect(PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks).count == 1)
        #expect(PlanCalendar.events(on: date("2026-10-19T19:00:00+08:00"), plans: repository.state.tasks).isEmpty)
        #expect(PlanCalendar.events(on: date("2026-10-23T23:59:00+08:00"), plans: repository.state.tasks).isEmpty)
    }
    @Test func wholeGroupEditRemapsExceptionsByOccurrenceAndDeletingRepeatRemovesExceptions() throws {
        let repository = try repo(), plan = weekly()
        try repository.saveTask(plan)
        try repository.movePlanOccurrence(id: plan.id, originalDate: date("2026-10-19T19:00:00+08:00"), isDeadline: false, to: date("2026-10-20T18:00:00+08:00"))
        var edited = repository.state.tasks[0]
        edited.startsAt = date("2026-10-13T19:00:00+08:00"); edited.endsAt = date("2026-10-13T20:00:00+08:00")
        try repository.savePlan(edited)
        #expect(repository.state.tasks[0].exceptions[0].originalDate == date("2026-10-20T19:00:00+08:00"))
        edited = repository.state.tasks[0]; edited.repeatRule = nil
        try repository.savePlan(edited)
        #expect(repository.state.tasks[0].exceptions.isEmpty)
    }
    @Test func planUndoIsAtomicAndPreservesUnrelatedEdits() throws {
        let repository = try repo(), first = weekly(), other = StudyTask(title: "另一个")
        try repository.saveTask(first); try repository.saveTask(other)
        let before = [repository.state.tasks.first { $0.id == first.id }!]
        try repository.deletePlan(id: first.id)
        var changedOther = other; changedOther.title = "后来修改"
        try repository.saveTask(changedOther)
        try repository.restorePlanChanges(before: before, after: [])
        #expect(repository.state.tasks.contains(changedOther))
        #expect(repository.state.tasks.contains(first))
        var edited = first; edited.title = "新标题"; try repository.saveTask(edited)
        let state = repository.state
        #expect(throws: (any Error).self) { try repository.restorePlanChanges(before: [], after: before) }
        #expect(repository.state == state)
    }
    @Test func invalidRecurrenceOrExceptionFailsWithoutRewriting() throws {
        let repository = try repo(), original = weekly()
        try repository.saveTask(original)
        let bytes = try Data(contentsOf: repository.root.appendingPathComponent("library.json"))
        var invalid = original; invalid.repeatRule?.interval = 0
        #expect(throws: (any Error).self) { try repository.saveTask(invalid) }
        invalid = original; invalid.endsAt = original.startsAt.addingTimeInterval(-1)
        #expect(throws: (any Error).self) { try repository.saveTask(invalid) }
        #expect(throws: (any Error).self) { try repository.movePlanOccurrence(id: original.id, originalDate: original.startsAt.addingTimeInterval(1), isDeadline: true, to: original.startsAt) }
        #expect(try Data(contentsOf: repository.root.appendingPathComponent("library.json")) == bytes)
    }
    @Test func oldSchemaFourTasksMigrateInMemoryWithoutCreatingDuplicateExecution() throws {
        let repository = try repo(), root = repository.root
        let plan = StudyTask(title: "旧作业", startsAt: date("2026-10-12T00:00:00+08:00"), deadline: date("2026-10-16T00:00:00+08:00"))
        var state = LibraryState(); state.schemaVersion = 4; state.tasks = [plan]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        var tasks = json["tasks"] as! [[String: Any]]
        for key in ["origin", "hasExecutionTime", "endsAt", "location", "showInMonth", "repeatRule", "completionRequired", "cancelledAt", "deadlineIsAllDay", "exceptions"] { tasks[0].removeValue(forKey: key) }
        json["tasks"] = tasks
        let bytes = try JSONSerialization.data(withJSONObject: json)
        // Release writer, then emulate an old library in a separate folder.
        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let url = legacyRoot.appendingPathComponent("library.json"); try bytes.write(to: url)
        let migrated = try LibraryRepository(root: legacyRoot)
        #expect(migrated.state.schemaVersion == 5 && !migrated.state.tasks[0].hasExecutionTime)
        #expect(migrated.state.tasks[0].startsAt == plan.startsAt)
        #expect(PlanCalendar.events(on: plan.startsAt, plans: migrated.state.tasks).isEmpty)
        #expect(PlanCalendar.events(on: plan.deadline!, plans: migrated.state.tasks)[0].isDeadline)
        #expect(try Data(contentsOf: url) == bytes)
        try migrated.saveAppearance("dark")
        #expect(try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: url)).schemaVersion == 5)
        #expect(try Data(contentsOf: legacyRoot.appendingPathComponent("library.json.bak")) == bytes)
    }
    @Test func courseMonthPreferenceSurvivesPortalReimport() throws {
        let repository = try repo()
        let input = UndergraduateSchedule(name: "秋", courses: [UndergraduateCourse(name: "数学", weeks: [1,2], weekday: 1, startSection: 1, timeCount: 1)])
        _ = try repository.importUndergraduateTimetable(input)
        let term = repository.state.timetableTerms[0]
        var meeting = term.meetings[0]; meeting.showInMonth = true
        try repository.updateTimetableMeeting(termID: term.id, meeting: meeting)
        _ = try repository.importUndergraduateTimetable(input)
        #expect(repository.state.timetableTerms[0].meetings[0].showInMonth == true)
        #expect(repository.state.timetableTerms[0].meetings[0].id == meeting.id)
    }
    @Test func deletionUndoRestoresParentAndDDLAndDetachesMissingExceptionLinks() throws {
        let repository = try repo(), course = Course(name: "数学")
        try repository.saveCourse(course)
        var plan = weekly(); plan.courseID = course.id
        try repository.saveTask(plan)
        var single = PlanCalendar.snapshot(of: plan, originalDate: plan.startsAt)
        single.title = "临时课"; single.courseID = course.id
        try repository.savePlan(single, originalDate: plan.startsAt, scope: .thisOccurrence)
        try repository.deleteTasks(ids: [plan.id])
        #expect(PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks).isEmpty)
        try repository.deleteCourse(id: course.id)
        try repository.undoTaskDeletion()
        #expect(repository.state.tasks[0].courseID == nil)
        #expect(repository.state.tasks[0].exceptions[0].details?.courseID == nil)
        #expect(PlanCalendar.events(on: plan.deadline!, plans: repository.state.tasks).count == 1)
    }
    @Test func completedSeriesCanReopenOneOccurrenceWithoutChangingItsOtherDates() throws {
        let repository = try repo()
        var plan = weekly(); plan.completedAt = Date()
        try repository.saveTask(plan)
        let original = date("2026-10-19T19:00:00+08:00")
        try repository.setPlanOccurrenceCompleted(id: plan.id, originalDate: original, completed: false)
        let reopened = PlanCalendar.events(on: original, plans: repository.state.tasks)
        #expect(reopened.first?.task.isCompleted == false)
        #expect(PlanCalendar.events(on: plan.startsAt, plans: repository.state.tasks).first?.task.isCompleted == true)
        let ddl = date("2026-10-23T23:59:00+08:00")
        #expect(PlanCalendar.events(on: ddl, plans: repository.state.tasks).first?.task.isCompleted == false)
    }

}
