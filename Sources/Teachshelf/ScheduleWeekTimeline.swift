import Foundation
import CoreGraphics
import TeachshelfCore

/// A whole day in a bounded canvas. Teaching periods have equal visual weight;
/// breaks and the hours before/after teaching remain visible, at a smaller scale.
struct ScheduleWeekTimeline {
    struct Segment {
        let start: Double
        let end: Double
        let lower: CGFloat
        let upper: CGFloat
    }

    let height: CGFloat
    let times: [TimetableSectionTime]
    let segments: [Segment]

    init(height: CGFloat, sectionCount: Int, times supplied: [TimetableSectionTime]) {
        let resolvedHeight = height.isFinite ? max(0, height) : 0
        self.height = resolvedHeight
        let defaults = UndergraduateTimetableDefaults.sectionTimes
        var times: [TimetableSectionTime] = []
        for section in 1...max(1, sectionCount) {
            if let time = supplied.first(where: { $0.section == section }),
               time.startMinute >= 0, time.endMinute <= 1440, time.startMinute < time.endMinute {
                times.append(time)
            } else if let fallback = defaults.first(where: { $0.section == section }) {
                times.append(fallback)
            } else if let previous = times.last, previous.endMinute + 10 < 1440 {
                let start = previous.endMinute + 10
                times.append(.init(section: section, startMinute: start, endMinute: min(1440, start + 50)))
            }
        }
        self.times = times.sorted { $0.startMinute < $1.startMinute }
        // Use interval boundaries rather than assuming a particular campus's
        // lunch break, so custom section clocks remain a monotonic mapping.
        let boundaries = Array(Set([0, 1440] + times.flatMap { [$0.startMinute, $0.endMinute] })).sorted()
        let first = times.map(\.startMinute).min() ?? 480
        let last = times.map(\.endMinute).max() ?? 1280
        let weighted = zip(boundaries, boundaries.dropFirst()).map { start, end -> (Double, Double, CGFloat) in
            let teaching = times.contains { $0.startMinute <= start && $0.endMinute >= end }
            let weight: CGFloat
            if teaching { weight = CGFloat(end - start) / 50 }
            else if end <= first || start >= last { weight = 0.65 }
            else { weight = min(0.45, max(0.14, CGFloat(end - start) / 300)) }
            return (Double(start), Double(end), weight)
        }
        let total = max(1, weighted.reduce(CGFloat.zero) { $0 + $1.2 })
        var offset: CGFloat = 0
        self.segments = weighted.map { start, end, weight in
            let lower = offset
            offset += resolvedHeight * weight / total
            return Segment(start: start, end: end, lower: lower, upper: offset)
        }
    }

    func y(for minute: Double) -> CGFloat {
        guard minute.isFinite else { return 0 }
        let bounded = max(0, min(1440, minute))
        guard let segment = segments.first(where: { bounded <= $0.end }) else { return height }
        let ratio = (bounded - segment.start) / max(1, segment.end - segment.start)
        return segment.lower + (segment.upper - segment.lower) * CGFloat(ratio)
    }

    func minute(at y: CGFloat, snapping: Int = 15) -> Int? {
        guard y.isFinite, height > 0, y >= 0, y < height,
              let segment = segments.first(where: { y <= $0.upper && $0.upper > $0.lower }) else { return nil }
        let ratio = Double((y - segment.lower) / (segment.upper - segment.lower))
        let raw = segment.start + (segment.end - segment.start) * ratio
        let step = Double(max(1, snapping))
        return max(0, min(1439, Int((raw / step).rounded()) * max(1, snapping)))
    }

    func sectionRect(start: Int, count: Int) -> CGRect? {
        guard let first = times.first(where: { $0.section == start }),
              let last = times.first(where: { $0.section == start + count - 1 }) else { return nil }
        let top = y(for: Double(first.startMinute)), bottom = y(for: Double(last.endMinute))
        return CGRect(x: 0, y: top, width: 0, height: max(1, bottom - top))
    }

    func section(at y: CGFloat, duration: Int) -> Int? {
        guard y.isFinite, y >= 0, y < height, duration > 0 else { return nil }
        return times.filter { sectionRect(start: $0.section, count: duration) != nil }
            .min { abs(self.y(for: Double($0.startMinute)) - y) < abs(self.y(for: Double($1.startMinute)) - y) }?.section
    }
}

struct ScheduleWeekSpan: Identifiable {
    let id: String
    let top: CGFloat
    let bottom: CGFloat
}

struct ScheduleWeekLane: Identifiable {
    let id: String
    let lane: Int
    let laneCount: Int
}

enum ScheduleWeekLanes {
    /// Use the rendered bounds, so tiny activities in compressed breaks can
    /// never cover the neighbouring course's clickable card.
    static func placements(_ spans: [ScheduleWeekSpan]) -> [ScheduleWeekLane] {
        let sorted = spans.sorted {
            if $0.top != $1.top { return $0.top < $1.top }
            if $0.bottom != $1.bottom { return $0.bottom < $1.bottom }
            return $0.id < $1.id
        }
        var groups: [[ScheduleWeekSpan]] = []
        var end = -CGFloat.infinity
        for span in sorted {
            if groups.isEmpty || span.top >= end { groups.append([span]); end = span.bottom }
            else { groups[groups.count - 1].append(span); end = max(end, span.bottom) }
        }
        return groups.flatMap { group in
            var ends: [CGFloat] = []
            let laneNumbers = group.map { span -> Int in
                if let lane = ends.firstIndex(where: { $0 <= span.top }) {
                    ends[lane] = span.bottom; return lane
                }
                ends.append(span.bottom); return ends.count - 1
            }
            return zip(group, laneNumbers).map { ScheduleWeekLane(id: $0.0.id, lane: $0.1, laneCount: ends.count) }
        }
    }
}
