import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@MainActor
struct ScheduleSelectionTests {
    private let calendar = TimetableTerm.academicCalendar

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func datedTerm(name: String = "2026 秋季", monday: Date? = nil, weekCount: Int = 4,
                           meetings: [TimetableMeeting] = []) -> TimetableTerm {
        TimetableTerm(name: name, weekOneMonday: monday ?? date(2026, 9, 7), weekCount: weekCount, meetings: meetings)
    }

    @Test func viewsShareTheSelectedDateAndWeekChoosesTheMatchingTerm() {
        let first = datedTerm(), latest = datedTerm(name: "2027 春季", monday: date(2027, 3, 1))
        var state = LibraryState(); state.timetableTerms = [latest, first]
        let chosen = date(2026, 9, 16)
        let selection = ScheduleSelection(selectedDate: chosen, mode: .month)
        selection.reconcile(state)
        #expect(selection.termID == nil)
        selection.setMode(.agenda, in: state)
        #expect(selection.selectedDate == chosen)
        #expect(selection.termID == nil)
        selection.setMode(.week, in: state)
        #expect(selection.termID == first.id)
        #expect(selection.week(in: state) == 2)
        #expect(selection.selectedDate == chosen)
        selection.setMode(.month, in: state)
        #expect(selection.termID == first.id)
        #expect(selection.selectedDate == chosen)
        selection.setTerm(nil, in: state)
        #expect(selection.termID == nil)
        selection.setMode(.week, in: state)
        #expect(selection.termID == first.id)
        #expect(selection.selectedDate == chosen)
    }

    @Test func changingSemesterKeepsTheCivilDateAndReportsOutsideTerm() {
        let first = datedTerm(), next = datedTerm(name: "2027 春季", monday: date(2027, 3, 1))
        let firstCourse = Course(name: "高等数学", semester: first.name)
        var state = LibraryState(); state.timetableTerms = [first, next]; state.courses = [firstCourse]
        let chosen = date(2026, 9, 16)
        let selection = ScheduleSelection(selectedDate: chosen)
        selection.reconcile(state); selection.courseID = firstCourse.id
        selection.setTerm(next.id, in: state)
        #expect(selection.termID == next.id)
        #expect(selection.week(in: state) == nil)
        #expect(selection.selectedDate == chosen)
        #expect(selection.courseID == nil)
        #expect(ScheduleData.weekDays(in: state, selection: selection).first == date(2026, 9, 14))
    }

    @Test func choosingAnAcademicWeekPreservesTheSelectedWeekday() {
        let term = datedTerm()
        var state = LibraryState(); state.timetableTerms = [term]
        let selection = ScheduleSelection(selectedDate: date(2026, 9, 9, hour: 15))
        selection.reconcile(state)
        #expect(selection.selectedDate == date(2026, 9, 9))
        selection.setWeek(3, in: state)
        #expect(selection.selectedDate == date(2026, 9, 23))
        #expect(selection.week(in: state) == 3)
        selection.setWeek(99, in: state)
        #expect(selection.selectedDate == date(2026, 9, 30))
        selection.shift(1, in: state)
        #expect(selection.selectedDate == date(2026, 10, 7))
        #expect(selection.week(in: state) == nil)
        selection.setWeek(0, in: state)
        #expect(selection.selectedDate == date(2026, 9, 9))
    }

    @Test func realWeeksFollowShanghaiMondayEvenAcrossTheUTCDateBoundary() {
        let term = datedTerm()
        var state = LibraryState(); state.timetableTerms = [term]
        // Shanghai Monday 00:01 is still Sunday in UTC.
        let chosen = date(2026, 9, 7, minute: 1)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(utc.component(.weekday, from: chosen) == 1)
        let selection = ScheduleSelection(selectedDate: chosen)
        selection.reconcile(state)
        let days = ScheduleData.weekDays(in: state, selection: selection)
        #expect(days.count == 7)
        #expect(days.first == date(2026, 9, 7))
        #expect(days.last == date(2026, 9, 13))
        #expect(selection.week(in: state) == 1)
        selection.setDate(chosen.addingTimeInterval(-120))
        #expect(selection.selectedDate == date(2026, 9, 6))
        #expect(selection.week(in: state) == nil)
        #expect(ScheduleData.weekDays(in: state, selection: selection).first == date(2026, 8, 31))
    }

