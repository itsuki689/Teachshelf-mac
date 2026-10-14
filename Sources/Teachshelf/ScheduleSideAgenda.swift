import SwiftUI
import TeachshelfCore

struct ScheduleSideAgenda: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ObservedObject var selection: ScheduleSelection
    let onMeeting: (ScheduleMeetingContext) -> Void
    let onPlan: (PlanOccurrence) -> Void
    let onTask: (StudyTask) -> Void

    private var events: [PlanDisplayEvent] {
        ScheduleData.planEvents(on: selection.selectedDate, in: store.state, selection: selection,
                                forMonth: selection.mode == .month)
    }
    private var loosePlans: [StudyTask] {
        ScheduleData.filteredPlans(in: store.state, selection: selection).filter {
            switch selection.planFilter {
            case .all: return !$0.hasExecutionTime && $0.deadline == nil && $0.cancelledAt == nil
            case .unplanned: return !$0.hasExecutionTime
            case .pending: return $0.completionRequired && !$0.isCompleted && $0.cancelledAt == nil
            case .completed: return $0.isCompleted || $0.exceptions.contains { $0.completedAt != nil }
            case .cancelled: return $0.cancelledAt != nil || $0.exceptions.contains { $0.cancelledAt != nil }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TimetableCalendar.formatted(selection.selectedDate, template: "MMM d EEEE"))
                .font(.callout.weight(.semibold))
            if selection.mode == .month {
                Text("默认显示 DDL，其他安排可在详情中加入月历。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if events.isEmpty {
                Text(selection.mode == .month ? "这一天没有月历条目" : "这一天没有安排")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in PlanEventRow(event: event, compact: true) { open(event) } }
            }
            if !loosePlans.isEmpty {
                Divider()
                Text(selection.planFilter == .all ? "待安排" : selection.planFilter.rawValue)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(loosePlans) { plan in
                    Button { onTask(plan) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plan.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(plan.cancelledAt != nil ? "已取消" : (plan.deadline.map { "截止 \(TimetableCalendar.formatted($0, template: "MMMd"))" } ?? "尚未安排时间"))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("编辑计划：\(plan.title)")
                }
            }
            if let term = selection.term(in: store.state) {
                let meetings = ScheduleData.freeMeetings(in: store.state, selection: selection)
                if !meetings.isEmpty {
                    Divider()
                    Text("未定时课程").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(meetings) { meeting in
                        Button(meeting.title) {
                            onMeeting(ScheduleMeetingContext(term: term, meeting: meeting, date: nil,
                                                            selectedDate: selection.selectedDate))
                        }.buttonStyle(.plain).font(.system(size: 12)).lineLimit(2)
                    }
                }
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
