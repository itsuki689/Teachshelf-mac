import SwiftUI
import TeachshelfCore

struct WeekPlanControls: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ObservedObject var selection: ScheduleSelection
    let adjusting: Bool
    let onOpen: (PlanDisplayEvent) -> Void

    var body: some View {
        if let event = ScheduleEventEditing.selected(in: store), ScheduleEventEditing.canSelect(event, fixedEditing: adjusting) {
            let editable = ScheduleEventEditing.canEdit(event, fixedEditing: adjusting)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("已选计划").font(.caption.weight(.semibold)).foregroundStyle(theme.ink)
                    Spacer()
                    Button { selection.selectedEventID = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("取消选中计划")
                }
                Text(event.title).font(.callout.weight(.semibold)).lineLimit(3)
                if let range = selection.timePreview ?? ScheduleEventEditing.range(of: event) {
                    edgeRow("开始", edge: .start, minute: range.start, event: event)
                    edgeRow("结束", edge: .end, minute: range.end, event: event)
                    HStack(spacing: 8) {
                        moveButton("前一天", icon: "arrow.left", event: event, days: -1)
                        moveButton("提前10分钟", icon: "arrow.up", event: event, minutes: -10)
                        moveButton("推迟10分钟", icon: "arrow.down", event: event, minutes: 10)
                        moveButton("后一天", icon: "arrow.right", event: event, days: 1)
                        Spacer(minLength: 0)
                    }
                    .disabled(!editable || store.isBusy)
                    Text("拖动上下边缘吸附10分钟；±精调1分钟。方向键整体移动，双击打开详情。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("跨天安排或未设置作息的课程，请在详情中调整。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("编辑详情") { onOpen(event) }.buttonStyle(.borderless)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.selection, in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func edgeRow(_ title: String, edge: PlanTimeEdge, minute: Int, event: PlanDisplayEvent) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(TimetableLayout.clock(minute)).font(.system(.callout, design: .monospaced))
            Spacer(minLength: 0)
            Button { nudge(event, edge: edge, minutes: -1) } label: { Image(systemName: "minus") }
                .accessibilityLabel("\(title)提前1分钟")
                .disabled(ScheduleEventEditing.range(of: event).map { edge == .start ? $0.start == 0 : $0.duration == 1 } ?? true)
            Button { nudge(event, edge: edge, minutes: 1) } label: { Image(systemName: "plus") }
                .accessibilityLabel("\(title)推迟1分钟")
                .disabled(ScheduleEventEditing.range(of: event).map { edge == .end ? $0.end == 1440 : $0.duration == 1 } ?? true)
        }.buttonStyle(.bordered).controlSize(.small)
            .disabled(!ScheduleEventEditing.canEdit(event, fixedEditing: adjusting) || store.isBusy)
    }

    private func nudge(_ event: PlanDisplayEvent, edge: PlanTimeEdge, minutes: Int) {
        ScheduleEventEditing.nudge(event, minutes: minutes, edge: edge, store: store, fixedEditing: adjusting)
    }
    private func moveButton(_ title: String, icon: String, event: PlanDisplayEvent, minutes: Int = 0, days: Int = 0) -> some View {
        Button { ScheduleEventEditing.nudge(event, minutes: minutes, days: days, store: store, fixedEditing: adjusting) } label: {
            Image(systemName: icon).frame(width: 14)
        }.buttonStyle(.bordered).controlSize(.small).help(title).accessibilityLabel("整体\(title)")
            .disabled(ScheduleEventEditing.range(of: event)?.shifted(by: minutes) == nil)
    }
}