    @Test func virtualAcademicWeeksNeverFabricateDatesForClassesOrTasks() {
        let scheduled = TimetableMeeting(title: "高等数学", weeks: [2], weekday: 1, startSection: 1, sectionCount: 2)
        let term = TimetableTerm(name: "未定日期学期", weekCount: 4, meetings: [scheduled])
        let realDay = date(2026, 9, 9)
        let task = StudyTask(title: "真实日期待办", startsAt: realDay)
        var state = LibraryState(); state.timetableTerms = [term]; state.tasks = [task]
        let selection = ScheduleSelection(selectedDate: realDay)
        selection.reconcile(state); selection.setWeek(2, in: state)
        #expect(selection.week(in: state) == 2)
        #expect(selection.selectedDate == realDay)
        #expect(ScheduleData.weekDays(in: state, selection: selection).isEmpty)
        #expect(ScheduleData.classes(on: realDay, in: state, selection: selection).isEmpty)
        #expect(ScheduleData.tasks(on: realDay, in: state, selection: selection).map(\.id) == [task.id])
        selection.shift(20, in: state)
        #expect(selection.week(in: state) == 4)
        #expect(selection.selectedDate == realDay)
        selection.shift(-20, in: state)
        #expect(selection.week(in: state) == 1)
        selection.setMode(.agenda, in: state)
        #expect(ScheduleData.agendaDays(selection: selection).first == realDay)
        #expect(ScheduleData.agendaDays(selection: selection).last == date(2026, 9, 15))
    }

    @Test func semesterCourseAndVisibilityFiltersApplyToCoursesAndTasksTogether() {
        let day = date(2026, 9, 7)
        let math = Course(name: "高等数学", semester: "主修"), english = Course(name: "大学英语", semester: "辅修")
        let mathClass = TimetableMeeting(courseID: math.id, title: math.name, weeks: [1], weekday: 1, startSection: 1, sectionCount: 2)
        let englishClass = TimetableMeeting(courseID: english.id, title: english.name, weeks: [1], weekday: 1, startSection: 3, sectionCount: 2)
        let primary = datedTerm(name: "主修", meetings: [mathClass]), secondary = datedTerm(name: "辅修", meetings: [englishClass])
        let mathTask = StudyTask(title: "数学作业", courseID: math.id, startsAt: day)
        let englishTask = StudyTask(title: "英语作业", courseID: english.id, startsAt: day)
        let freeTask = StudyTask(title: "个人待办", startsAt: day)
        let hidden = StudyTask(title: "隐藏待办", courseID: math.id, startsAt: day, showOnCalendar: false)
        let archived = StudyTask(title: "归档待办", courseID: math.id, startsAt: day, archivedAt: day)
        var state = LibraryState(); state.courses = [math, english]; state.timetableTerms = [primary, secondary]
        state.tasks = [mathTask, englishTask, freeTask, hidden, archived]
        let selection = ScheduleSelection(selectedDate: day, mode: .month)
        #expect(Set(ScheduleData.classes(on: day, in: state, selection: selection).map(\.meeting.id)) == Set([mathClass.id, englishClass.id]))
        #expect(Set(ScheduleData.tasks(on: day, in: state, selection: selection).map(\.id)) == Set([mathTask.id, englishTask.id, freeTask.id]))
        selection.setTerm(primary.id, in: state)
        #expect(selection.filteredCourses(in: state).map(\.id) == [math.id])
        #expect(ScheduleData.classes(on: day, in: state, selection: selection).map(\.meeting.id) == [mathClass.id])
        #expect(Set(ScheduleData.tasks(on: day, in: state, selection: selection).map(\.id)) == Set([mathTask.id, freeTask.id]))
        selection.courseID = math.id
        #expect(ScheduleData.tasks(on: day, in: state, selection: selection).map(\.id) == [mathTask.id])
        #expect(ScheduleData.classes(on: day, in: state, selection: selection).map(\.meeting.id) == [mathClass.id])
        selection.showsCourses = false
        #expect(ScheduleData.classes(on: day, in: state, selection: selection).isEmpty)
        #expect(ScheduleData.tasks(on: day, in: state, selection: selection).count == 1)
        selection.showsTasks = false
        #expect(ScheduleData.tasks(on: day, in: state, selection: selection).isEmpty)
    }

