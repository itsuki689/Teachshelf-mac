import CoreGraphics
import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

struct ScheduleWeekFitTests {
    @Test func allElevenPeriodsAndSundayRemainVisibleBesideTheInspector() {
        // Available chart sizes after the app sidebar, inspector, navigation and
        // status bar at the minimum and default window sizes.
        for viewport in [CGSize(width: 552, height: 570), CGSize(width: 752, height: 690)] {
            let metrics = ScheduleWeekMetrics(viewport: viewport, sectionCount: 11)
            let calendar = TimetableTerm.academicCalendar
            let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
            let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: monday)! }
            let term = TimetableTerm(name: "秋季", weekOneMonday: monday)
            let grid = ScheduleDragGrid(labelWidth: metrics.labelWidth, columnWidth: metrics.columnWidth,
                rowHeight: metrics.rowHeight, sectionCount: 11, days: days)

            #expect(grid.width + 2 * metrics.horizontalInset <= viewport.width + 0.001)
            #expect(grid.height + metrics.headerHeight + 2 * metrics.verticalInset <= viewport.height + 0.001)
            #expect(metrics.rowHeight >= 42)
            #expect(metrics.timeColumnWidth >= 48)
            #expect(metrics.sectionColumnWidth >= 52)
            #expect(metrics.labelWidth == metrics.timeColumnWidth + metrics.sectionColumnWidth)
            #expect(metrics.columnWidth >= 61)
            let bottomRight = CGPoint(x: grid.width - 1, y: grid.height - 1)
            let target = grid.target(at: bottomRight, grabOffsetY: 0, duration: 1, term: term)
            #expect(target?.dayIndex == 6)
            #expect(target?.startSection == 11)
            if let target {
                let card = grid.rect(for: target)
                #expect(card.maxY <= grid.height)
                #expect(card.maxX <= grid.width)
            }
        }
    }

    @Test func customPeriodCountsAndTransientZeroSizesDoNotCreateOverflow() {
        for sections in [1, 11, 16, 30] {
            let viewport = CGSize(width: 552, height: 570)
            let metrics = ScheduleWeekMetrics(viewport: viewport, sectionCount: sections)
            #expect(metrics.rowHeight * CGFloat(sections) + metrics.headerHeight
                    + 2 * metrics.verticalInset <= viewport.height + 0.001)
            #expect(metrics.rowHeight > 0)
        }
        for viewport in [CGSize.zero, CGSize(width: -10, height: -5),
                         CGSize(width: CGFloat.infinity, height: CGFloat.nan)] {
            let metrics = ScheduleWeekMetrics(viewport: viewport, sectionCount: 0)
            #expect(metrics.rowHeight.isFinite && metrics.rowHeight >= 0)
            #expect(metrics.columnWidth.isFinite && metrics.columnWidth >= 0)
        }
    }

    @Test func allPlanEdgesFillTheExactDayAndConflictLaneBoundaries() {
        for viewport in [CGSize(width: 552, height: 570), CGSize(width: 752, height: 690)] {
            let metrics = ScheduleWeekMetrics(viewport: viewport, sectionCount: 11)
            for day in 0..<7 {
                for count in 1...3 {
                    for lane in 0..<count {
                        let rect = metrics.eventRect(dayIndex: day, lane: lane, laneCount: count,
                                                     top: 100, height: 60)
                        let width = metrics.columnWidth / CGFloat(count)
                        #expect(abs(rect.minX - (metrics.labelWidth + CGFloat(day) * metrics.columnWidth + CGFloat(lane) * width)) < 0.001)
                        #expect(abs(rect.maxX - (metrics.labelWidth + CGFloat(day) * metrics.columnWidth + CGFloat(lane + 1) * width)) < 0.001)
                        #expect(rect.minY == 100 && rect.height == 60)
                    }
                }
            }
        }
    }
}
