import SwiftUI
import TeachshelfCore

/// The same event language is used in the selected-day pane and the seven-day agenda.
struct ScheduleClassCard: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    let event: TimetableCalendar.DayClass
    let onOpen: () -> Void

    var body: some View {
        let meeting = event.meeting
        let color = ScheduleEventColor.course(meeting.courseID, in: store.state, theme: theme)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "book.closed.fill").foregroundStyle(color)
                    Text(meeting.title).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
                }
                HStack(spacing: 6) {
                    Text(event.sectionLabel)
                    if let time = event.timeLabel { Text(time).monospacedDigit() }
                }.font(.caption).foregroundStyle(.secondary)
                if event.rescheduleID != nil {
                    Label("临时调课", systemImage: "arrow.triangle.swap").font(.caption).foregroundStyle(.secondary)
                }
                if !meeting.classroom.isEmpty {
                    Label(meeting.classroom, systemImage: "mappin.and.ellipse")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if !meeting.teacher.isEmpty { Text(meeting.teacher).lineLimit(1) }
                    Spacer(minLength: 0)
                    Text(event.termName).lineLimit(1)
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(theme.isDark ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 14)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("查看课程安排与关联资料")
    }
}

struct ScheduleTaskCard: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    let task: StudyTask
    let onOpen: () -> Void

    var body: some View {
        let color = ScheduleEventColor.course(task.courseID, in: store.state, theme: theme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button { store.setTaskCompleted(task) } label: {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(task.isCompleted ? theme.ink : Color.secondary)
                }
                .buttonStyle(.plain).padding(.top, 1)
                .help(task.isCompleted ? "标为未完成" : "完成待办")
                .accessibilityLabel("\(task.isCompleted ? "重新打开" : "完成")\(task.title)")
                Button(action: onOpen) {
                    Text(task.title).font(.headline).strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("编辑待办")
            }
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(task.courseID == nil ? (task.courseNameSnapshot ?? "未分配课程") : store.courseName(task.courseID)).lineLimit(1)
                Spacer(minLength: 0)
                Text(task.kind).lineLimit(1)
            }.font(.caption).foregroundStyle(.secondary)
            Label(timeLabel, systemImage: task.deadline == nil ? "calendar" : "clock")
                .font(.caption).foregroundStyle(isOverdue ? Color.red : Color.secondary)
            if !task.content.isEmpty {
                Text(task.content).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 14)
        }
        .contextMenu {
            Button("编辑待办", action: onOpen)
            Button(task.isCompleted ? "标为未完成" : "完成待办") { store.setTaskCompleted(task) }
            Button("归档待办") { store.archiveTask(task) }
        }
    }

    private var timeLabel: String {
        if let deadline = task.deadline {
            return task.isAllDay ? "当天截止" : "\(TimetableCalendar.formatted(deadline, template: "jmm")) 截止"
        }
        return task.isAllDay ? "全天待办" : "\(TimetableCalendar.formatted(task.startsAt, template: "jmm")) 开始"
    }

    private var isOverdue: Bool {
        guard !task.isCompleted, let deadline = task.deadline else { return false }
        let calendar = TimetableCalendar.calendar
        return task.isAllDay
            ? calendar.startOfDay(for: deadline) < calendar.startOfDay(for: Date())
            : deadline < Date()
    }
}

enum ScheduleEventColor {
    static func event(_ event: PlanDisplayEvent, in state: LibraryState, theme: AppTheme) -> Color {
        if let hex = event.colorHex, RGBColor(hex: hex) != nil { return Color(hex: hex) }
        return course(event.courseID, in: state, theme: theme)
    }
    static func course(_ id: UUID?, in state: LibraryState, theme: AppTheme) -> Color {
        guard let course = state.courses.first(where: { $0.id == id }) else { return theme.ink }
        return Color(hex: course.colorHex)
    }
}
