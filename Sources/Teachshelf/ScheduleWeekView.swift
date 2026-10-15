import SwiftUI
import AppKit
import TeachshelfCore

/// Seven complete days in one bounded canvas. There is deliberately no scroll
/// container: the inspector carries details that do not fit on a compact card.
struct ScheduleWeekView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var selection: ScheduleSelection
    @Binding var adjusting: Bool
    let onMeeting: (ScheduleMeetingContext) -> Void
    let onPlan: (PlanOccurrence) -> Void
    let onCreate: (Date, Date) -> Void
    @ViewState private var drag: WeekPlanDrag?
    @ViewState private var resize: WeekPlanResize?
    @ViewState private var creation: WeekCreation?
    @ViewState private var cancelledDrag = false
    @ViewState private var lastDragEnded = Date.distantPast
    @GestureState private var gestureActive = false
    @FocusState private var keyboardFocused: Bool

    private let calendar = TimetableCalendar.calendar
    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private var term: TimetableTerm? { selection.term(in: store.state) }
    private var days: [Date] { ScheduleData.weekDays(in: store.state, selection: selection) }
    private var isUndated: Bool { term != nil && term?.weekOneMonday == nil }
    private var sections: Int { TimetableLayout.sectionCount(in: term) }
    private var sectionTimes: [TimetableSectionTime] { term?.sectionTimes ?? [] }

    var body: some View {
        GeometryReader { geometry in
            let metrics = ScheduleWeekMetrics(viewport: geometry.size, sectionCount: sections)
            let timeline = ScheduleWeekTimeline(height: metrics.rowHeight * CGFloat(sections),
                                                sectionCount: sections, times: sectionTimes,
                                                outerHoursExtraHeight: metrics.outerHoursExtraHeight)
            VStack(spacing: 0) {
                TimelineView(.periodic(from: Date(), by: 60)) { context in
                    weekdayHeader(metrics, now: context.date)
                }
                ZStack(alignment: .topLeading) {
                    timeCanvas(metrics, timeline: timeline)
                    dragPreview
                }
                .coordinateSpace(name: "ScheduleWeekCanvas")
            }
            .padding(.horizontal, metrics.horizontalInset)
            .padding(.vertical, metrics.verticalInset)
        }
        .clipped()
        .focusable().focusEffectDisabled().focused($keyboardFocused)
        .onKeyPress(phases: [.down, .repeat], action: handleKey)
        .onExitCommand {
            cancelledDrag = true; creation = nil; cancelDrag()
        }
        .onDisappear { drag = nil; resize = nil; creation = nil; selection.timePreview = nil }
        .onChange(of: adjusting) { _, _ in cancelDrag() }
        .onChange(of: selection.selectedDate) { _, _ in cancelDrag(); creation = nil }
        .onChange(of: selection.termID) { _, _ in cancelDrag(); creation = nil }
        .onChange(of: selection.courseID) { _, _ in cancelDrag(); creation = nil }
        .onChange(of: selection.showsCourses) { _, _ in cancelDrag() }
        .onChange(of: selection.showsTasks) { _, _ in cancelDrag() }
        .onChange(of: selection.planFilter) { _, _ in cancelDrag(); creation = nil }
        .onChange(of: scenePhase) { _, value in
            if value != .active { cancelDrag(); creation = nil }
        }
        .onChange(of: gestureActive) { _, active in
            guard !active else { return }
            Task { @MainActor in
                await Task.yield()
                if !gestureActive { cancelDrag(); creation = nil; cancelledDrag = false }
            }
        }
    }

    private func weekdayHeader(_ metrics: ScheduleWeekMetrics, now: Date) -> some View {
        HStack(spacing: 0) {
            Text("时间").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: metrics.timeColumnWidth, height: metrics.headerHeight)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.065)).frame(width: 0.7) }
            Text("节次").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: metrics.sectionColumnWidth, height: metrics.headerHeight)
            ForEach(0..<7, id: \.self) { index in
                let date = dayDate(index)
                let selected = date.map { calendar.isDate($0, inSameDayAs: selection.selectedDate) } ?? false
                let isToday = date.map { calendar.isDate($0, inSameDayAs: now) } ?? false
                let events = date.map { bandEvents(on: $0) } ?? []
                VStack(spacing: 4) {
                    Button {
                        if let date { selection.setDate(date) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(weekdays[index]).font(.system(size: 13, weight: .semibold))
                            if isToday {
                                Circle().fill(Color.white).frame(width: 4, height: 4)
                            }
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .disabled(date == nil)
                    .accessibilityLabel(date.map { TimetableCalendar.formatted($0, template: "MMM d EEEE") } ?? weekdays[index])
                    .accessibilityValue([isToday ? "今天" : nil, selected ? "已选择" : nil].compactMap { $0 }.joined(separator: "，"))
                    if let date {
                        HStack(spacing: 2) {
                            Button { selection.setDate(date) } label: {
                                Text(TimetableLayout.dateLabel(date)).font(.system(size: 11))
                                    .foregroundStyle(isToday ? Color.white.opacity(0.9) : Color.secondary)
                            }.accessibilityLabel("选择 \(TimetableCalendar.formatted(date, template: "MMM d"))")
                            HStack(spacing: 0) {
                                dayMarker(.allDay, events: events, date: date)
                                dayMarker(.deadlines, events: events, date: date)
                            }
                        }
                    }
                }
                .buttonStyle(.plain).disabled(date == nil)
                .frame(width: metrics.columnWidth, height: metrics.headerHeight)
                .foregroundStyle(isToday ? Color.white : Color.primary)
                .contentShape(Rectangle())
                .background(isToday ? theme.controlAccent : (selected ? Color.gray.opacity(theme.isDark ? 0.28 : 0.20) : .clear))
            }
        }
    }

    @ViewBuilder private func dayMarker(_ section: ScheduleDaySection, events: [PlanDisplayEvent], date: Date) -> some View {
        let items = events.filter { $0.daySection == section }
        if !items.isEmpty {
            let title = section == .deadlines ? "DDL" : "全天计划"
            Button { selection.showAgenda(on: date, section: section, in: store.state) } label: {
                Circle().fill(section == .deadlines ? Color.red : Color.cyan)
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 0.5) }
                    .frame(width: 7, height: 7)
                    .frame(width: 12, height: 14).contentShape(Rectangle())
            }
            .help("\(items.count) 项\(title)：\(items.map(\.title).joined(separator: "、"))。点击查看当天详情。")
            .accessibilityLabel("\(TimetableCalendar.formatted(date, template: "MMM d"))，\(items.count) 项\(title)，跳转到日视图")
        }
    }

    private func timeCanvas(_ metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(creationGesture(metrics, timeline: timeline))
            gridBackground(metrics, timeline: timeline).allowsHitTesting(false)
            targetPreview(metrics, timeline: timeline).allowsHitTesting(false)
            creationPreview(metrics, timeline: timeline).allowsHitTesting(false)
            if isUndated, let term {
                virtualCourses(term, metrics: metrics, timeline: timeline)
            } else {
                ForEach(0..<7, id: \.self) { index in
                    if let day = dayDate(index) {
                        let events = timedEvents(on: day)
                        let lanes = ScheduleWeekLanes.placements(events.map {
                            let rect = timeRect($0, day: day, timeline: timeline)
                            return ScheduleWeekSpan(id: $0.id, top: rect.minY, bottom: rect.maxY)
                        })
                        ForEach(lanes) { lane in
                            if let event = events.first(where: { $0.id == lane.id }) {
                                timedCard(event, day: day, index: index, lane: lane, metrics: metrics, timeline: timeline)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: metrics.labelWidth + metrics.columnWidth * 7, height: timeline.height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 0.7).allowsHitTesting(false)
        }
    }

    private func gridBackground(_ metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> some View {
        ZStack(alignment: .topLeading) {
            // Only lunch and the hours outside teaching retain their own space.
            ForEach(Array(timeline.segments.enumerated()), id: \.offset) { _, segment in
                if segment.upper > segment.lower,
                   !timeline.times.contains(where: { Double($0.startMinute) <= segment.start && Double($0.endMinute) >= segment.end }) {
                    Rectangle().fill(Color.primary.opacity(0.018))
                        .frame(width: metrics.labelWidth + metrics.columnWidth * 7,
                               height: max(0, segment.upper - segment.lower))
                        .offset(y: segment.lower)
                }
            }
            ForEach(0..<7, id: \.self) { index in
                if let date = dayDate(index), calendar.isDate(date, inSameDayAs: selection.selectedDate) {
                    Rectangle().fill(Color.gray.opacity(theme.isDark ? 0.22 : 0.12))
                        .frame(width: metrics.columnWidth, height: timeline.height)
                        .offset(x: metrics.labelWidth + CGFloat(index) * metrics.columnWidth)
                }
            }
            ForEach(timeline.gridMinutes, id: \.self) { minute in
                let isStart = timeline.times.contains { $0.startMinute == minute }
                Rectangle().fill(Color.primary.opacity(isStart ? 0.09 : 0.065))
                    .frame(width: metrics.labelWidth + metrics.columnWidth * 7, height: 0.7)
                    .offset(y: timeline.y(for: Double(minute)))
            }
            ForEach(timeline.times, id: \.section) { time in
                let top = timeline.y(for: Double(time.startMinute))
                let bottom = timeline.y(for: Double(time.endMinute))
                if sectionTimes.contains(where: { $0.section == time.section }) || term == nil {
                    clockTick(time.startMinute, y: top, metrics: metrics)
                }
                Text("\(time.section)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.sectionColumnWidth, height: max(1, bottom - top))
                    .offset(x: metrics.timeColumnWidth, y: top)
            }
            Text("早间").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: metrics.sectionColumnWidth, height: timeline.y(for: Double(timeline.times.first?.startMinute ?? 480)))
                .offset(x: metrics.timeColumnWidth)
            if let lunch = timeline.lunchBreak {
                let top = timeline.y(for: Double(lunch.lowerBound))
                let bottom = timeline.y(for: Double(lunch.upperBound))
                if sectionTimes.contains(where: { $0.endMinute == lunch.lowerBound }) || term == nil {
                    clockTick(lunch.lowerBound, y: top, metrics: metrics)
                }
                Text("午休").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: metrics.sectionColumnWidth, height: bottom - top)
                    .offset(x: metrics.timeColumnWidth, y: top)
            }
            if let end = timeline.times.last?.endMinute {
                let nightTop = timeline.y(for: Double(end))
                if sectionTimes.contains(where: { $0.endMinute == end }) || term == nil {
                    clockTick(end, y: nightTop, metrics: metrics)
                }
                Text("夜间").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: metrics.sectionColumnWidth, height: max(1, timeline.height - nightTop))
                    .offset(x: metrics.timeColumnWidth, y: nightTop)
            }
            Path { path in
                path.move(to: CGPoint(x: metrics.timeColumnWidth, y: 0))
                path.addLine(to: CGPoint(x: metrics.timeColumnWidth, y: timeline.height))
                for index in 0...7 {
                    let x = metrics.labelWidth + CGFloat(index) * metrics.columnWidth
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: timeline.height))
                }
            }.stroke(Color.primary.opacity(0.065), lineWidth: 1)
        }
        .frame(width: metrics.labelWidth + metrics.columnWidth * 7, height: timeline.height, alignment: .topLeading)
    }

    private func clockTick(_ minute: Int, y: CGFloat, metrics: ScheduleWeekMetrics) -> some View {
        Text(TimetableLayout.clock(minute)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: max(0, metrics.timeColumnWidth - 8), height: 16)
            .background(Color(nsColor: .textBackgroundColor))
            .offset(x: 4, y: y - 8)
    }

    private func timedCard(_ event: PlanDisplayEvent, day: Date, index: Int, lane: ScheduleWeekLane,
                           metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> some View {
        let vertical: CGRect
        if let resize, resize.event.id == event.id {
            vertical = timeline.intervalRect(start: Double(resize.target.start), end: Double(resize.target.end), minimumHeight: 13)
        } else { vertical = timeRect(event, day: day, timeline: timeline) }
        let rect = metrics.eventRect(dayIndex: index, lane: lane.lane, laneCount: lane.laneCount,
                                     top: vertical.minY, height: vertical.height)
        let selectable = ScheduleEventEditing.canSelect(event, fixedEditing: adjusting)
        let selected = selectable && selection.selectedEventID == event.id
        let hint = selectable
            ? "单击选中，双击编辑" + (canDrag(event) ? " · 拖动调整，上下边缘改变时间" : " · 请在详情中调整时间")
            : "双击查看详情 · 开启编辑固定计划后可选中和调整"
        let card = Button {
            guard drag == nil, resize == nil, Date().timeIntervalSince(lastDragEnded) > 0.15 else { return }
            select(event)
        } label: {
            cardContent(event, size: rect.size)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: event.planOccurrence == nil ? 0 : 5)
                            .strokeBorder(theme.controlAccent, lineWidth: 2).allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain).frame(width: rect.width, height: rect.height)
        .opacity(drag?.event.id == event.id ? 0.16 : 1)
        .help("\(event.title) · \(event.timeLabel) · \(hint)")
        .accessibilityLabel("\(event.title)，\(event.timeLabel)，\(event.location)")
        .accessibilityValue(selectable ? (selected ? "已选中，可用方向键移动" : "未选中") : "固定计划，未开启编辑，不可选中")
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(event) })
        .contextMenu { Button("查看与编辑…") { open(event) } }
        return Group {
            if canDrag(event) { card.highPriorityGesture(eventDrag(event, sourceRect: rect, metrics: metrics, timeline: timeline)) }
            else { card }
        }
        .overlay(alignment: .top) {
            if selected, canDrag(event), rect.height >= 12 { resizeHandle(event, edge: .start, timeline: timeline) }
        }
        .overlay(alignment: .bottom) {
            if selected, canDrag(event), rect.height >= 12 { resizeHandle(event, edge: .end, timeline: timeline) }
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    private func select(_ event: PlanDisplayEvent) {
        guard ScheduleEventEditing.select(event, in: store, fixedEditing: adjusting) else { return }
        keyboardFocused = true
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        ScheduleEventEditing.handleKey(press, store: store, fixedEditing: adjusting)
    }

    private func resizeHandle(_ event: PlanDisplayEvent, edge: PlanTimeEdge, timeline: ScheduleWeekTimeline) -> some View {
        Color.clear.frame(height: 6).contentShape(Rectangle())
            .overlay { Capsule().fill(theme.controlAccent).frame(width: 15, height: 2) }
            .onHover { hovering in if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("ScheduleWeekCanvas"))
                .updating($gestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    guard canDrag(event), !cancelledDrag, !store.isBusy, let original = ScheduleEventEditing.range(of: event) else { return }
                    if resize == nil { select(event) }
                    let initialY = timeline.y(for: Double(edge == .start ? original.start : original.end))
                    let position = max(0, min(timeline.height - 0.001, initialY + value.translation.height))
                    guard let minute = timeline.minute(at: position, snapping: 1) else { return }
                    resize = WeekPlanResize(event: event, target: original.resized(edge, to: minute))
                    selection.timePreview = resize?.target
                }
                .onEnded { _ in
                    lastDragEnded = Date()
                    defer { resize = nil; selection.timePreview = nil }
                    guard !cancelledDrag, let current = resize else { return }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85)) {
                        ScheduleEventEditing.apply(current.target, to: current.event, on: current.event.date,
                                                   store: store, fixedEditing: adjusting)
                    }
                })
            .accessibilityElement().accessibilityLabel(edge == .start ? "调整开始边界" : "调整结束边界")
            .accessibilityAdjustableAction { direction in
                ScheduleEventEditing.nudge(event, minutes: direction == .increment ? 1 : -1, edge: edge, store: store, fixedEditing: adjusting)
            }
    }

    private func cardContent(_ event: PlanDisplayEvent, size: CGSize) -> some View {
        let color = eventColor(event)
        let compact = size.height < 24
        let verticalInset: CGFloat = compact ? 0 : 5
        let showsDetails = size.height >= 48
        let titleLines = max(1, min(4, Int((size.height - verticalInset * 2 - (showsDetails ? 16 : 0)) / 16)))
        return VStack(alignment: .leading, spacing: 2) {
            if size.height >= 12 {
                Text(event.title).font(.system(size: compact ? 10 : (size.width < 46 ? 11 : 13), weight: .semibold))
                    .lineLimit(titleLines).strikethrough(event.isCompleted)
            }
            if showsDetails {
                Text(event.location.isEmpty ? event.timeLabel : event.location)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5).padding(.vertical, verticalInset)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .modifier(WeekCardSurface(color: color, isCourse: event.planOccurrence == nil, isDark: theme.isDark))
    }

    @ViewBuilder private func virtualCourses(_ term: TimetableTerm, metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> some View {
        if let week = selection.week(in: store.state), selection.showsCourses {
            ForEach(1...7, id: \.self) { weekday in
                let meetings = term.meetings.filter {
                    $0.isScheduled && $0.weekday == weekday && $0.weeks.contains(week)
                        && (selection.courseID == nil || $0.courseID == selection.courseID)
                }
                ForEach(TimetableLayout.placements(meetings)) { placement in
                    if let vertical = timeline.sectionRect(start: placement.meeting.startSection, count: placement.meeting.sectionCount) {
                        let rect = metrics.eventRect(dayIndex: weekday - 1, lane: placement.lane, laneCount: placement.laneCount,
                                                     top: vertical.minY, height: vertical.height)
                        Button {
                            onMeeting(ScheduleMeetingContext(term: term, meeting: placement.meeting, date: nil, selectedDate: selection.selectedDate))
                        } label: {
                            Text(placement.meeting.title).font(.system(size: rect.width < 46 ? 11 : 13, weight: .semibold))
                                .lineLimit(max(1, min(4, Int((rect.height - 8) / 16))))
                                .padding(4).frame(width: rect.width, height: rect.height, alignment: .topLeading)
                                .modifier(WeekCardSurface(color: eventColorForCourse(placement.meeting.courseID),
                                                          isCourse: true, isDark: theme.isDark))
                        }
                        .buttonStyle(.plain)
                        .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
        }
    }

    private func timeRect(_ event: PlanDisplayEvent, day: Date, timeline: ScheduleWeekTimeline) -> CGRect {
        if case .course(let course) = event.source, event.endDate == nil,
           let rect = timeline.sectionRect(start: course.meeting.startSection, count: course.meeting.sectionCount) { return rect }
        let midnight = calendar.startOfDay(for: day)
        let start = max(0, event.date.timeIntervalSince(midnight) / 60)
        let end = min(1440, (event.endDate ?? event.date.addingTimeInterval(30 * 60)).timeIntervalSince(midnight) / 60)
        return timeline.intervalRect(start: start, end: max(start + 1, end), minimumHeight: 13)
    }

    private func eventDrag(_ event: PlanDisplayEvent, sourceRect: CGRect,
                           metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("ScheduleWeekCanvas"))
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard canDrag(event), !cancelledDrag, !store.isBusy else { return }
                if drag?.event.id != event.id || drag?.isReturning == true {
                    drag = WeekPlanDrag(event: event, sourceRect: sourceRect,
                                        grabOffsetY: value.startLocation.y - sourceRect.minY,
                                        translation: .zero, target: nil)
                }
                guard var updated = drag else { return }
                updated.translation = value.translation
                updated.target = dropTarget(event, point: value.location, grabOffset: updated.grabOffsetY,
                                            metrics: metrics, timeline: timeline)
                selection.timePreview = selection.selectedEventID == event.id ? updated.target?.range : nil
                drag = updated
            }
            .onEnded { value in
                lastDragEnded = Date()
                guard !cancelledDrag else { cancelledDrag = false; cancelDrag(); return }
                guard var completed = drag, completed.event.id == event.id else { return }
                completed.target = dropTarget(event, point: value.location, grabOffset: completed.grabOffsetY,
                                               metrics: metrics, timeline: timeline)
                finishDrag(completed)
            }
    }

    private func dropTarget(_ event: PlanDisplayEvent, point: CGPoint, grabOffset: CGFloat,
                            metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> WeekPlanDrop? {
        guard !isUndated, days.count == 7, point.x.isFinite, point.y.isFinite,
              metrics.columnWidth > 0, point.x >= metrics.labelWidth,
              point.x < metrics.labelWidth + 7 * metrics.columnWidth,
              point.y >= 0, point.y < timeline.height else { return nil }
        let index = Int((point.x - metrics.labelWidth) / metrics.columnWidth)
        let day = days[index]
        guard let range = ScheduleEventEditing.range(of: event) else { return nil }
        let y = max(0, min(timeline.height - 0.001, point.y - grabOffset))
        guard let minute = timeline.minute(at: y, snapping: 1) else { return nil }
        return WeekPlanDrop(date: day, dayIndex: index, range: range.moved(to: minute))
    }

    private func finishDrag(_ completed: WeekPlanDrag) {
        defer { selection.timePreview = nil }
        guard canDrag(completed.event), let target = completed.target else { cancelDrag(); return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) {
            if ScheduleEventEditing.apply(target.range, to: completed.event, on: target.date, store: store, fixedEditing: adjusting) { drag = nil }
        }
        if drag != nil { cancelDrag() }
    }

    @ViewBuilder private func targetPreview(_ metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> some View {
        if let current = drag, let target = current.target {
            let rect = targetRect(current.event, target: target, metrics: metrics, timeline: timeline)
            let shape = RoundedRectangle(cornerRadius: current.event.planOccurrence == nil ? 0 : 5)
            shape.fill(theme.ink.opacity(0.10))
                .overlay { shape.strokeBorder(theme.ink, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
                .overlay(alignment: .topLeading) {
                    Text("\(TimetableLayout.clock(target.range.start))–\(TimetableLayout.clock(target.range.end))")
                        .font(.system(size: 9, weight: .semibold)).padding(3)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: target)
        }
    }

    private func targetRect(_ event: PlanDisplayEvent, target: WeekPlanDrop,
                            metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> CGRect {
        let column = metrics.eventRect(dayIndex: target.dayIndex, top: 0, height: 0)
        let x = column.minX, width = column.width
        let rect = timeline.intervalRect(start: Double(target.range.start), end: Double(target.range.end), minimumHeight: 13)
        return CGRect(x: x, y: rect.minY, width: width, height: rect.height)
    }

    @ViewBuilder private var dragPreview: some View {
        if let drag {
            cardContent(drag.event, size: drag.sourceRect.size)
                .frame(width: drag.sourceRect.width, height: drag.sourceRect.height)
                .scaleEffect(reduceMotion ? 1 : 1.025)
                .shadow(color: .black.opacity(reduceMotion ? 0 : 0.20), radius: 12, y: 5)
                .offset(x: drag.sourceRect.minX + drag.translation.width,
                        y: drag.sourceRect.minY + drag.translation.height - (reduceMotion ? 0 : 3))
                .allowsHitTesting(false).accessibilityHidden(true).zIndex(10)
        }
    }

    private func cancelDrag() {
        resize = nil
        selection.timePreview = nil
        guard let current = drag, !current.isReturning else { return }
        lastDragEnded = Date()
        guard !reduceMotion else { drag = nil; return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            drag?.translation = .zero; drag?.target = nil; drag?.isReturning = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard drag?.sessionID == current.sessionID, drag?.isReturning == true else { return }
            withAnimation(.easeOut(duration: 0.08)) { drag = nil }
        }
    }

    private func creationGesture(_ metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("ScheduleWeekCanvas"))
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !isUndated, !cancelledDrag, drag == nil, !store.isBusy,
                      let start = creationPoint(value.startLocation, metrics: metrics, timeline: timeline),
                      let end = creationPoint(value.location, metrics: metrics, timeline: timeline),
                      start.index == end.index else { creation = nil; return }
                creation = WeekCreation(dayIndex: start.index, startMinute: min(start.minute, end.minute),
                                        endMinute: max(start.minute + 10, end.minute + 10))
            }
            .onEnded { value in
                lastDragEnded = Date()
                defer { creation = nil; cancelledDrag = false }
                guard !cancelledDrag, let creation,
                      let end = creationPoint(value.location, metrics: metrics, timeline: timeline),
                      end.index == creation.dayIndex, days.indices.contains(creation.dayIndex),
                      let start = calendar.date(byAdding: .minute, value: creation.startMinute, to: days[creation.dayIndex]),
                      let finish = calendar.date(byAdding: .minute, value: min(1440, creation.endMinute), to: days[creation.dayIndex]) else { return }
                selection.setDate(start); onCreate(start, finish)
            }
    }

    private func creationPoint(_ point: CGPoint, metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> (index: Int, minute: Int)? {
        guard days.count == 7, point.x.isFinite, metrics.columnWidth > 0,
              point.x >= metrics.labelWidth, point.x < metrics.labelWidth + 7 * metrics.columnWidth,
              let minute = timeline.minute(at: point.y, snapping: 10) else { return nil }
        return (Int((point.x - metrics.labelWidth) / metrics.columnWidth), minute)
    }

    @ViewBuilder private func creationPreview(_ metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> some View {
        if let creation {
            let vertical = timeline.intervalRect(start: Double(creation.startMinute), end: Double(creation.endMinute), minimumHeight: 13)
            let rect = metrics.eventRect(dayIndex: creation.dayIndex, top: vertical.minY, height: vertical.height)
            RoundedRectangle(cornerRadius: 5).fill(theme.selection)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(theme.ink, style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                .overlay(alignment: .topLeading) { Text("空").font(.system(size: 11, weight: .medium)).padding(4) }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    private func canDrag(_ event: PlanDisplayEvent) -> Bool { !isUndated && ScheduleEventEditing.canEdit(event, fixedEditing: adjusting) }
    private func dayDate(_ index: Int) -> Date? { days.indices.contains(index) ? days[index] : nil }
    private func bandEvents(on day: Date) -> [PlanDisplayEvent] {
        ScheduleData.planEvents(on: day, in: store.state, selection: selection).filter { $0.isDeadline || $0.isAllDay }
    }
    private func timedEvents(on day: Date) -> [PlanDisplayEvent] {
        ScheduleData.planEvents(on: day, in: store.state, selection: selection).filter { !$0.isDeadline && !$0.isAllDay }
    }
    private func eventColor(_ event: PlanDisplayEvent) -> Color { ScheduleEventColor.event(event, in: store.state, theme: theme) }
    private func eventColorForCourse(_ id: UUID?) -> Color { id.map { store.courseColor($0) } ?? theme.ink }
    private func open(_ event: PlanDisplayEvent) {
        guard drag == nil, Date().timeIntervalSince(lastDragEnded) > 0.15 else { return }
        switch event.source {
        case .plan(let occurrence): onPlan(occurrence)
        case .course(let course):
            guard let term = store.state.timetableTerms.first(where: { $0.id == course.termID }) else { return }
            onMeeting(ScheduleMeetingContext(term: term, meeting: course.meeting, date: course.day,
                selectedDate: selection.selectedDate, originalDate: course.originalDate))
        }
    }
}

private struct WeekCardSurface: ViewModifier {
    let color: Color
    let isCourse: Bool
    let isDark: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: isCourse ? 0 : 5)
        content
            .background {
                // The solid base masks grid lines and selected-day shading.
                shape.fill(Color(nsColor: .textBackgroundColor))
                    .overlay { shape.fill(color.opacity(isDark ? 0.26 : 0.16)) }
            }
            .overlay { shape.strokeBorder(color.opacity(0.22), lineWidth: 0.7) }
            .overlay {
                shape.strokeBorder(color, lineWidth: 2)
                    .mask(alignment: .leading) { Rectangle().frame(width: isCourse ? 2 : 6) }
            }
            .clipShape(shape).contentShape(shape)
    }
}

private struct WeekPlanDrag {
    let sessionID = UUID()
    let event: PlanDisplayEvent
    let sourceRect: CGRect
    let grabOffsetY: CGFloat
    var translation: CGSize
    var target: WeekPlanDrop?
    var isReturning = false
}

private struct WeekPlanDrop: Equatable {
    let date: Date
    let dayIndex: Int
    let range: PlanTimeRange
}

private struct WeekCreation {
    let dayIndex: Int
    let startMinute: Int
    let endMinute: Int
}

private struct WeekPlanResize {
    let event: PlanDisplayEvent
    let target: PlanTimeRange
}