    @Test func tasksUseTheirDeadlineAndKeepCompletedTasksAfterIncompleteTasks() {
        let first = date(2026, 9, 7), second = date(2026, 9, 8)
        let late = StudyTask(title: "晚上截止", startsAt: first, deadline: date(2026, 9, 8, hour: 20))
        let early = StudyTask(title: "早上截止", startsAt: first, deadline: date(2026, 9, 8, hour: 8))
        let done = StudyTask(title: "已完成", startsAt: second, completedAt: first)
        var state = LibraryState(); state.tasks = [done, late, early]
        let selection = ScheduleSelection(selectedDate: first, mode: .month)
        #expect(ScheduleData.tasks(on: first, in: state, selection: selection).isEmpty)
        #expect(ScheduleData.tasks(on: second, in: state, selection: selection).map(\.id) == [early.id, late.id, done.id])
    }

    @Test func editedCourseSemesterPreservesItsTimetableFilterAndAssociatedTasks() {
        let day = date(2026, 9, 7)
        var course = Course(name: "高等数学", semester: "2026 秋季")
        let meeting = TimetableMeeting(courseID: course.id, title: course.name, weeks: [1], weekday: 1, startSection: 1, sectionCount: 2)
        let term = datedTerm(meetings: [meeting])
        let task = StudyTask(title: "数学作业", courseID: course.id, startsAt: day)
        let other = Course(name: "无关联课程", semester: "其他学期")
        let otherTask = StudyTask(title: "其他作业", courseID: other.id, startsAt: day)
        var state = LibraryState(); state.courses = [course, other]; state.timetableTerms = [term]; state.tasks = [task, otherTask]
        let selection = ScheduleSelection(selectedDate: day)
        selection.reconcile(state); selection.courseID = course.id
        // Course edits and subsequent reimports preserve user-defined semester labels.
        course.name = "自定义数学名称"; course.semester = "我的自定义学期"
        state.courses[0] = course
        selection.reconcile(state)
        #expect(selection.courseID == course.id)
        #expect(selection.filteredCourses(in: state).map(\.id) == [course.id])
        #expect(ScheduleData.classes(on: day, in: state, selection: selection).map(\.meeting.id) == [meeting.id])
        #expect(ScheduleData.tasks(on: day, in: state, selection: selection).map(\.id) == [task.id])
        selection.courseID = nil
        #expect(ScheduleData.tasks(on: day, in: state, selection: selection).map(\.id) == [task.id])
    }

    @Test func monthShiftsClampTheDayAndAgendaShiftsKeepASevenDayWindow() {
        let selection = ScheduleSelection(selectedDate: date(2026, 1, 31), mode: .month)
        let state = LibraryState()
        selection.shift(1, in: state)
        #expect(selection.selectedDate == date(2026, 2, 28))
        selection.setMode(.agenda, in: state)
        selection.shift(1, in: state)
        #expect(selection.selectedDate == date(2026, 3, 7))
        #expect(ScheduleData.agendaDays(selection: selection).last == date(2026, 3, 13))
        selection.shift(-1, in: state)
        #expect(selection.selectedDate == date(2026, 2, 28))
        selection.setMode(.week, in: state)
        #expect(selection.termID == nil)
        #expect(ScheduleData.weekDays(in: state, selection: selection).count == 7)
    }

