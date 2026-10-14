import Foundation

/// The undergraduate portal's JSON contract. `time_count` is an end-offset:
/// sections 3–4 have start_time 3 and time_count 1.
public struct UndergraduateSchedule: Codable, Hashable, Sendable {
    public var name: String
    public var courses: [UndergraduateCourse]
    public var warnings: [String]

    public init(name: String, courses: [UndergraduateCourse], warnings: [String] = []) {
        self.name = name; self.courses = courses; self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey { case name, courses, warnings }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        courses = try values.decode([UndergraduateCourse].self, forKey: .courses)
        warnings = values.contains(.warnings) ? try values.decode([String].self, forKey: .warnings) : []
    }
}

public struct UndergraduateCourse: Codable, Hashable, Sendable {
    public var name: String
    public var classroom: String?
    public var classNumber: String?
    public var teacher: String?
    public var weeks: [Int]
    public var weekday: Int?
    public var startSection: Int
    public var timeCount: Int
    public var examTime: String?
    public var examLocation: String?
    public var info: String?

    public init(name: String, classroom: String? = nil, classNumber: String? = nil, teacher: String? = nil, weeks: [Int], weekday: Int? = nil, startSection: Int = 0, timeCount: Int = 0, examTime: String? = nil, examLocation: String? = nil, info: String? = nil) {
        self.name = name; self.classroom = classroom; self.classNumber = classNumber; self.teacher = teacher
        self.weeks = weeks; self.weekday = weekday; self.startSection = startSection; self.timeCount = timeCount
        self.examTime = examTime; self.examLocation = examLocation; self.info = info
    }

    public var endSection: Int { Self.safeSum(startSection, timeCount) }
    public var sectionCount: Int { startSection > 0 ? Self.safeSum(timeCount, 1) : 0 }
    public var isScheduled: Bool { weekday.map { (1...7).contains($0) } == true && startSection > 0 }
    public var displayPeriod: String {
        guard isScheduled, let weekday else { return "自由时间" }
        let days = ["一", "二", "三", "四", "五", "六", "日"]
        let sections = endSection == startSection ? "第 \(startSection) 节" : "第 \(startSection)–\(endSection) 节"
        return "周\(days[weekday - 1]) · \(sections)"
    }

    private static func safeSum(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private enum CodingKeys: String, CodingKey {
        case name, classroom, teacher, weeks, info
        case classNumber = "class_number", weekday = "week_time", startSection = "start_time", timeCount = "time_count"
        case examTime = "test_time", examLocation = "test_location"
    }
}

public struct TimetableSectionTime: Codable, Hashable, Sendable {
    public var section: Int
    public var startMinute: Int
    public var endMinute: Int

    public init(section: Int, startMinute: Int, endMinute: Int) {
        self.section = section; self.startMinute = startMinute; self.endMinute = endMinute
    }
}

/// An optional convenience preset transcribed from the user's undergraduate
/// timetable screenshot. Apply only after an explicit user selection; this is
/// not a claim that every campus or semester uses one official time schedule.
public enum UndergraduateTimetableDefaults {
    public static let sectionTimes: [TimetableSectionTime] = [
        .init(section: 1, startMinute: 480, endMinute: 530),
        .init(section: 2, startMinute: 540, endMinute: 590),
        .init(section: 3, startMinute: 610, endMinute: 660),
        .init(section: 4, startMinute: 670, endMinute: 720),
        .init(section: 5, startMinute: 840, endMinute: 890),
        .init(section: 6, startMinute: 900, endMinute: 950),
        .init(section: 7, startMinute: 970, endMinute: 1020),
        .init(section: 8, startMinute: 1030, endMinute: 1080),
        .init(section: 9, startMinute: 1110, endMinute: 1160),
        .init(section: 10, startMinute: 1170, endMinute: 1220),
        .init(section: 11, startMinute: 1230, endMinute: 1280)
    ]
}

public struct TimetableMeeting: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var courseID: UUID?
    public var courseCode: String
    public var title: String
    public var teacher: String
    public var classroom: String
    public var weeks: [Int]
    public var weekday: Int?
    public var startSection: Int
    public var sectionCount: Int
    public var note: String

