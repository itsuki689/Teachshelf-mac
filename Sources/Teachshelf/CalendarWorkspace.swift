import SwiftUI
import TeachshelfCore


struct CalendarWorkspace: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ViewState<Date> private var month = Calendar.current.startOfDay(for: Date())
    @ViewState<Date> private var selectedDay = Calendar.current.startOfDay(for: Date())
    @ViewState<UUID?> private var courseID: UUID?
    @ViewState<StudyTask?> private var editingTask: StudyTask?
    @ViewState<Bool> private var creating = false
    private let calendar = Calendar.current
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    private var calendarTasks: [StudyTask] {
        store.state.tasks.filter { !$0.isArchived && $0.showOnCalendar && (courseID == nil || $0.courseID == courseID) }
    }

    private var days: [Date] {
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else { return [] }
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -offset, to: start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func tasks(on day: Date) -> [StudyTask] {
        calendarTasks.filter { calendar.isDate($0.deadline ?? $0.startsAt, inSameDayAs: day) }
            .sorted {
                if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
                return ($0.deadline ?? $0.startsAt) < ($1.deadline ?? $1.startsAt)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("日历").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("把课程与截止时间放在一起，安排自己的节奏。").foregroundStyle(.secondary)
                }
                Spacer()
                Button { creating = true } label: { Label("新建待办", systemImage: "plus") }
                    .appPrimaryButton().controlSize(.regular)
            }.padding(24)

            HStack(spacing: 14) {
                Text(month.formatted(.dateTime.year().month(.wide))).font(.title2.weight(.semibold)).frame(minWidth: 170, alignment: .leading)
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }.help("上个月")
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }.help("下个月")
                Button("今天") { month = Date(); selectedDay = calendar.startOfDay(for: Date()) }
                Spacer()
                CourseMenu(selection: $courseID, courses: store.state.courses).frame(width: 180)
            }.padding(.horizontal, 24).padding(.bottom, 18)
            Divider()

            WorkspaceSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(weekdays, id: \.self) { day in
                            Text(day).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 13)
                        }
                    }
                    GeometryReader { geometry in
                        let rowHeight = max(83, geometry.size.height / 6)
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                                ForEach(days, id: \.self) { day in
                                    dayCell(day, height: rowHeight - 1)
                                }
                            }.background(Color.primary.opacity(0.07))
                        }
                    }
                }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selectedDay.formatted(.dateTime.month().day().weekday(.wide))).font(.title3.weight(.semibold))
                        Text("\(tasks(on: selectedDay).count) 项安排").font(.caption).foregroundStyle(.secondary)
                    }.padding(22)
                    Divider()
                    if tasks(on: selectedDay).isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "sun.max").font(.system(size: 34)).foregroundStyle(.tertiary)
                            Text("这一天还没有安排").foregroundStyle(.secondary)
                            Button("添加待办") { creating = true }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(tasks(on: selectedDay)) { task in agendaCard(task) }
                            }.padding(18)
                        }
                    }
                }.frame(minWidth: 240, idealWidth: 280, maxWidth: 340, maxHeight: .infinity)
            }
        }
        .sheet(item: $editingTask) { TaskEditor(task: $0) }
        .sheet(isPresented: $creating) {
            TaskEditor(task: StudyTask(title: "", courseID: courseID, startsAt: selectedDay), isNew: true)
        }
    }

    private func moveMonth(_ offset: Int) {
        guard let newMonth = calendar.date(byAdding: .month, value: offset, to: month) else { return }
        month = newMonth
        if let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: newMonth)) { selectedDay = firstDay }
    }

    private func courseColor(_ task: StudyTask) -> Color {
        if let course = store.state.courses.first(where: { $0.id == task.courseID }) { return Color(hex: course.colorHex) }
        return theme.ink
    }

    private func dayCell(_ day: Date, height: CGFloat) -> some View {
        let sameMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        let dayTasks = tasks(on: day)
        return Button {
            selectedDay = day
            if !sameMonth { month = day }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.callout.weight(isToday || isSelected ? .semibold : .regular))
                        .foregroundStyle(isToday ? Color.white : (sameMonth ? Color.primary : Color.secondary))
                        .frame(width: 25, height: 25)
                        .background(isToday ? theme.controlAccent : Color.clear, in: Circle())
                    Spacer()
                }
                ForEach(Array(dayTasks.prefix(2))) { task in
                    HStack(spacing: 4) {
                        Circle().fill(task.isCompleted ? Color.secondary : courseColor(task)).frame(width: 5, height: 5)
                        Text(task.title).font(.system(size: 11)).strikethrough(task.isCompleted).lineLimit(1)
                            .foregroundStyle(task.isCompleted ? Color.secondary : Color.primary)
                    }
                }
                if dayTasks.count > 2 { Text("另 \(dayTasks.count - 2) 项").font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(isSelected ? theme.selection : Color(nsColor: .windowBackgroundColor))
            .overlay { if isSelected { Rectangle().strokeBorder(theme.selectionBorder, lineWidth: 1.5) } }
            .opacity(sameMonth ? 1 : 0.55)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func agendaCard(_ task: StudyTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button { store.setTaskCompleted(task) } label: {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(task.isCompleted ? theme.ink : Color.secondary)
                }.buttonStyle(.plain).padding(.top, 1)
                Button { editingTask = task } label: {
                    Text(task.title).font(.headline).strikethrough(task.isCompleted).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Circle().fill(courseColor(task)).frame(width: 6, height: 6)
                Text(task.courseID == nil ? (task.courseNameSnapshot ?? "未分配课程") : store.courseName(task.courseID)).lineLimit(1)
                Spacer()
                Text(task.kind)
            }.font(.caption).foregroundStyle(.secondary)
            if let deadline = task.deadline {
                Label(task.isAllDay ? "当天截止" : "\(deadline.formatted(.dateTime.hour().minute())) 截止", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !task.content.isEmpty { Text(task.content).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(courseColor(task)).frame(width: 3).padding(.vertical, 14) }
        .contextMenu {
            Button("编辑待办") { editingTask = task }
            Button(task.isCompleted ? "标为未完成" : "完成待办") { store.setTaskCompleted(task) }
            Button("归档待办") { store.archiveTask(task) }
        }
    }
}
