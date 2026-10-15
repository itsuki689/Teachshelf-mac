import Foundation
import Testing
@testable import TeachshelfCore

struct PlanTimeEditingTests {
    private let calendar = PlanCalendar.calendar
    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func snappedEdgesRemainInsideOneDayAndNeverInvertTheInterval() throws {
        for (start, end) in [(0, 31), (727, 797), (1435, 1440)] {
            let range = try #require(PlanTimeRange(start: start, end: end))
            for minute in stride(from: -20, through: 1460, by: 7) {
                let first = range.resized(.start, to: minute)
                let last = range.resized(.end, to: minute)
                #expect(first.start >= 0 && first.start < first.end && first.end == end)
                #expect(last.start == start && last.start < last.end && last.end <= 1440)
                #expect(first.start % 10 == 0 && last.end % 10 == 0)
            }
        }
        let range = try #require(PlanTimeRange(start: 720, end: 780))
        #expect(range.resized(.start, to: 726).start == 730)
        #expect(range.resized(.end, to: 784).end == 780)
        #expect(range.resized(.end, to: 781, snapping: 1).end == 781)
        #expect(PlanTimeRange(start: 1400, end: 1441) == nil)
        #expect(PlanTimeRange(start: 700, end: 700) == nil)
    }

    @Test func wholeMovesPreserveDurationAndRespectBothMidnightBoundaries() throws {
        let range = try #require(PlanTimeRange(start: 720, end: 757))
        #expect(range.shifted(by: 10) == PlanTimeRange(start: 730, end: 767))
        #expect(range.shifted(by: -721) == nil)
        #expect(range.shifted(by: 684) == nil)
        let latest = range.moved(to: 1440)
        #expect(latest.start == 1400 && latest.end == 1437)
        #expect(range.moved(to: -10).start == 0)
        #expect(range.moved(to: 728).start == 730)
    }

    @Test func resizingOneRepeatedOccurrenceLeavesItsDeadlineAndOtherWeeksUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-resize-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let plan = StudyTask(title: "复习", startsAt: date(15, 12), deadline: date(15, 20), isAllDay: false,
                             endsAt: date(15, 13), repeatRule: .init(frequency: .weekly), colorHex: "#8058A1")
        try repository.savePlan(plan)
        try repository.setPlanOccurrenceTime(id: plan.id, originalDate: date(22, 12), day: date(22),
                                              range: try #require(PlanTimeRange(start: 670, end: 800)))
        let parent = try #require(repository.state.tasks.first)
        let resized = PlanCalendar.snapshot(of: parent, originalDate: date(22, 12))
        #expect(resized.startsAt == date(22, 11, 10) && resized.endsAt == date(22, 13, 20))
        #expect(resized.deadline == date(22, 20) && resized.colorHex == "#8058A1")
        #expect(parent.startsAt == plan.startsAt && parent.endsAt == plan.endsAt)
        #expect(PlanCalendar.snapshot(of: parent, originalDate: date(29, 12)).startsAt == date(29, 12))
        #expect(try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json"))) == repository.state)
    }

    @Test func customColorsSupportSingleOccurrenceOverridesExplicitResetAndLegacyData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-colors-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let plan = StudyTask(title: "阅读", startsAt: date(15, 12), isAllDay: false, endsAt: date(15, 13),
                             repeatRule: .init(frequency: .weekly), colorHex: "#3B72B8")
        try repository.savePlan(plan)
        var single = PlanCalendar.snapshot(of: plan, originalDate: date(22, 12)); single.colorHex = "#AE567C"
        try repository.savePlan(single, originalDate: date(22, 12), scope: .thisOccurrence)
        var parent = try #require(repository.state.tasks.first); parent.colorHex = "#39786B"
        try repository.savePlan(parent)
        parent = try #require(repository.state.tasks.first)
        #expect(PlanCalendar.snapshot(of: parent, originalDate: date(22, 12)).colorHex == "#AE567C")
        #expect(PlanCalendar.snapshot(of: parent, originalDate: date(29, 12)).colorHex == "#39786B")
        single = PlanCalendar.snapshot(of: parent, originalDate: date(22, 12)); single.colorHex = nil
        try repository.savePlan(single, originalDate: date(22, 12), scope: .thisOccurrence)
        let reloaded = try #require(try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json"))).tasks.first)
        #expect(PlanCalendar.snapshot(of: reloaded, originalDate: date(22, 12)).colorHex == nil)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        legacy.removeValue(forKey: "colorHex")
        let decoded = try JSONDecoder().decode(StudyTask.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.colorHex == nil)
        var invalid = parent; invalid.colorHex = "bad-color"
        #expect(throws: (any Error).self) { try repository.savePlan(invalid) }
    }
}
