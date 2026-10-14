import SwiftUI
import TeachshelfCore

enum PlanExceptionRestoreKind { case cancellation, completion, all }

/// A recovery path for individual occurrences that no longer appear on the calendar.
struct PlanExceptionHistory: View {
    @EnvironmentObject private var store: AppStore
    let plan: StudyTask
    var onRestored: (Date, PlanExceptionRestoreKind) -> Void = { _, _ in }
    @ViewState<Date?> private var confirmingReset: Date?

    private var changes: [PlanException] {
        plan.exceptions.filter { change in
            change.cancelledAt != nil || change.completedAt != nil || change.completedOverride != nil || change.details != nil
                || change.startsAt != nil || change.endsAt != nil || change.deadline != nil || change.location != nil
        }.sorted { $0.originalDate > $1.originalDate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(changes, id: \.originalDate) { change in
                let effective = PlanCalendar.snapshot(of: plan, originalDate: change.originalDate)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("原定 \(change.originalDate.formatted(.dateTime.month().day().weekday()))")
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 4)
                        if change.cancelledAt != nil {
                            Label("本次已取消", systemImage: "xmark.circle").foregroundStyle(.secondary)
                        } else if change.completedAt != nil {
                            Label("本次已完成", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        } else if change.completedOverride == false {
                            Label("本次待完成", systemImage: "circle").foregroundStyle(.secondary)
                        }
                    }
                    if change.details != nil {
                        Text(effective.title == plan.title ? "本次内容已单独调整" : effective.title)
                            .foregroundStyle(.secondary)
                    }
                    if effective.hasExecutionTime {
                        Text("执行 \(effective.startsAt.formatted(effective.isAllDay ? .dateTime.month().day() : .dateTime.month().day().hour().minute()))")
                            .foregroundStyle(.secondary)
                    }
                    if let deadline = effective.deadline {
                        Text("DDL \(deadline.formatted(effective.deadlineIsAllDay ? .dateTime.month().day() : .dateTime.month().day().hour().minute()))")
                            .foregroundStyle(.secondary)
                    }
                    if !effective.location.isEmpty { Label(effective.location, systemImage: "mappin").foregroundStyle(.secondary) }
                    HStack(spacing: 14) {
                        if change.cancelledAt != nil {
                            Button("恢复本次") { restore(change.originalDate, kind: .cancellation) }
                                .help("恢复这次安排，保留已经调整的时间和地点")
                        }
                        if change.completedAt != nil {
                            Button("重新打开本次") { restore(change.originalDate, kind: .completion) }
                        }
                        Spacer(minLength: 0)
                        Button("还原原安排") { confirmingReset = change.originalDate }
                    }.buttonStyle(.borderless)
                        .disabled(plan.isArchived || plan.isCancelled || store.isBusy)
                }.font(.caption)
                if change.originalDate != changes.last?.originalDate { Divider() }
            }
            if plan.isCancelled {
                Text("整组计划已取消，请先恢复整组，再调整单次记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .environment(\.calendar, PlanCalendar.calendar)
        .environment(\.timeZone, PlanCalendar.calendar.timeZone)
        .confirmationDialog("还原这次的原始安排？", isPresented: Binding(
            get: { confirmingReset != nil },
            set: { if !$0 { confirmingReset = nil } }
        )) {
            Button("还原原安排", role: .destructive) {
                guard let date = confirmingReset else { return }
                restore(date, kind: .all); confirmingReset = nil
            }
            Button("返回", role: .cancel) { confirmingReset = nil }
        } message: {
            Text("清除这次的时间、内容、完成和取消变更，恢复原重复安排。其他次数保留，可以撤销。")
        }
    }

    private func restore(_ date: Date, kind: PlanExceptionRestoreKind) {
        let label: String
        switch kind {
        case .cancellation: label = "恢复本次安排"
        case .completion: label = "重新打开本次计划"
        case .all: label = "还原本次安排"
        }
        let restored = store.changePlan(id: plan.id, label: label) { repository in
            switch kind {
            case .cancellation: try repository.setPlanOccurrenceCancelled(id: plan.id, originalDate: date, cancelled: false)
            case .completion: try repository.setPlanOccurrenceCompleted(id: plan.id, originalDate: date, completed: false)
            case .all: try repository.restorePlanOccurrence(id: plan.id, originalDate: date)
            }
        }
        if restored { onRestored(date, kind) }
    }
}
