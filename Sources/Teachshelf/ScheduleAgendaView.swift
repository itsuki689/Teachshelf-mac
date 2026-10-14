import SwiftUI
import TeachshelfCore

struct ScheduleAgendaView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var selection: ScheduleSelection
    let onMeeting: (ScheduleMeetingContext) -> Void
    let onTask: (StudyTask) -> Void
    let onCreateTask: (Date) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(ScheduleData.agendaDays(selection: selection), id: \.self) { day in
                    daySection(day)
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private func daySection(_ day: Date) -> some View {
        let classes = ScheduleData.classes(on: day, in: store.state, selection: selection)
        let tasks = ScheduleData.tasks(on: day, in: store.state, selection: selection)
        let items = agendaItems(classes: classes, tasks: tasks)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(TimetableCalendar.formatted(day, template: "MMM d EEEE")).font(.title3.weight(.semibold))
                        if TimetableCalendar.calendar.isDateInToday(day) {
                            Text("今天").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    Text("\(classes.count) 次课 · \(tasks.count) 项待办").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { onCreateTask(day) } label: { Label("待办", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .help("在\(TimetableCalendar.formatted(day, template: "MMM d"))新建待办")
            }
            if items.isEmpty {
                Text("这一天还没有安排").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(items) { item in
                    switch item.event {
                    case .course(let event):
                        ScheduleClassCard(event: event) { openMeeting(event) }
                    case .task(let task):
                        ScheduleTaskCard(task: task) { onTask(task) }
                    }
                }
            }
        }
    }

    private func openMeeting(_ event: TimetableCalendar.DayClass) {
        guard let term = store.state.timetableTerms.first(where: { $0.id == event.termID }) else { return }
        onMeeting(ScheduleMeetingContext(term: term, meeting: event.meeting, date: event.day,
                                        selectedDate: selection.selectedDate, originalDate: event.originalDate))
    }

    private func agendaItems(classes: [TimetableCalendar.DayClass], tasks: [StudyTask]) -> [AgendaItem] {
        let calendar = TimetableCalendar.calendar
        let courseItems = classes.map { event in
            let startMinute = event.timeLabel == nil ? nil : store.state.timetableTerms
                .first(where: { $0.id == event.termID })?.sectionTimes
                .first(where: { $0.section == event.meeting.startSection })?.startMinute
            // A section number is not a wall-clock time; keep unconfigured classes separate.
            return AgendaItem(id: "course-\(event.id)", group: startMinute == nil ? 2 : 1,
                              order: startMinute ?? event.meeting.startSection, title: event.meeting.title, event: .course(event))
        }
        let taskItems = tasks.map { task in
            let date = task.deadline ?? task.startsAt
            let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            return AgendaItem(id: "task-\(task.id)", group: task.isAllDay ? 0 : 1,
                              order: task.isAllDay ? 0 : minute, title: task.title, event: .task(task))
        }
        return (courseItems + taskItems).sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}

private struct AgendaItem: Identifiable {
    enum Event {
        case course(TimetableCalendar.DayClass)
        case task(StudyTask)
    }
    let id: String
    let group: Int
    let order: Int
    let title: String
    let event: Event
}
