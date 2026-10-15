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
                sectionCount: 11, times: UndergraduateTimetableDefaults.sectionTimes,
                outerHoursExtraHeight: metrics.outerHoursExtraHeight)
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
            #expect(timeline.height + metrics.headerHeight
                + 2 * metrics.verticalInset <= size.height + 0.001)
        }
    }

    @Test func manualPlansCanSnapInLunchBreakAndNightWithoutASelectedTerm() {
        let timeline = ScheduleWeekTimeline(height: 470, sectionCount: 11, times: [])
        for minute in [15, 375, 480, 630, 780, 840, 1320, 1425] {
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
                #expect(timeline.gridMinutes.contains { abs(timeline.y(for: Double($0)) - course.maxY) < 0.001 })
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

    @Test func removedAllDayBandGivesEqualSpaceToEarlyAndNightWithoutChangingLessonsOrLunch() throws {
        for viewport in [CGSize(width: 552, height: 570), CGSize(width: 752, height: 690)] {
            let metrics = ScheduleWeekMetrics(viewport: viewport, sectionCount: 11)
            let height = metrics.rowHeight * 11
            let extra = metrics.outerHoursExtraHeight
            let old = ScheduleWeekTimeline(height: height - extra, sectionCount: 11, times: [])
            let current = ScheduleWeekTimeline(height: height, sectionCount: 11, times: [], outerHoursExtraHeight: extra)
            #expect(abs(current.y(for: 480) - old.y(for: 480) - extra / 2) < 0.001)
            #expect(abs((current.height - current.y(for: 1280)) - (old.height - old.y(for: 1280)) - extra / 2) < 0.001)
            for section in 1...11 {
                let oldRect = try #require(old.sectionRect(start: section, count: 1))
                let newRect = try #require(current.sectionRect(start: section, count: 1))
                #expect(abs(oldRect.height - newRect.height) < 0.001)
                #expect(abs(newRect.minY - oldRect.minY - extra / 2) < 0.001)
            }
            #expect(abs((current.y(for: 840) - current.y(for: 720)) - (old.y(for: 840) - old.y(for: 720))) < 0.001)
            for minute in [15, 375, 480, 780, 1320, 1425] {
                #expect(current.minute(at: current.y(for: Double(minute))) == minute)
            }
        }
    }

    @Test func shortPlansBeforeClassDoNotCreateFalseCourseConflicts() throws {
        for height: CGFloat in [468, 588] {
            let timeline = ScheduleWeekTimeline(height: height, sectionCount: 11, times: [])
            for (start, end, section) in [(360.0, 420.0, 1), (835.0, 839.0, 5)] {
                let plan = timeline.intervalRect(start: start, end: end, minimumHeight: 13)
                let course = try #require(timeline.sectionRect(start: section, count: 2))
                #expect(plan.minY == timeline.y(for: start))
                #expect(plan.height > 0)
                #expect(plan.maxY <= course.minY)
                let lanes = ScheduleWeekLanes.placements([
                    .init(id: "plan", top: plan.minY, bottom: plan.maxY),
                    .init(id: "course", top: course.minY, bottom: course.maxY)
                ])
                #expect(lanes.allSatisfy { $0.laneCount == 1 })
            }
        }
    }

    @Test func smallBreaksCollapseAndTheirFormerHeightBelongsToLunch() throws {
        let timeline = ScheduleWeekTimeline(height: 468, sectionCount: 11, times: [])
        #expect(timeline.lunchBreak == 720..<840)
        for (previous, next) in zip(timeline.times, timeline.times.dropFirst()) where previous.endMinute != 720 {
            #expect(timeline.y(for: Double(previous.endMinute)) == timeline.y(for: Double(next.startMinute)))
            // Dragging onto a shared line chooses the following period, not
            // the hidden previous end or one of the collapsed break minutes.
            #expect(timeline.minute(at: timeline.y(for: Double(next.startMinute)), snapping: 1) == next.startMinute)
            #expect(!timeline.gridMinutes.contains(previous.endMinute))
        }
        let first = try #require(timeline.sectionRect(start: 1, count: 1))
        let lunchHeight = timeline.y(for: 840) - timeline.y(for: 720)
        // Former lunch (0.4 periods) + nine short breaks (0.14 each).
        #expect(abs(lunchHeight / first.height - 1.66) < 0.001)
        #expect(abs(timeline.y(for: 480) / first.height - 0.65) < 0.001)
    }

    @Test func customLunchTimesKeepTheirOwnExpandedInterval() {
        var times = UndergraduateTimetableDefaults.sectionTimes
        times[3].endMinute = 735
        times[4].startMinute = 810
        let timeline = ScheduleWeekTimeline(height: 468, sectionCount: 11, times: times)
        #expect(timeline.lunchBreak == 735..<810)
        #expect(timeline.gridMinutes.contains(735))
        #expect(timeline.y(for: 735) < timeline.y(for: 780))
        #expect(timeline.y(for: 780) < timeline.y(for: 810))
        #expect(timeline.minute(at: timeline.y(for: 780)) == 780)
    }
}
