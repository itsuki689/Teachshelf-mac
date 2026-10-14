import SwiftUI
import TeachshelfCore

struct PlanEventRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    let event: PlanDisplayEvent
    var compact = false
    let onOpen: () -> Void

    var body: some View {
        let color = ScheduleEventColor.course(event.courseID, in: store.state, theme: theme)
        let shape = RoundedRectangle(cornerRadius: event.planOccurrence == nil ? 0 : 10)
        HStack(alignment: .top, spacing: compact ? 8 : 12) {
            if let occurrence = event.planOccurrence, event.completionRequired {
                Button {
                    store.changePlan(id: occurrence.task.id, label: event.isCompleted ? "重新打开计划" : "完成计划") {
                        try $0.setPlanOccurrenceCompleted(id: occurrence.task.id, originalDate: occurrence.originalDate,
                                                         completed: !event.isCompleted)
                    }
                } label: {
                    Image(systemName: event.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(event.isCompleted ? theme.ink : Color.secondary)
                        .font(.system(size: compact ? 16 : 20))
                }.buttonStyle(.plain).accessibilityLabel("\(event.isCompleted ? "重新打开" : "完成")计划：\(event.title)")
            } else {
                Image(systemName: event.isDeadline ? "flag.fill" : (event.isFixed ? "calendar" : "circle.fill"))
                    .font(.system(size: compact ? 11 : 16)).foregroundStyle(color).frame(width: compact ? 16 : 20)
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title).font(.system(size: compact ? 12 : 15, weight: .medium))
                        .strikethrough(event.isCompleted).lineLimit(compact ? 3 : nil)
                    Text(event.timeLabel + " · " + (event.isDeadline ? "DDL · 固定" : (event.isFixed ? "固定计划" : "活动计划")))
                        .font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary)
                    if !event.location.isEmpty {
                        Label(event.location, systemImage: "mappin.and.ellipse")
                            .font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary).lineLimit(compact ? 2 : nil)
                    }
                    if !compact, let task = event.planOccurrence?.task, !task.content.isEmpty {
                        Text(task.content).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看\(event.isDeadline ? "DDL" : "计划")：\(event.title)，\(event.timeLabel)")
        }
        .padding(compact ? 0 : 14)
        .background {
            if !compact {
                shape.fill(Color(nsColor: .textBackgroundColor))
                    .overlay { shape.fill(color.opacity(theme.isDark ? 0.22 : 0.12)) }
            }
        }
        .opacity(event.isCompleted ? 0.65 : 1)
    }
}
