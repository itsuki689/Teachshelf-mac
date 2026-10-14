import SwiftUI
import TeachshelfCore

struct ScheduleMeetingContext: Identifiable {
    let id = UUID()
    let term: TimetableTerm
    let meeting: TimetableMeeting
    let date: Date?
    let selectedDate: Date
    let originalDate: Date?
    var sourceDate: Date? { originalDate ?? date }

    init(term: TimetableTerm, meeting: TimetableMeeting, date: Date?, selectedDate: Date, originalDate: Date? = nil) {
        self.term = term; self.meeting = meeting; self.date = date
        self.selectedDate = selectedDate; self.originalDate = originalDate
    }
}

struct ScheduleMeetingSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var panel: MeetingPanel?
    let context: ScheduleMeetingContext
    private var meeting: TimetableMeeting { context.meeting }
    private var courseID: UUID? { store.state.courses.first { $0.id == meeting.courseID }?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(meeting.title).font(.title2.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                Spacer(minLength: 8)
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭课程信息")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(context.term.name).font(.callout).foregroundStyle(.secondary)
                    Label("固定计划 · 来自导入课表", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("将此时段加入月历", isOn: Binding(get: {
                        store.state.timetableTerms.first { $0.id == context.term.id }?.meetings.first { $0.id == meeting.id }?.showInMonth == true
                    }, set: { visible in
                        guard var master = store.state.timetableTerms.first(where: { $0.id == context.term.id })?.meetings.first(where: { $0.id == meeting.id }) else { return }
                        master.showInMonth = visible
                        store.changeTimetable(termID: context.term.id, label: visible ? "上课安排加入月历" : "上课安排移出月历") {
                            try $0.updateTimetableMeeting(termID: context.term.id, meeting: master)
                        }
                    })).toggleStyle(.checkbox)
                    Divider()
                    if let date = context.date { LabeledContent("日期", value: TimetableCalendar.formatted(date, template: "yMMMdEEEE")) }
                    if let sourceDate = context.sourceDate, context.term.reschedules.contains(where: {
                        $0.meetingID == meeting.id && TimetableTerm.academicCalendar.isDate($0.originalDate, inSameDayAs: sourceDate)
                    }) {
                        Label("临时调课 · 原定 \(TimetableCalendar.formatted(sourceDate, template: "MMMd"))", systemImage: "arrow.triangle.swap")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("上课时段", value: meeting.isScheduled ? "\(TimetableLayout.weekdayLabel(meeting.weekday)) · \(TimetableLayout.sectionLabel(meeting))" : "自由时间")
                    if let time = TimetableLayout.timeLabel(meeting, in: context.term) { LabeledContent("作息时间", value: time) }
                    LabeledContent("上课周次", value: TimetableLayout.weeksLabel(meeting.weeks))
                    LabeledContent("教室", value: meeting.classroom.isEmpty ? "未提供" : meeting.classroom)
                    LabeledContent("教师", value: meeting.teacher.isEmpty ? "未提供" : meeting.teacher)
                    if !meeting.courseCode.isEmpty { LabeledContent("课程号", value: meeting.courseCode) }
                    if !meeting.note.isEmpty { Text(meeting.note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    if context.date == nil {
                        Text("关联计划将使用当前所选日期，可在创建时调整。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let date = context.date {
                        Divider()
                        HStack(spacing: 12) {
                            Text("仅标记这一天的这次课程，其他周次照常显示。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("本次停课") { cancel(on: date) }.buttonStyle(.bordered).disabled(store.isBusy)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                if let courseID {
                    Button("查看课程资料") { dismiss(); store.navigate(to: .course(courseID)) }
                }
                Button("调整安排") { panel = .edit }.buttonStyle(.bordered)
                Spacer(minLength: 0)
                if let courseID {
                    Button("新建关联计划") {
                        panel = .task(StudyTask(title: "", kind: "作业", courseID: courseID, startsAt: context.date ?? context.selectedDate,
                                               hasExecutionTime: false, completionRequired: true))
                    }.appPrimaryButton()
                } else { Button("完成") { dismiss() } }
            }
        }.padding(26).frame(width: 530, height: 500)
            .sheet(item: $panel) { item in
                Group {
                    switch item {
                    case .task(let task): TaskEditor(task: task, isNew: true, compact: true, calendar: TimetableTerm.academicCalendar)
                    case .edit: ScheduleEditSheet(context: context, onSaved: { dismiss() })
                    }
                }.environmentObject(store)
                    .environment(\.calendar, TimetableTerm.academicCalendar)
                    .environment(\.timeZone, TimetableTerm.academicCalendar.timeZone)
            }
    }

    private func cancel(on date: Date) {
        if store.changeTimetable(termID: context.term.id, label: "标记本次停课", action: {
            try $0.cancelTimetableClass(termID: context.term.id, meetingID: meeting.id, on: context.sourceDate ?? date)
        }) { dismiss() }
    }
}

private enum MeetingPanel: Identifiable {
    case task(StudyTask), edit
    var id: String {
        switch self { case .task(let task): return task.id.uuidString; case .edit: return "edit" }
    }
}