    @Test func reconciliationKeepsReimportsAndClearsDeletedSelectionsWithoutMovingDate() {
        let term = datedTerm(), older = datedTerm(name: "2025 秋季", monday: date(2025, 9, 1))
        let course = Course(name: "高等数学", semester: term.name)
        var state = LibraryState(); state.timetableTerms = [term, older]; state.courses = [course]
        let chosen = date(2026, 9, 9), selection = ScheduleSelection(selectedDate: date(2026, 9, 9))
        selection.reconcile(state); selection.courseID = course.id
        var reimported = term
        reimported.meetings = [.init(courseID: course.id, title: "新课表", weeks: [1], weekday: 3, startSection: 1, sectionCount: 1)]
        state.timetableTerms[0] = reimported
        selection.reconcile(state)
        #expect(selection.termID == term.id)
        #expect(selection.courseID == course.id)
        #expect(selection.selectedDate == chosen)
        state.timetableTerms = [older]; state.courses = []
        selection.reconcile(state)
        #expect(selection.termID == older.id)
        #expect(selection.courseID == nil)
        #expect(selection.week(in: state) == nil)
        #expect(selection.selectedDate == chosen)
        selection.setMode(.month, in: state)
        state.timetableTerms = []
        selection.reconcile(state)
        #expect(selection.termID == nil)
        #expect(selection.selectedDate == chosen)
        state.timetableTerms = [term]
        selection.reconcile(state)
        #expect(selection.termID == nil)
        selection.setMode(.week, in: state)
        #expect(selection.termID == term.id)
        #expect(selection.selectedDate == chosen)
    }

    @Test func undatedWeeksAreClampedAfterRestoringShorterSemesterSettings() {
        var term = TimetableTerm(name: "未定日期", weekCount: 20)
        var state = LibraryState(); state.timetableTerms = [term]
        let chosen = date(2026, 9, 9), selection = ScheduleSelection(selectedDate: date(2026, 9, 9))
        selection.reconcile(state); selection.setWeek(18, in: state)
        term.weekCount = 4; state.timetableTerms = [term]
        selection.reconcile(state)
        #expect(selection.floatingWeek == 4)
        #expect(selection.week(in: state) == 4)
        #expect(selection.selectedDate == chosen)
        let dated = datedTerm()
        state.timetableTerms = [term, dated]
        selection.setTerm(dated.id, in: state)
        selection.setTerm(nil, in: state)
        #expect(selection.termID == dated.id)
        #expect(selection.selectedDate == chosen)
    }

    @Test func freeTimeMeetingsRespectWeekCourseAndVisibilityWithoutBecomingDatedClasses() {
        let courseID = UUID()
        let always = TimetableMeeting(courseID: courseID, title: "学年论文", weeks: [])
        let odd = TimetableMeeting(courseID: courseID, title: "自主学习", weeks: [1, 3])
        let even = TimetableMeeting(title: "实验自选", weeks: [2, 4])
        let scheduled = TimetableMeeting(title: "课堂", weeks: [1], weekday: 1, startSection: 1, sectionCount: 1)
        let term = datedTerm(meetings: [always, odd, even, scheduled])
        var state = LibraryState(); state.timetableTerms = [term]
        state.courses = [Course(id: courseID, name: "论文", semester: term.name)]
        let selection = ScheduleSelection(selectedDate: date(2026, 9, 7))
        selection.reconcile(state)
        #expect(Set(ScheduleData.freeMeetings(in: state, selection: selection).map(\.id)) == Set([always.id, odd.id]))
        selection.setWeek(2, in: state)
        #expect(Set(ScheduleData.freeMeetings(in: state, selection: selection).map(\.id)) == Set([always.id, even.id]))
        selection.courseID = courseID
        #expect(ScheduleData.freeMeetings(in: state, selection: selection).map(\.id) == [always.id])
        selection.setDate(date(2026, 11, 1))
        #expect(ScheduleData.freeMeetings(in: state, selection: selection).map(\.id) == [always.id])
        selection.showsCourses = false
        #expect(ScheduleData.freeMeetings(in: state, selection: selection).isEmpty)
    }
}
