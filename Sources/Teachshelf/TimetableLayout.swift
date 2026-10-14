import Foundation
import TeachshelfCore

/// Meetings in one overlapping group share the available day column.
struct TimetablePlacement: Identifiable {
    let meeting: TimetableMeeting
    let lane: Int
    let laneCount: Int
    var id: UUID { meeting.id }
}

enum TimetableLayout {
    static func sectionCount(in term: TimetableTerm?) -> Int {
        max(UndergraduateTimetableDefaults.sectionTimes.last?.section ?? 11,
            max(max(term?.meetings.filter(\.isScheduled).map(\.endSection).max() ?? 0,
                    term?.reschedules.map(\.meeting.endSection).max() ?? 0),
                term?.sectionTimes.map(\.section).max() ?? 0))
    }

    static func placements(_ meetings: [TimetableMeeting]) -> [TimetablePlacement] {
        let sorted = meetings.filter(\.isScheduled).sorted {
            if $0.startSection != $1.startSection { return $0.startSection < $1.startSection }
            if $0.endSection != $1.endSection { return $0.endSection < $1.endSection }
            return $0.id.uuidString < $1.id.uuidString
        }
        var groups: [[TimetableMeeting]] = []
        var groupEnd = 0
        for meeting in sorted {
            if groups.isEmpty || meeting.startSection > groupEnd {
                groups.append([meeting]); groupEnd = meeting.endSection
            } else {
                groups[groups.count - 1].append(meeting)
                groupEnd = max(groupEnd, meeting.endSection)
            }
        }
        return groups.flatMap { group in
            var laneEnds: [Int] = []
            var lanes: [Int] = []
            for meeting in group {
                if let lane = laneEnds.firstIndex(where: { $0 < meeting.startSection }) {
                    laneEnds[lane] = meeting.endSection; lanes.append(lane)
                } else {
                    lanes.append(laneEnds.count); laneEnds.append(meeting.endSection)
                }
            }
            return zip(group, lanes).map { TimetablePlacement(meeting: $0.0, lane: $0.1, laneCount: laneEnds.count) }
        }
    }

    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    static func sectionLabel(_ meeting: TimetableMeeting) -> String {
        guard meeting.isScheduled else { return "自由时间" }
        return meeting.sectionCount == 1 ? "第 \(meeting.startSection) 节" : "第 \(meeting.startSection)–\(meeting.endSection) 节"
    }

    static func weekdayLabel(_ weekday: Int?) -> String {
        guard let weekday, (1...7).contains(weekday) else { return "自由时间" }
        return ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][weekday - 1]
    }

    static func timeLabel(_ meeting: TimetableMeeting, in term: TimetableTerm) -> String? {
        guard let first = term.sectionTimes.first(where: { $0.section == meeting.startSection }),
              let last = term.sectionTimes.first(where: { $0.section == meeting.endSection }) else { return nil }
        return "\(clock(first.startMinute))–\(clock(last.endMinute))"
    }

    static func weeksLabel(_ weeks: [Int]) -> String {
        let sorted = Array(Set(weeks)).sorted()
        guard let first = sorted.first else { return "未指定周次" }
        var ranges: [String] = []
        var start = first, end = first
        for week in sorted.dropFirst() {
            if week == end + 1 { end = week }
            else { ranges.append(start == end ? "\(start)" : "\(start)–\(end)"); start = week; end = week }
        }
        ranges.append(start == end ? "\(start)" : "\(start)–\(end)")
        return "第 \(ranges.joined(separator: "、")) 周"
    }

    static var academicCalendar: Calendar { TimetableTerm.academicCalendar }

    static func dateLabel(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.month(.twoDigits).day(.twoDigits)
        style.timeZone = academicCalendar.timeZone
        return date.formatted(style)
    }
}
