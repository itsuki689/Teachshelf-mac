import Foundation
import CoreGraphics
import TeachshelfCore

/// A drop is a civil date plus a section range, rather than a change to the
/// recurring meeting. Keeping this calculation separate makes grid boundaries
/// and partial semester weeks deterministic.
struct ScheduleDropTarget: Equatable {
    let date: Date
    let dayIndex: Int
    let startSection: Int
    let sectionCount: Int
}

struct ScheduleDragGrid {
    let labelWidth: CGFloat
    let columnWidth: CGFloat
    let rowHeight: CGFloat
    let sectionCount: Int
    let days: [Date]
    var visibleRect: CGRect? = nil

    var width: CGFloat { labelWidth + 7 * columnWidth }
    var height: CGFloat { CGFloat(sectionCount) * rowHeight }

    func target(at point: CGPoint, grabOffsetY: CGFloat, duration: Int, term: TimetableTerm) -> ScheduleDropTarget? {
        guard point.x.isFinite, point.y.isFinite, grabOffsetY.isFinite,
              labelWidth.isFinite, columnWidth.isFinite, rowHeight.isFinite,
              labelWidth >= 0, columnWidth > 0, rowHeight > 0,
              width.isFinite, height.isFinite,
              duration > 0, duration <= sectionCount, days.count == 7,
              point.x >= labelWidth, point.x < width, point.y >= 0, point.y < height else { return nil }
        if let visibleRect, !visibleRect.contains(point) { return nil }
        let dayIndex = Int((point.x - labelWidth) / columnWidth)
        guard days.indices.contains(dayIndex) else { return nil }
        let date = days[dayIndex]
        guard term.week(containing: date) != nil else { return nil }
        let rawSection = ((point.y - grabOffsetY) / rowHeight).rounded() + 1
        let boundedSection = max(1, min(CGFloat(sectionCount - duration + 1), rawSection))
        return ScheduleDropTarget(date: date, dayIndex: dayIndex,
                                  startSection: Int(boundedSection), sectionCount: duration)
    }

    func rect(for target: ScheduleDropTarget) -> CGRect {
        CGRect(x: labelWidth + CGFloat(target.dayIndex) * columnWidth + 3,
               y: CGFloat(target.startSection - 1) * rowHeight + 3,
               width: max(1, columnWidth - 6), height: CGFloat(target.sectionCount) * rowHeight - 6)
    }
}

struct ScheduleOccurrencePlacement: Identifiable {
    let event: TimetableCalendar.DayClass
    let dayIndex: Int
    let lane: Int
    let laneCount: Int
    var id: String { event.id }
}

enum ScheduleDragLayout {
    /// Two occurrences of the same recurring meeting may land on the same day.
    /// Lane assignment therefore uses occurrence identity, never meeting ID.
    static func placements(_ events: [TimetableCalendar.DayClass], dayIndex: Int) -> [ScheduleOccurrencePlacement] {
        let sorted = events.filter { $0.meeting.isScheduled }.sorted {
            if $0.meeting.startSection != $1.meeting.startSection { return $0.meeting.startSection < $1.meeting.startSection }
            if $0.meeting.endSection != $1.meeting.endSection { return $0.meeting.endSection < $1.meeting.endSection }
            return $0.id < $1.id
        }
        var groups: [[TimetableCalendar.DayClass]] = []
        var groupEnd = 0
        for event in sorted {
            if groups.isEmpty || event.meeting.startSection > groupEnd {
                groups.append([event]); groupEnd = event.meeting.endSection
            } else {
                groups[groups.count - 1].append(event)
                groupEnd = max(groupEnd, event.meeting.endSection)
            }
        }
        return groups.flatMap { group in
            var laneEnds: [Int] = []
            var lanes: [Int] = []
            for event in group {
                if let lane = laneEnds.firstIndex(where: { $0 < event.meeting.startSection }) {
                    laneEnds[lane] = event.meeting.endSection; lanes.append(lane)
                } else {
                    lanes.append(laneEnds.count); laneEnds.append(event.meeting.endSection)
                }
            }
            return zip(group, lanes).map {
                ScheduleOccurrencePlacement(event: $0.0, dayIndex: dayIndex, lane: $0.1, laneCount: laneEnds.count)
            }
        }
    }
}
