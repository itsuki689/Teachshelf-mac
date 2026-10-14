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

public struct TimetableTerm: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var weekOneMonday: Date?
    public var weekCount: Int
    public var sectionTimes: [TimetableSectionTime]
    public var meetings: [TimetableMeeting]

    public init(id: UUID = UUID(), name: String, weekOneMonday: Date? = nil, weekCount: Int? = nil, sectionTimes: [TimetableSectionTime] = [], meetings: [TimetableMeeting] = []) {
        self.id = id; self.name = name; self.weekOneMonday = weekOneMonday
        self.weekCount = weekCount ?? max(20, meetings.flatMap(\.weeks).max() ?? 0)
        self.sectionTimes = sectionTimes; self.meetings = meetings
    }

    /// A semester follows the university's local dates even if macOS changes zone.
    public static var academicCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    public func week(containing date: Date) -> Int? {
        guard (1...60).contains(weekCount), date.timeIntervalSinceReferenceDate.isFinite, let monday = weekOneMonday,
              monday.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let calendar = Self.academicCalendar
        let start = calendar.startOfDay(for: monday), day = calendar.startOfDay(for: date)
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
        return calendar.date(byAdding: .day, value: (week - 1) * 7 + weekday - 1, to: calendar.startOfDay(for: monday))
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
