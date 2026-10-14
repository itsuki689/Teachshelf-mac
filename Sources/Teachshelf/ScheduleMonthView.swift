import SwiftUI
import TeachshelfCore

struct ScheduleMonthView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ObservedObject var selection: ScheduleSelection
    let onMeeting: (ScheduleMeetingContext) -> Void
    let onTask: (StudyTask) -> Void
    let onCreateTask: (Date) -> Void
    private let calendar = TimetableCalendar.calendar
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    private var days: [Date] {
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: selection.selectedDate)) else { return [] }
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        guard let first = calendar.date(byAdding: .day, value: -offset, to: start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    var body: some View {
        WorkspaceSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(weekdays, id: \.self) { weekday in
                        Text(weekday).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                }
                GeometryReader { geometry in
                    let rowHeight = max(83, geometry.size.height / 6)
                    let compact = (geometry.size.width - 6) / 7 < 84
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                            ForEach(days, id: \.self) { day in dayCell(day, height: rowHeight - 1, compact: compact) }
                        }.background(Color.primary.opacity(0.07))
                    }
                }
            }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            selectedDayAgenda.frame(minWidth: 240, idealWidth: 280, maxWidth: 340, maxHeight: .infinity)
        }
    }

    private var selectedDayAgenda: some View {
        let classes = classes(on: selection.selectedDate)
        let tasks = tasks(on: selection.selectedDate)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(TimetableCalendar.formatted(selection.selectedDate, template: "MMM d EEEE"))
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                    Button { onCreateTask(selection.selectedDate) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("在这一天新建待办")
                        .accessibilityLabel("在所选日期新建待办")
                }
                Text("\(classes.count) 次课 · \(tasks.count) 项待办").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            if classes.isEmpty && tasks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sun.max").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("这一天还没有安排").foregroundStyle(.secondary)
                    Button("添加待办") { onCreateTask(selection.selectedDate) }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !classes.isEmpty {
                            Label("课程", systemImage: "books.vertical")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(classes) { event in
                                ScheduleClassCard(event: event) { openMeeting(event) }
                            }
                        }
                        if !tasks.isEmpty {
                            Label("待办", systemImage: "checklist")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, classes.isEmpty ? 0 : 8)
                            ForEach(tasks) { task in ScheduleTaskCard(task: task) { onTask(task) } }
                        }
                    }.padding(18)
                }
            }
        }
    }

    private func tasks(on day: Date) -> [StudyTask] {
        ScheduleData.tasks(on: day, in: store.state, selection: selection)
    }

    private func classes(on day: Date) -> [TimetableCalendar.DayClass] {
        ScheduleData.classes(on: day, in: store.state, selection: selection)
    }

    private func openMeeting(_ event: TimetableCalendar.DayClass) {
        guard let term = store.state.timetableTerms.first(where: { $0.id == event.termID }) else { return }
        onMeeting(ScheduleMeetingContext(term: term, meeting: event.meeting, date: event.day,
                                        selectedDate: selection.selectedDate, originalDate: event.originalDate))
    }

    private func dayCell(_ day: Date, height: CGFloat, compact: Bool) -> some View {
        let sameMonth = calendar.isDate(day, equalTo: selection.selectedDate, toGranularity: .month)
        let isSelected = calendar.isDate(day, inSameDayAs: selection.selectedDate)
        let isToday = calendar.isDateInToday(day)
        let dayTasks = tasks(on: day)
        let dayClasses = classes(on: day)
        let eventLimit = height < 96 ? 1 : 2
        let shownClasses = Array(dayClasses.prefix(dayTasks.isEmpty ? eventLimit : 1))
        let shownTasks = Array(dayTasks.prefix(eventLimit - shownClasses.count))
        let remainingClasses = dayClasses.count - shownClasses.count
        let remainingTasks = dayTasks.count - shownTasks.count
        return Button { selection.setDate(day) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.callout.weight(isToday || isSelected ? .semibold : .regular))
                        .foregroundStyle(isToday ? Color.white : (sameMonth ? Color.primary : Color.secondary))
                        .frame(width: 25, height: 25)
                        .background(isToday ? theme.controlAccent : Color.clear, in: Circle())
                    Spacer(minLength: 0)
                }
                if compact {
                    if !dayClasses.isEmpty {
                        Label("\(dayClasses.count) 次课", systemImage: "book.closed.fill")
                            .font(.system(size: 10)).foregroundStyle(theme.ink).lineLimit(1)
                    }
                    if !dayTasks.isEmpty {
                        Label("\(dayTasks.count) 待办", systemImage: "checklist")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    ForEach(shownClasses) { event in
                        HStack(spacing: 4) {
                            Image(systemName: "book.closed.fill").font(.system(size: 8))
                                .foregroundStyle(ScheduleEventColor.course(event.meeting.courseID, in: store.state, theme: theme))
                            Text("\(event.meeting.startSection)·\(event.meeting.title)").font(.system(size: 11)).lineLimit(1)
                        }
                    }
                    ForEach(shownTasks) { task in
                        HStack(spacing: 4) {
                            Circle().fill(task.isCompleted ? Color.secondary : ScheduleEventColor.course(task.courseID, in: store.state, theme: theme))
                                .frame(width: 5, height: 5)
                            Text(task.title).font(.system(size: 11)).strikethrough(task.isCompleted).lineLimit(1)
                                .foregroundStyle(task.isCompleted ? Color.secondary : Color.primary)
                        }
                    }
                    if remainingClasses + remainingTasks > 0 {
                        Text([remainingClasses > 0 ? "+\(remainingClasses) 次课" : nil,
                              remainingTasks > 0 ? "+\(remainingTasks) 待办" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(isSelected ? theme.selection : Color(nsColor: .windowBackgroundColor))
            .overlay { if isSelected { Rectangle().strokeBorder(theme.selectionBorder, lineWidth: 1.5) } }
            .opacity(sameMonth ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TimetableCalendar.formatted(day, template: "yMMMdEEEE"))
        .accessibilityValue("\(isSelected ? "已选择，" : "")\(dayClasses.count) 次课，\(dayTasks.count) 项待办")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
