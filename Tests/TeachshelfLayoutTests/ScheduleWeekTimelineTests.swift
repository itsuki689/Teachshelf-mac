import CoreGraphics
import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

struct ScheduleWeekTimelineTests {
    @Test func allPeriodsBreaksAndHoursOutsideTeachingRemainInsideTheCanvas() {
        for size in [CGSize(width: 552, height: 570), CGSize(width: 752, height: 690)] {
            let metrics = ScheduleWeekMetrics(viewport: size, sectionCount: 11)
            let timeline = ScheduleWeekTimeline(height: metrics.rowHeight * 11,
                sectionCount: 11, times: UndergraduateTimetableDefaults.sectionTimes)
            #expect(timeline.times.count == 11)
            #expect(timeline.y(for: 0) == 0)
            #expect(abs(timeline.y(for: 1440) - timeline.height) < 0.001)
            #expect(timeline.y(for: 480) > 0) // Early plans remain reachable.
            #expect(timeline.y(for: 780) > timeline.y(for: 720)) // Lunch is not a zero-height gap.
            #expect(timeline.y(for: 780) < timeline.y(for: 840))
            #expect(timeline.y(for: 1280) < timeline.height) // Night plans remain reachable.
            for section in 1...11 {
                let rect = timeline.sectionRect(start: section, count: 1)!
                #expect(rect.height >= 30)
                #expect(rect.minY >= 0 && rect.maxY <= timeline.height + 0.001)
                #expect(timeline.section(at: rect.minY, duration: 1) == section)
            }
            #expect(timeline.height + metrics.headerHeight + metrics.allDayHeight
                + 2 * metrics.verticalInset <= size.height + 0.001)
        }
    }

    @Test func manualPlansCanSnapInLunchBreakAndNightWithoutASelectedTerm() {
        let timeline = ScheduleWeekTimeline(height: 470, sectionCount: 11, times: [])
        for minute in [15, 375, 480, 600, 780, 840, 1320, 1425] {
            #expect(timeline.minute(at: timeline.y(for: Double(minute))) == minute)
        }
        #expect(timeline.minute(at: -.infinity) == nil)
        #expect(timeline.minute(at: 470) == nil)
        #expect(timeline.sectionRect(start: 11, count: 2) == nil)
        #expect(timeline.section(at: 469, duration: 2) == 10)
    }

    @Test func compressedActivityCardsHaveDistinctClickableLanes() {
        let lanes = ScheduleWeekLanes.placements([
            .init(id: "course", top: 100, bottom: 180),
            .init(id: "lunch", top: 170, bottom: 183),
            .init(id: "next", top: 183, bottom: 220)
        ])
        #expect(lanes.count == 3)
        let course = lanes.first { $0.id == "course" }!
        let lunch = lanes.first { $0.id == "lunch" }!
        #expect(course.lane != lunch.lane)
        #expect(course.laneCount == 2 && lunch.laneCount == 2)
        #expect(lanes.first { $0.id == "next" }?.laneCount == 1)
    }

    @Test func courseAndActivityBoundsShareEveryVisibleClockBoundary() throws {
        for height: CGFloat in [468, 588] {
            let timeline = ScheduleWeekTimeline(height: height, sectionCount: 11,
                times: UndergraduateTimetableDefaults.sectionTimes)
            for time in timeline.times {
                let course = try #require(timeline.sectionRect(start: time.section, count: 1))
                let activity = timeline.intervalRect(start: Double(time.startMinute), end: Double(time.endMinute), minimumHeight: 13)
                #expect(course == activity)
                #expect(timeline.gridMinutes.contains(time.startMinute))
                #expect(timeline.gridMinutes.contains(time.endMinute))
                #expect(course.minY == timeline.y(for: Double(time.startMinute)))
                #expect(abs(course.maxY - timeline.y(for: Double(time.endMinute))) < 0.001)
            }
            let last = try #require(timeline.sectionRect(start: 11, count: 1))
            #expect(timeline.gridMinutes.last == 1280) // 21:20 separates period 11 and night.
            #expect(abs(last.maxY - timeline.y(for: 1280)) < 0.001)
            #expect(last.maxY < height)
        }
    }

    @Test func compactNightCardsKeepTheirActualStartWhenSpaceBelowIsShort() {
        let timeline = ScheduleWeekTimeline(height: 468, sectionCount: 11, times: [])
        let card = timeline.intervalRect(start: 1425, end: 1440, minimumHeight: 13)
        #expect(card.minY == timeline.y(for: 1425))
        #expect(card.height > 0 && card.height < 13)
        #expect(abs(card.maxY - timeline.height) < 0.001)
    }
}
