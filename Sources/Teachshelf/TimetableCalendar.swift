import Foundation
import TeachshelfCore

/// Projects academic weeks onto civil dates in Nanjing, independently of the Mac's time zone.
enum TimetableCalendar {
    static var calendar: Calendar { TimetableTerm.academicCalendar }

    struct DayClass: Identifiable, Hashable {
        var termID: UUID
        var termName: String
        var meeting: TimetableMeeting
        var day: Date
        var timeLabel: String?
        var sourceDate: Date? = nil
        var rescheduleID: UUID? = nil
        var originalDate: Date { sourceDate ?? day }
        var id: String { "\(termID.uuidString)-\(meeting.id.uuidString)-\(Int(originalDate.timeIntervalSince1970))" }
        var sectionLabel: String {
            meeting.sectionCount == 1 ? "第 \(meeting.startSection) 节" : "第 \(meeting.startSection)–\(meeting.endSection) 节"
        }
    }

    static func classes(on day: Date, terms: [TimetableTerm], courseID: UUID? = nil) -> [DayClass] {
        let day = calendar.startOfDay(for: day)
        return terms.flatMap { term -> [DayClass] in
            return term.occurrences(on: day).compactMap { occurrence in
                let meeting = occurrence.meeting
                guard courseID == nil || meeting.courseID == courseID else { return nil }
                return DayClass(termID: term.id, termName: term.name, meeting: meeting, day: occurrence.date,
                                timeLabel: timeLabel(for: meeting, sectionTimes: term.sectionTimes),
                                sourceDate: occurrence.originalDate, rescheduleID: occurrence.rescheduleID)
            }
        }.sorted {
            if $0.meeting.startSection != $1.meeting.startSection { return $0.meeting.startSection < $1.meeting.startSection }
            if $0.meeting.endSection != $1.meeting.endSection { return $0.meeting.endSection < $1.meeting.endSection }
            return $0.meeting.title.localizedStandardCompare($1.meeting.title) == .orderedAscending
        }
    }

    static func timeLabel(for meeting: TimetableMeeting, sectionTimes: [TimetableSectionTime]) -> String? {
        guard let range = meeting.timeRange(sectionTimes: sectionTimes) else { return nil }
        return "\(clock(range.start))–\(clock(range.end))"
    }

    static func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
