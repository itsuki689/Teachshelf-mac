import Foundation

extension LibraryRepository {
    /// Replaces one semester in a single metadata transaction. Existing course
    /// records retain their user edits, materials, tasks, and workspace folders.
    @discardableResult public func importUndergraduateTimetable(_ schedule: UndergraduateSchedule) throws -> TimetableImportSummary {
        let name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.invalidInput("课表缺少学期名称。") }
        guard !schedule.courses.isEmpty else { throw LibraryError.invalidInput("课表中没有可导入的本科课程。") }
        var summary = TimetableImportSummary(termID: UUID(), coursesCreated: 0, meetingsImported: 0)
        try commit { state in
            let existing = state.timetableTerms.first { $0.name == name }
            var term = existing ?? TimetableTerm(name: name)
            let courseIDs = Set(state.courses.map(\.id))
            var oldCourseIDs: [TimetableCourseKey: UUID] = [:]
            var oldSessionIDs: [TimetableMeeting: UUID] = [:]
            var oldMonthFlags: [TimetableMeeting: Bool?] = [:]
            for meeting in term.meetings {
                if let id = meeting.courseID, courseIDs.contains(id) {
                    oldCourseIDs[TimetableCourseKey(code: meeting.courseCode, title: meeting.title, teacher: meeting.teacher)] = id
                }
                oldSessionIDs[Self.timetableSessionKey(meeting)] = meeting.id
                oldMonthFlags[Self.timetableSessionKey(meeting)] = .some(meeting.showInMonth)
            }
            var importedCourseIDs: [TimetableCourseKey: UUID] = [:]
            var sessions = Set<TimetableMeeting>()
            var meetings: [TimetableMeeting] = []
            var created = 0
            for course in schedule.courses {
                let title = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let teacher = (course.teacher ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let code = (course.classNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let classroom = (course.classroom ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var notes = [(course.info ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
                if let time = course.examTime?.trimmingCharacters(in: .whitespacesAndNewlines), !time.isEmpty { notes.append("考试时间：\(time)") }
                if let location = course.examLocation?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty { notes.append("考试地点：\(location)") }
                // Validate the raw offset too: a free-time row must not conceal
                // malformed negative or non-zero period data.
                guard course.timeCount >= 0, course.timeCount < 30,
                      course.startSection > 0 || course.timeCount == 0 else { throw LibraryError.invalidInput("\(title)：课程节次无效。") }
                var meeting = TimetableMeeting(courseCode: code, title: title, teacher: teacher, classroom: classroom,
                    weeks: Array(Set(course.weeks)).sorted(), weekday: course.weekday == 0 ? nil : course.weekday,
                    startSection: course.startSection, sectionCount: course.sectionCount, note: notes.filter { !$0.isEmpty }.joined(separator: "\n"))
                try Self.validateTimetableMeeting(meeting, weekCount: 60, courseIDs: nil)
                let key = TimetableCourseKey(code: code, title: title, teacher: teacher)
                if let id = importedCourseIDs[key] ?? oldCourseIDs[key] {
                    meeting.courseID = id
                } else if let existingCourse = state.courses.first(where: { $0.semester == name && $0.name == title && $0.teacher == teacher }) {
                    meeting.courseID = existingCourse.id
                } else {
                    let newCourse = Course(name: title, semester: name, teacher: teacher,
                        colorHex: ColorPalette.themes[state.courses.count % ColorPalette.themes.count].hex)
                    state.courses.append(newCourse)
                    meeting.courseID = newCourse.id
                    created += 1
                }
                importedCourseIDs[key] = meeting.courseID
                let sessionKey = Self.timetableSessionKey(meeting)
                guard sessions.insert(sessionKey).inserted else { continue }
                meeting.id = oldSessionIDs[sessionKey] ?? meeting.id
                meeting.showInMonth = oldMonthFlags[sessionKey] ?? nil
                meeting.colorHex = term.meetings.first { Self.timetableSessionKey($0) == sessionKey }?.colorHex
                if oldMonthFlags[sessionKey] == nil {
                    let oldSlots = term.meetings.filter {
                        $0.courseID == meeting.courseID && $0.weekday == meeting.weekday &&
                        $0.startSection == meeting.startSection && $0.sectionCount == meeting.sectionCount
                    }
                    if oldSlots.count == 1 { meeting.showInMonth = oldSlots[0].showInMonth }
                }
                meetings.append(meeting)
            }
            term.cancellations = Self.remapTimetableCancellations(term.cancellations, oldMeetings: term.meetings, newMeetings: meetings)
            term.reschedules = Self.remapTimetableReschedules(term.reschedules, oldMeetings: term.meetings, newMeetings: meetings)
            term.meetings = meetings
            let importedWeeks = meetings.flatMap(\.weeks).max() ?? 1
            if term.endDate != nil, importedWeeks > term.weekCount {
                throw LibraryError.invalidInput("导入课表含第 \(importedWeeks) 周课程，超过已设置的 \(term.weekCount) 周学期。请先核对学期结束日期与周数。")
            }
            if term.endDate == nil { term.weekCount = max(term.weekCount, importedWeeks) }
            if let index = state.timetableTerms.firstIndex(where: { $0.id == term.id }) { state.timetableTerms[index] = term }
            else { state.timetableTerms.append(term) }
            summary = TimetableImportSummary(termID: term.id, coursesCreated: created, meetingsImported: meetings.count)
        }
        return summary
    }

    public func saveTimetableTerm(_ term: TimetableTerm) throws {
        var term = term
        term.name = term.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let monday = term.weekOneMonday, monday.timeIntervalSinceReferenceDate.isFinite {
            term.weekOneMonday = TimetableTerm.academicCalendar.startOfDay(for: monday)
        }
        if let endDate = term.endDate, endDate.timeIntervalSinceReferenceDate.isFinite { term.endDate = TimetableTerm.academicCalendar.startOfDay(for: endDate) }
        term.reschedules = term.reschedules.map(Self.normalizedReschedule)
        for index in term.cancellations.indices {
            if term.cancellations[index].date.timeIntervalSinceReferenceDate.isFinite { term.cancellations[index].date = TimetableTerm.academicCalendar.startOfDay(for: term.cancellations[index].date) }
            if let saved = term.cancellations[index].savedReschedule { term.cancellations[index].savedReschedule = Self.normalizedReschedule(saved) }
        }
        try commit { state in
            if let index = state.timetableTerms.firstIndex(where: { $0.id == term.id }) { state.timetableTerms[index] = term }
            else { state.timetableTerms.append(term) }
        }
    }

    public func deleteTimetableTerm(id: UUID) throws {
        try commit { state in
            guard state.timetableTerms.contains(where: { $0.id == id }) else { throw LibraryError.missingRecord("学期课表") }
            state.timetableTerms.removeAll { $0.id == id }
        }
    }

    /// Cancels one real occurrence without changing recurring weeks or other
    /// sessions. Repeating this action preserves both the original record and backup.
    public func cancelTimetableClass(termID: UUID, meetingID: UUID, on date: Date, reason: String = "") throws {
        try withLock {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw LibraryError.invalidInput("停课日期无效。") }
            guard let term = snapshot.timetableTerms.first(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
            let calendar = TimetableTerm.academicCalendar
            let day = calendar.startOfDay(for: date)
            guard !term.cancellations.contains(where: { $0.meetingID == meetingID && calendar.isDate($0.date, inSameDayAs: day) }) else { return }
            let move = term.reschedules.first { $0.meetingID == meetingID && calendar.isDate($0.originalDate, inSameDayAs: day) }
            let source = term.meetings.first { $0.id == meetingID }
            guard let meeting = move?.meeting ?? source else { throw LibraryError.missingRecord("上课时段") }
            guard move != nil || Self.isActualOccurrence(meeting, in: term, on: day) else {
                throw LibraryError.invalidInput("所选日期没有这次固定课程，无法设置停课。")
            }
            let cancellation = TimetableCancellation(meetingID: meetingID, date: day, title: meeting.title,
                                                     reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), savedReschedule: move)
            try commit { state in
                guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
                if let move { state.timetableTerms[index].reschedules.removeAll { $0.id == move.id } }
                state.timetableTerms[index].cancellations.append(cancellation)
            }
        }
    }

    public func restoreTimetableClass(termID: UUID, cancellationID: UUID) throws {
        try withLock {
            guard let term = snapshot.timetableTerms.first(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
            guard let cancellation = term.cancellations.first(where: { $0.id == cancellationID }) else { return }
            try commit { state in
                guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
                if let saved = cancellation.savedReschedule { state.timetableTerms[index].reschedules.append(saved) }
                state.timetableTerms[index].cancellations.removeAll { $0.id == cancellationID }
            }
        }
    }

    public func rescheduleTimetableClass(termID: UUID, meetingID: UUID, originalDate: Date, to date: Date, startSection: Int, sectionCount: Int, classroom: String, startMinute: Int? = nil, endMinute: Int? = nil) throws {
        try withLock {
            guard [originalDate, date].allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else { throw LibraryError.invalidInput("调课日期无效。") }
            guard let term = snapshot.timetableTerms.first(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
            let calendar = TimetableTerm.academicCalendar
            let origin = calendar.startOfDay(for: originalDate), target = calendar.startOfDay(for: date)
            let existing = term.reschedules.first { $0.meetingID == meetingID && calendar.isDate($0.originalDate, inSameDayAs: origin) }
            let master = term.meetings.first { $0.id == meetingID }
            guard let source = existing?.meeting ?? master else { throw LibraryError.missingRecord("上课时段") }
            guard !term.isCancelled(source, on: origin), existing != nil || Self.isActualOccurrence(source, in: term, on: origin) else {
                throw LibraryError.invalidInput("原课次不存在或已停课，请先恢复停课后再调整。")
            }
            guard let targetWeek = term.week(containing: target) else { throw LibraryError.invalidInput("调课目标日期应在所选学期内。") }
            guard (1...30).contains(startSection), (1...30).contains(sectionCount), startSection <= 31 - sectionCount else {
                throw LibraryError.invalidInput("调课节次需在第 1–30 节内。")
            }
            let room = classroom.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (startMinute == nil && endMinute == nil) || (startMinute.flatMap { start in endMinute.flatMap { PlanTimeRange(start: start, end: $0) } } != nil) else {
                throw LibraryError.invalidInput("课程时间必须在同一天内，且结束晚于开始。")
            }
            if let master, Self.isActualOccurrence(master, in: term, on: origin), origin == target,
               master.startSection == startSection, master.sectionCount == sectionCount, master.classroom == room,
               (startMinute == nil && endMinute == nil || master.timeRange(sectionTimes: term.sectionTimes) == startMinute.flatMap { start in endMinute.flatMap { PlanTimeRange(start: start, end: $0) } }) {
                if let existing { try restoreTimetableReschedule(termID: termID, rescheduleID: existing.id) }
                return
            }
            var moved = source
            moved.id = meetingID; moved.weekday = (calendar.component(.weekday, from: target) + 5) % 7 + 1
            moved.weeks = [targetWeek]; moved.startSection = startSection; moved.sectionCount = sectionCount; moved.classroom = room
            moved.startMinuteOverride = startMinute; moved.endMinuteOverride = endMinute
            let move = TimetableReschedule(id: existing?.id ?? UUID(), meetingID: meetingID, originalDate: origin, date: target, meeting: moved)
            if move == existing { return }
            try commit { state in
                guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
                if let position = state.timetableTerms[index].reschedules.firstIndex(where: { $0.id == move.id }) { state.timetableTerms[index].reschedules[position] = move }
                else { state.timetableTerms[index].reschedules.append(move) }
            }
        }
    }

    public func restoreTimetableReschedule(termID: UUID, rescheduleID: UUID) throws {
        try withLock {
            guard let term = snapshot.timetableTerms.first(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
            guard term.reschedules.contains(where: { $0.id == rescheduleID }) else { return }
            try commit { state in
                guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
                state.timetableTerms[index].reschedules.removeAll { $0.id == rescheduleID }
            }
        }
    }

    public func updateTimetableMeeting(termID: UUID, meeting: TimetableMeeting) throws {
        try commit { state in
            guard let termIndex = state.timetableTerms.firstIndex(where: { $0.id == termID }),
                  let meetingIndex = state.timetableTerms[termIndex].meetings.firstIndex(where: { $0.id == meeting.id }) else { throw LibraryError.missingRecord("上课时段") }
            let previousTerm = state.timetableTerms[termIndex]
            func rebasedSourceDay(_ original: Date) -> Date {
                guard meeting.isScheduled, let week = previousTerm.week(containing: original), meeting.weeks.contains(week),
                      let weekday = meeting.weekday, let day = previousTerm.date(week: week, weekday: weekday) else { return original }
                return day
            }
            for index in state.timetableTerms[termIndex].reschedules.indices where state.timetableTerms[termIndex].reschedules[index].meetingID == meeting.id {
                state.timetableTerms[termIndex].reschedules[index].originalDate = rebasedSourceDay(state.timetableTerms[termIndex].reschedules[index].originalDate)
            }
            for index in state.timetableTerms[termIndex].cancellations.indices where state.timetableTerms[termIndex].cancellations[index].meetingID == meeting.id {
                let day = rebasedSourceDay(state.timetableTerms[termIndex].cancellations[index].date)
                state.timetableTerms[termIndex].cancellations[index].date = day
                if state.timetableTerms[termIndex].cancellations[index].savedReschedule != nil {
                    state.timetableTerms[termIndex].cancellations[index].savedReschedule?.originalDate = day
                }
            }
            state.timetableTerms[termIndex].meetings[meetingIndex] = meeting
        }
    }

    public func setTimetableMeetingColor(termID: UUID, meetingID: UUID, hex: String?) throws {
        let color: String?
        if let hex {
            guard let rgb = RGBColor(hex: hex) else { throw LibraryError.invalidInput("计划颜色须为六位 HEX 颜色。") }
            color = rgb.hex
        } else { color = nil }
        try commit { state in
            guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期") }
            for m in state.timetableTerms[index].meetings.indices where state.timetableTerms[index].meetings[m].id == meetingID {
                state.timetableTerms[index].meetings[m].colorHex = color
            }
            for r in state.timetableTerms[index].reschedules.indices where state.timetableTerms[index].reschedules[r].meetingID == meetingID {
                state.timetableTerms[index].reschedules[r].meeting.colorHex = color
            }
            for c in state.timetableTerms[index].cancellations.indices where state.timetableTerms[index].cancellations[c].meetingID == meetingID {
                state.timetableTerms[index].cancellations[c].savedReschedule?.meeting.colorHex = color
            }
        }
    }

    public func deleteTimetableMeeting(termID: UUID, meetingID: UUID) throws {
        try commit { state in
            guard let index = state.timetableTerms.firstIndex(where: { $0.id == termID }) else { throw LibraryError.missingRecord("学期课表") }
            guard state.timetableTerms[index].meetings.contains(where: { $0.id == meetingID }) || state.timetableTerms[index].reschedules.contains(where: { $0.meetingID == meetingID }) else {
                throw LibraryError.missingRecord("上课时段")
            }
            state.timetableTerms[index].meetings.removeAll { $0.id == meetingID }
            state.timetableTerms[index].reschedules.removeAll { $0.meetingID == meetingID }
            for cancellationIndex in state.timetableTerms[index].cancellations.indices where state.timetableTerms[index].cancellations[cancellationIndex].meetingID == meetingID {
                state.timetableTerms[index].cancellations[cancellationIndex].savedReschedule = nil
            }
        }
    }

    private static func isActualOccurrence(_ meeting: TimetableMeeting, in term: TimetableTerm, on day: Date) -> Bool {
        let weekday = (TimetableTerm.academicCalendar.component(.weekday, from: day) + 5) % 7 + 1
        return meeting.isScheduled && meeting.weekday == weekday && term.week(containing: day).map(meeting.weeks.contains) == true
    }

    private static func normalizedReschedule(_ move: TimetableReschedule) -> TimetableReschedule {
        var move = move
        if move.date.timeIntervalSinceReferenceDate.isFinite { move.date = TimetableTerm.academicCalendar.startOfDay(for: move.date) }
        if move.originalDate.timeIntervalSinceReferenceDate.isFinite { move.originalDate = TimetableTerm.academicCalendar.startOfDay(for: move.originalDate) }
        return move
    }

    func validateTimetables(_ terms: [TimetableTerm], courseIDs: Set<UUID>) throws {
        guard Set(terms.map(\.id)).count == terms.count,
              Set(terms.map(\.name)).count == terms.count else { throw LibraryError.invalidInput("课表包含重复的学期编号或名称。") }
        var meetingIDs = Set<UUID>(), cancellationIDs = Set<UUID>(), rescheduleIDs = Set<UUID>()
        for term in terms {
            guard !term.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  term.name == term.name.trimmingCharacters(in: .whitespacesAndNewlines) else { throw LibraryError.invalidInput("课表学期名称不能为空或含有首尾空格。") }
            guard (1...60).contains(term.weekCount) else { throw LibraryError.invalidInput("学期周数应为 1–60 周。") }
            if let monday = term.weekOneMonday {
                guard monday.timeIntervalSinceReferenceDate.isFinite,
                      TimetableTerm.academicCalendar.component(.weekday, from: monday) == 2 else { throw LibraryError.invalidInput("请将第一周起始日设为周一（中国标准时间）。") }
            }
            if let end = term.endDate {
                guard end.timeIntervalSinceReferenceDate.isFinite else { throw LibraryError.invalidInput("学期结束日期无效。") }
                if let monday = term.weekOneMonday {
                    let calendar = TimetableTerm.academicCalendar
                    let start = calendar.startOfDay(for: monday), last = calendar.startOfDay(for: end)
                    let dayCount = calendar.dateComponents([.day], from: start, to: last).day ?? -1
                    guard dayCount >= (term.weekCount - 1) * 7, dayCount < term.weekCount * 7 else {
                        throw LibraryError.invalidInput("学期结束日期应位于第 \(term.weekCount) 周内，请核对开始日期与总周数。")
                    }
                }
            }
            var previousSection = 0, previousEnd = 0
            for time in term.sectionTimes {
                guard (1...30).contains(time.section), time.section > previousSection,
                      time.startMinute >= 0, time.startMinute < time.endMinute, time.endMinute <= 1_440,
                      time.startMinute >= previousEnd else { throw LibraryError.invalidInput("作息时间需按节次排序，各节的开始和结束时间不能重叠。") }
                previousSection = time.section; previousEnd = time.endMinute
            }
            for meeting in term.meetings {
                guard meetingIDs.insert(meeting.id).inserted else { throw LibraryError.invalidInput("课表包含重复的上课记录编号。") }
                try Self.validateTimetableMeeting(meeting, weekCount: term.weekCount, courseIDs: courseIDs)
            }
            var cancelledOccurrences = Set<String>(), movedOccurrences = Set<String>()
            for cancellation in term.cancellations {
                guard cancellationIDs.insert(cancellation.id).inserted else { throw LibraryError.invalidInput("课表包含重复的停课记录编号。") }
                guard cancellation.date.timeIntervalSinceReferenceDate.isFinite else { throw LibraryError.invalidInput("停课记录包含无效日期。") }
                guard !cancellation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("停课记录的课程名称不能为空。") }
                let key = Self.timetableOccurrenceKey(meetingID: cancellation.meetingID, date: cancellation.date)
                guard cancelledOccurrences.insert(key).inserted else { throw LibraryError.invalidInput("同一课次存在重复停课记录。") }
                if let saved = cancellation.savedReschedule {
                    guard saved.originalDate.timeIntervalSinceReferenceDate.isFinite, saved.meetingID == cancellation.meetingID,
                          TimetableTerm.academicCalendar.isDate(saved.originalDate, inSameDayAs: cancellation.date) else { throw LibraryError.invalidInput("停课记录的原调课快照不匹配。") }
                    guard rescheduleIDs.insert(saved.id).inserted else { throw LibraryError.invalidInput("课表包含重复的调课记录编号。") }
                    try Self.validateTimetableReschedule(saved, in: term, courseIDs: courseIDs, active: false)
                }
                // Detached meeting IDs intentionally retain a visible history after reimports.
            }
            for move in term.reschedules {
                guard rescheduleIDs.insert(move.id).inserted else { throw LibraryError.invalidInput("课表包含重复的调课记录编号。") }
                try Self.validateTimetableReschedule(move, in: term, courseIDs: courseIDs, active: true)
                let key = Self.timetableOccurrenceKey(meetingID: move.meetingID, date: move.originalDate)
                guard movedOccurrences.insert(key).inserted, !cancelledOccurrences.contains(key) else { throw LibraryError.invalidInput("同一课次存在重复调课，或同时标记为停课。") }
            }
        }
    }

    private static func validateTimetableMeeting(_ meeting: TimetableMeeting, weekCount: Int, courseIDs: Set<UUID>?) throws {
        if let hex = meeting.colorHex, RGBColor(hex: hex) == nil { throw LibraryError.invalidInput("课程时段颜色无效。") }
        if meeting.startMinuteOverride != nil || meeting.endMinuteOverride != nil {
            guard let start = meeting.startMinuteOverride, let end = meeting.endMinuteOverride,
                  PlanTimeRange(start: start, end: end) != nil else { throw LibraryError.invalidInput("课程时间须在同一天内。") }
        }
        guard !meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("课表课程名称不能为空。") }
        if let id = meeting.courseID, let courseIDs, !courseIDs.contains(id) { throw LibraryError.invalidInput("课表关联的课程不存在。") }
        let freeTime = (meeting.weekday == nil || meeting.weekday == 0) && meeting.startSection == 0 && meeting.sectionCount == 0
        guard (freeTime || !meeting.weeks.isEmpty), Set(meeting.weeks).count == meeting.weeks.count,
              meeting.weeks.allSatisfy({ (1...weekCount).contains($0) }) else { throw LibraryError.invalidInput("\(meeting.title)：上课周次应在学期周数范围内。") }
        if meeting.weekday == nil || meeting.weekday == 0 {
            guard meeting.startSection == 0, meeting.sectionCount == 0 else { throw LibraryError.invalidInput("\(meeting.title)：自由时间课程不能包含固定节次。") }
        } else {
            guard let weekday = meeting.weekday, (1...7).contains(weekday), (1...30).contains(meeting.startSection),
                  (1...30).contains(meeting.sectionCount), meeting.endSection <= 30 else { throw LibraryError.invalidInput("\(meeting.title)：星期或课程节次无效。") }
        }
    }

    private static func validateTimetableReschedule(_ move: TimetableReschedule, in term: TimetableTerm, courseIDs: Set<UUID>, active: Bool) throws {
        guard move.date.timeIntervalSinceReferenceDate.isFinite, move.originalDate.timeIntervalSinceReferenceDate.isFinite,
              move.meetingID == move.meeting.id, move.meeting.isScheduled else { throw LibraryError.invalidInput("调课记录的日期、课堂编号或节次无效。") }
        try validateTimetableMeeting(move.meeting, weekCount: 60, courseIDs: courseIDs)
        let calendar = TimetableTerm.academicCalendar
        guard move.date == calendar.startOfDay(for: move.date), move.originalDate == calendar.startOfDay(for: move.originalDate),
              move.meeting.weekday == (calendar.component(.weekday, from: move.date) + 5) % 7 + 1 else {
            throw LibraryError.invalidInput("调课日期需按北京时间整日保存，星期应与目标日期一致。")
        }
        if active, term.weekOneMonday != nil {
            // The snapshot's original week labels are descriptive; its civil
            // target remains authoritative when semester dates are adjusted.
            guard term.week(containing: move.date) != nil else { throw LibraryError.invalidInput("调课目标日期应在所选学期内。") }
        }
    }

    private static func timetableOccurrenceKey(meetingID: UUID, date: Date) -> String {
        "\(meetingID.uuidString)-\(TimetableTerm.academicCalendar.startOfDay(for: date).timeIntervalSinceReferenceDate)"
    }

    private static func timetableSessionKey(_ meeting: TimetableMeeting) -> TimetableMeeting {
        var key = meeting
        key.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        key.courseID = nil
        key.showInMonth = nil
        key.colorHex = nil; key.startMinuteOverride = nil; key.endMinuteOverride = nil
        return key
    }

    private static func remapTimetableCancellations(_ cancellations: [TimetableCancellation], oldMeetings: [TimetableMeeting], newMeetings: [TimetableMeeting]) -> [TimetableCancellation] {
        return cancellations.map { cancellation in
            var remapped = cancellation
            remapped.meetingID = remappedMeetingID(cancellation.meetingID, oldMeetings: oldMeetings, newMeetings: newMeetings)
            if let saved = cancellation.savedReschedule {
                remapped.savedReschedule = remapTimetableReschedules([saved], oldMeetings: oldMeetings, newMeetings: newMeetings).first
            }
            return remapped
        }
    }

    private static func remapTimetableReschedules(_ moves: [TimetableReschedule], oldMeetings: [TimetableMeeting], newMeetings: [TimetableMeeting]) -> [TimetableReschedule] {
        moves.map { move in
            var remapped = move
            remapped.meetingID = remappedMeetingID(move.meetingID, oldMeetings: oldMeetings, newMeetings: newMeetings)
            remapped.meeting.id = remapped.meetingID
            return remapped
        }
    }

    private static func remappedMeetingID(_ id: UUID, oldMeetings: [TimetableMeeting], newMeetings: [TimetableMeeting]) -> UUID {
        func sameSlot(_ first: TimetableMeeting, _ second: TimetableMeeting) -> Bool {
            guard first.isScheduled, second.isScheduled, first.weekday == second.weekday,
                  first.startSection == second.startSection, first.sectionCount == second.sectionCount else { return false }
            return (first.courseID != nil && first.courseID == second.courseID) || (!first.courseCode.isEmpty && first.courseCode == second.courseCode)
        }
        guard !newMeetings.contains(where: { $0.id == id }), let old = oldMeetings.first(where: { $0.id == id }) else { return id }
        let candidates = newMeetings.filter { sameSlot(old, $0) }
        guard candidates.count == 1, let candidate = candidates.first, oldMeetings.filter({ sameSlot($0, candidate) }).count == 1 else { return id }
        return candidate.id
    }
}

private struct TimetableCourseKey: Hashable {
    var code: String
    var title: String
    var teacher: String

    init(code: String, title: String, teacher: String) {
        self.code = code
        // A portal course number survives user edits to the library course.
        self.title = code.isEmpty ? title : ""
        self.teacher = code.isEmpty ? teacher : ""
    }
}
