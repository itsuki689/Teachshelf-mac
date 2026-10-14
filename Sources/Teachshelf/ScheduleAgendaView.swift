import SwiftUI
import TeachshelfCore

/// The day surface shows one civil date. Untimed deadlines never occupy the execution timeline.
struct ScheduleAgendaView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var selection: ScheduleSelection
    let onMeeting: (ScheduleMeetingContext) -> Void
    let onPlan: (PlanOccurrence) -> Void
    let onCreateTask: (Date) -> Void

    private var events: [PlanDisplayEvent] {
        ScheduleData.planEvents(on: selection.selectedDate, in: store.state, selection: selection)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(TimetableCalendar.formatted(selection.selectedDate, template: "MMM d EEEE"))
                            .font(.title2.weight(.semibold))
                        Text("\(events.filter { !$0.isDeadline }.count) 项安排 · \(events.filter(\.isDeadline).count) 个 DDL")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { onCreateTask(selection.selectedDate) } label: { Label("新建计划", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
                if events.isEmpty {
                    Text("这一天没有安排").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
                } else {
                    eventSection("全天", events: events.filter { !$0.isDeadline && $0.isAllDay })
                    eventSection("时间安排", events: events.filter { !$0.isDeadline && !$0.isAllDay })
                    eventSection("当天截止", events: events.filter(\.isDeadline))
                }
            }.frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).padding(22)
        }
    }

    @ViewBuilder private func eventSection(_ title: String, events: [PlanDisplayEvent]) -> some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(events) { event in PlanEventRow(event: event) { open(event) } }
            }
        }
    }

    private func open(_ event: PlanDisplayEvent) {
        switch event.source {
        case .plan(let plan): onPlan(plan)
        case .course(let course):
            guard let term = store.state.timetableTerms.first(where: { $0.id == course.termID }) else { return }
            onMeeting(ScheduleMeetingContext(term: term, meeting: course.meeting, date: course.day,
                                            selectedDate: selection.selectedDate, originalDate: course.originalDate))
        }
    }
}