    public init(id: UUID = UUID(), courseID: UUID? = nil, courseCode: String = "", title: String, teacher: String = "", classroom: String = "", weeks: [Int], weekday: Int? = nil, startSection: Int = 0, sectionCount: Int = 0, note: String = "") {
        self.id = id; self.courseID = courseID; self.courseCode = courseCode; self.title = title
        self.teacher = teacher; self.classroom = classroom; self.weeks = weeks; self.weekday = weekday
        self.startSection = startSection; self.sectionCount = sectionCount; self.note = note
    }

    public var isScheduled: Bool { weekday.map { (1...7).contains($0) } == true && startSection > 0 && sectionCount > 0 }
    public var endSection: Int {
        guard sectionCount > 0 else { return 0 }
        let result = startSection.addingReportingOverflow(sectionCount - 1)
        return result.overflow ? Int.max : result.partialValue
    }
}

/// A reversible exception for one civil occurrence, independent of its
/// recurring meeting's week rules. The title retains context after reimports.
public struct TimetableCancellation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var date: Date
    public var title: String
    public var reason: String
    public var savedReschedule: TimetableReschedule?

    public init(id: UUID = UUID(), meetingID: UUID, date: Date, title: String, reason: String = "", savedReschedule: TimetableReschedule? = nil) {
        self.id = id; self.meetingID = meetingID; self.date = date
        self.title = title; self.reason = reason; self.savedReschedule = savedReschedule
    }
}

/// A one-off arrangement keeps its own snapshot if a later portal import no
/// longer contains the original recurring session.
public struct TimetableReschedule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var originalDate: Date
    public var date: Date
    public var meeting: TimetableMeeting

    public init(id: UUID = UUID(), meetingID: UUID, originalDate: Date, date: Date, meeting: TimetableMeeting) {
        self.id = id; self.meetingID = meetingID; self.originalDate = originalDate
        self.date = date; self.meeting = meeting
    }
}

public struct TimetableOccurrence: Identifiable, Hashable, Sendable {
    public var meeting: TimetableMeeting
    public var date: Date
    public var originalDate: Date
    public var rescheduleID: UUID?
    public var id: String { "\(meeting.id.uuidString)-\(originalDate.timeIntervalSinceReferenceDate)" }

    public init(meeting: TimetableMeeting, date: Date, originalDate: Date, rescheduleID: UUID? = nil) {
        self.meeting = meeting; self.date = date; self.originalDate = originalDate; self.rescheduleID = rescheduleID
    }
}

