import SwiftUI
import TeachshelfCore

/// Secondary information lives beside the timetable, so tasks never reduce its height.
struct ScheduleSideAgenda: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ObservedObject var selection: ScheduleSelection
    let onMeeting: (ScheduleMeetingContext) -> Void
    let onTask: (StudyTask) -> Void

    private var term: TimetableTerm? { selection.term(in: store.state) }
    private var isUndated: Bool { selection.mode == .week && term?.weekOneMonday == nil && term != nil }
    private var classes: [TimetableCalendar.DayClass] {
        isUndated ? [] : ScheduleData.classes(on: selection.selectedDate, in: store.state, selection: selection)
    }
    private var tasks: [StudyTask] {
        guard !isUndated else { return [] }
        let days = selection.mode == .week
            ? ScheduleData.weekDays(in: store.state, selection: selection) : [selection.selectedDate]
        return days.flatMap { ScheduleData.tasks(on: $0, in: store.state, selection: selection) }
    }
    private var freeMeetings: [TimetableMeeting] {
        ScheduleData.freeMeetings(in: store.state, selection: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !isUndated {
                VStack(alignment: .leading, spacing: 11) {
                    Text(TimetableCalendar.formatted(selection.selectedDate, template: "MMM d EEEE"))
                        .font(.callout.weight(.semibold))
                    if selection.showsCourses {
                        if classes.isEmpty {
                            Text("这一天没有课程").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(classes) { event in
                                courseRow(event.meeting, detail: event.timeLabel ?? event.sectionLabel,
                                          moved: event.rescheduleID != nil) { openMeeting(event) }
                            }
                        }
                    }
                }
                if selection.showsTasks {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Label(selection.mode == .week ? "本周待办" : "当天待办", systemImage: "checklist")
                            Spacer(minLength: 0)
                            Text("\(tasks.count)").monospacedDigit().foregroundStyle(.secondary)
                        }.font(.caption.weight(.medium))
                        if tasks.isEmpty {
                            Text(selection.mode == .week ? "这一周没有待办" : "这一天没有待办")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(tasks) { task in taskRow(task) }
                        }
                    }
                }
            }
            if let term, !freeMeetings.isEmpty {
                VStack(alignment: .leading, spacing: 11) {
                    Label("自由时间 · \(freeMeetings.count)", systemImage: "clock")
                        .font(.caption.weight(.medium))
                    ForEach(freeMeetings) { meeting in
                        courseRow(meeting, detail: "未指定日期", moved: false) {
                            onMeeting(ScheduleMeetingContext(term: term, meeting: meeting, date: nil,
                                                            selectedDate: selection.selectedDate))
                        }
                    }
                }
            }
        }
    }

    private func courseRow(_ meeting: TimetableMeeting, detail: String, moved: Bool,
                           action: @escaping () -> Void) -> some View {
        let color = ScheduleEventColor.course(meeting.courseID, in: store.state, theme: theme)
        return Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title).font(.system(size: 12, weight: .medium)).lineLimit(3)
                    Text(detail + (moved ? " · 临时调课" : ""))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !meeting.classroom.isEmpty {
                        Text(meeting.classroom).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2).fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("查看课程详情与调整")
    }

    private func taskRow(_ task: StudyTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { store.setTaskCompleted(task) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundStyle(task.isCompleted ? theme.ink : Color.secondary)
            }.buttonStyle(.plain).accessibilityLabel("\(task.isCompleted ? "重新打开" : "完成")待办：\(task.title)")
            Button {
                selection.setDate(task.deadline ?? task.startsAt)
                onTask(task)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.system(size: 12)).strikethrough(task.isCompleted).lineLimit(2)
                    Text(TimetableCalendar.formatted(task.deadline ?? task.startsAt,
                                                     template: task.isAllDay ? "EEE M d" : "EEE M d HHmm"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("编辑待办：\(task.title)")
        }
    }

    private func openMeeting(_ event: TimetableCalendar.DayClass) {
        guard let term = store.state.timetableTerms.first(where: { $0.id == event.termID }) else { return }
        onMeeting(ScheduleMeetingContext(term: term, meeting: event.meeting, date: event.day,
                                        selectedDate: selection.selectedDate, originalDate: event.originalDate))
    }
}
