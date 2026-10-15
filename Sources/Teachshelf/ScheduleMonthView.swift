import SwiftUI
import TeachshelfCore

struct ScheduleMonthView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ObservedObject var selection: ScheduleSelection
    private let calendar = TimetableCalendar.calendar
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    private var days: [Date] {
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: selection.selectedDate)) else { return [] }
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        guard let first = calendar.date(byAdding: .day, value: -offset, to: start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { weekday in
                    Text(weekday).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 42)
                }
            }
            GeometryReader { geometry in
                let rowHeight = max(1, (geometry.size.height - 5) / 6)
                let compact = (geometry.size.width - 6) / 7 < 84
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                    ForEach(days, id: \.self) { day in dayCell(day, height: rowHeight, compact: compact) }
                }.background(Color.primary.opacity(0.07))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dayCell(_ day: Date, height: CGFloat, compact: Bool) -> some View {
        let sameMonth = calendar.isDate(day, equalTo: selection.selectedDate, toGranularity: .month)
        let isSelected = calendar.isDate(day, inSameDayAs: selection.selectedDate)
        let isToday = calendar.isDateInToday(day)
        let events = ScheduleData.planEvents(on: day, in: store.state, selection: selection, forMonth: true)
        let dueCount = events.filter(\.isDeadline).count
        let eventLimit = height < 96 ? 1 : 2
        let shown = Array(events.prefix(eventLimit))
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
                    if dueCount > 0 {
                        Label("\(dueCount) DDL", systemImage: "flag.fill")
                            .font(.system(size: 10)).foregroundStyle(theme.ink).lineLimit(1)
                    }
                    if events.count > dueCount {
                        Text("\(events.count - dueCount) 项安排").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    ForEach(shown) { event in
                        HStack(spacing: 4) {
                            Image(systemName: event.isDeadline ? "flag.fill" : "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(ScheduleEventColor.event(event, in: store.state, theme: theme))
                            Text(event.title).font(.system(size: 11)).lineLimit(1)
                                .strikethrough(event.isCompleted)
                                .foregroundStyle(event.isCompleted ? Color.secondary : Color.primary)
                        }
                    }
                    if events.count > shown.count {
                        Text("+\(events.count - shown.count) 项").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
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
        .accessibilityValue("\(isSelected ? "已选择，" : "")\(dueCount) 个 DDL，\(events.count - dueCount) 项安排")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