public struct TimetableTerm: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var weekOneMonday: Date?
    public var weekCount: Int
    public var endDate: Date?
    public var sectionTimes: [TimetableSectionTime]
    public var meetings: [TimetableMeeting]
    public var cancellations: [TimetableCancellation]
    public var reschedules: [TimetableReschedule]

    public init(id: UUID = UUID(), name: String, weekOneMonday: Date? = nil, weekCount: Int? = nil, endDate: Date? = nil, sectionTimes: [TimetableSectionTime] = [], meetings: [TimetableMeeting] = [], cancellations: [TimetableCancellation] = [], reschedules: [TimetableReschedule] = []) {
        self.id = id; self.name = name; self.weekOneMonday = weekOneMonday
        self.weekCount = weekCount ?? max(20, meetings.flatMap(\.weeks).max() ?? 0)
        self.endDate = endDate
        self.sectionTimes = sectionTimes; self.meetings = meetings; self.cancellations = cancellations; self.reschedules = reschedules
    }

    private enum CodingKeys: String, CodingKey { case id, name, weekOneMonday, weekCount, endDate, sectionTimes, meetings, cancellations, reschedules }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        weekOneMonday = try values.decodeIfPresent(Date.self, forKey: .weekOneMonday)
        weekCount = try values.decode(Int.self, forKey: .weekCount)
        endDate = try values.decodeIfPresent(Date.self, forKey: .endDate)
        sectionTimes = try values.decode([TimetableSectionTime].self, forKey: .sectionTimes)
        meetings = try values.decode([TimetableMeeting].self, forKey: .meetings)
        cancellations = values.contains(.cancellations) ? try values.decode([TimetableCancellation].self, forKey: .cancellations) : []
        reschedules = values.contains(.reschedules) ? try values.decode([TimetableReschedule].self, forKey: .reschedules) : []
    }

    public func isCancelled(_ meeting: TimetableMeeting, on date: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        let calendar = Self.academicCalendar
        return cancellations.contains {
            $0.meetingID == meeting.id && $0.date.timeIntervalSinceReferenceDate.isFinite && calendar.isDate($0.date, inSameDayAs: date)
        }
    }

    public func occurrences(on date: Date) -> [TimetableOccurrence] {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let calendar = Self.academicCalendar, day = Self.academicCalendar.startOfDay(for: date)
        guard let week = week(containing: day) else { return [] }
        let weekday = (calendar.component(.weekday, from: day) + 5) % 7 + 1
        let regular = meetings.compactMap { meeting -> TimetableOccurrence? in
            guard meeting.isScheduled, meeting.weekday == weekday, meeting.weeks.contains(week),
                  !isCancelled(meeting, on: day),
                  !reschedules.contains(where: { $0.meetingID == meeting.id && calendar.isDate($0.originalDate, inSameDayAs: day) }) else { return nil }
            return TimetableOccurrence(meeting: meeting, date: day, originalDate: day)
        }
        let moved = reschedules.compactMap { move -> TimetableOccurrence? in
            guard calendar.isDate(move.date, inSameDayAs: day), !isCancelled(move.meeting, on: move.originalDate) else { return nil }
            return TimetableOccurrence(meeting: move.meeting, date: day, originalDate: move.originalDate, rescheduleID: move.id)
        }
        return (regular + moved).sorted {
            if $0.meeting.startSection != $1.meeting.startSection { return $0.meeting.startSection < $1.meeting.startSection }
            if $0.meeting.endSection != $1.meeting.endSection { return $0.meeting.endSection < $1.meeting.endSection }
            let titleComparison = $0.meeting.title.localizedStandardCompare($1.meeting.title)
            if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
            return $0.id < $1.id
        }
    }

    /// A semester follows the university's local dates even if macOS changes zone.
    public static var academicCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// Infers week one's Monday from a civil date and its known academic week.
    /// The reference date always belongs to its Shanghai Monday-to-Sunday week.
    public static func firstMonday(referenceDate: Date, academicWeek: Int) -> Date? {
        guard (1...60).contains(academicWeek), referenceDate.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let calendar = academicCalendar
        let day = calendar.startOfDay(for: referenceDate)
        guard day.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let weekdayOffset = (calendar.component(.weekday, from: day) + 5) % 7
        return calendar.date(byAdding: .day, value: -weekdayOffset - (academicWeek - 1) * 7, to: day)
    }

    public func week(containing date: Date) -> Int? {
        guard (1...60).contains(weekCount), date.timeIntervalSinceReferenceDate.isFinite, let monday = weekOneMonday,
              monday.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let calendar = Self.academicCalendar
        let start = calendar.startOfDay(for: monday), day = calendar.startOfDay(for: date)
        if let endDate {
            guard endDate.timeIntervalSinceReferenceDate.isFinite, day <= calendar.startOfDay(for: endDate) else { return nil }
        }
        guard calendar.component(.weekday, from: start) == 2,
              let days = calendar.dateComponents([.day], from: start, to: day).day, days >= 0 else { return nil }
        let week = days / 7 + 1
        return (1...weekCount).contains(week) ? week : nil
    }

    public func date(week: Int, weekday: Int) -> Date? {
        guard (1...60).contains(weekCount), (1...weekCount).contains(week), (1...7).contains(weekday),
              let monday = weekOneMonday, monday.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let calendar = Self.academicCalendar
        guard calendar.component(.weekday, from: monday) == 2 else { return nil }
        guard let day = calendar.date(byAdding: .day, value: (week - 1) * 7 + weekday - 1, to: calendar.startOfDay(for: monday)),
              self.week(containing: day) == week else { return nil }
        return day
    }
}

public struct TimetableImportSummary: Equatable, Sendable {
    public var termID: UUID
    public var coursesCreated: Int
    public var meetingsImported: Int

    public init(termID: UUID, coursesCreated: Int, meetingsImported: Int) {
        self.termID = termID; self.coursesCreated = coursesCreated; self.meetingsImported = meetingsImported
    }
}
