import SwiftUI
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
    @ViewState private var creation: WeekCreation?
    @ViewState private var cancelledDrag = false
    @ViewState private var lastDragEnded = Date.distantPast
    @GestureState private var gestureActive = false

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
                                                sectionCount: sections, times: sectionTimes)
            VStack(spacing: 0) {
                TimelineView(.periodic(from: Date(), by: 60)) { context in
                    weekdayHeader(metrics, now: context.date)
                }
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        allDayBand(metrics)
                        timeCanvas(metrics, timeline: timeline)
                    }
                    dragPreview
                }
                .coordinateSpace(name: "ScheduleWeekCanvas")
            }
            .padding(.horizontal, metrics.horizontalInset)
            .padding(.vertical, metrics.verticalInset)
        }
        .clipped()
        .onExitCommand {
            cancelledDrag = true; creation = nil; cancelDrag()
        }
        .onDisappear { drag = nil; creation = nil }
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
                Button {
                    if let date { selection.setDate(date) }
                } label: {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Text(weekdays[index]).font(.system(size: 13, weight: .semibold))
                            if isToday {
                                Circle().fill(Color.white).frame(width: 4, height: 4)
                            }
                        }
                        if let date {
                            Text(TimetableLayout.dateLabel(date)).font(.system(size: 11))
                                .foregroundStyle(isToday ? Color.white.opacity(0.9) : Color.secondary)
                        }
                    }
                    .frame(width: metrics.columnWidth, height: metrics.headerHeight)
                    .foregroundStyle(isToday ? Color.white : Color.primary)
                    .contentShape(Rectangle())
                    .background(isToday ? theme.controlAccent : (selected ? theme.selection : .clear))
                    .overlay(alignment: .bottom) {
                        if selected && !isToday { Rectangle().fill(theme.ink).frame(height: 2) }
                    }
                }
                .buttonStyle(.plain).disabled(date == nil)
                .accessibilityLabel(date.map { TimetableCalendar.formatted($0, template: "MMM d EEEE") } ?? weekdays[index])
                .accessibilityValue([isToday ? "今天" : nil, selected ? "已选择" : nil].compactMap { $0 }.joined(separator: "，"))
            }
        }
    }

    private func allDayBand(_ metrics: ScheduleWeekMetrics) -> some View {
        HStack(spacing: 0) {
            Text("全天\n截止").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: metrics.labelWidth, height: metrics.allDayHeight)
            ForEach(0..<7, id: \.self) { index in
                let events = dayDate(index).map { bandEvents(on: $0) } ?? []
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(events.prefix(2).enumerated()), id: \.element.id) { row, event in
                        bandCard(event, index: index, row: row, metrics: metrics)
                    }
                    if events.count > 2 {
                        Menu {
                            ForEach(events.dropFirst(2)) { event in
                                Button("\(event.isDeadline ? "DDL · " : "")\(event.title)") { open(event) }
                            }
                        } label: { Text("另 \(events.count - 2) 项").font(.system(size: 9)).foregroundStyle(theme.ink) }
                        .menuStyle(.borderlessButton).controlSize(.mini).fixedSize().frame(height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .frame(width: metrics.columnWidth, height: metrics.allDayHeight, alignment: .topLeading)
                .background(Color.primary.opacity(0.018))
                .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.065)).frame(width: 1) }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    private func bandCard(_ event: PlanDisplayEvent, index: Int, row: Int, metrics: ScheduleWeekMetrics) -> some View {
        let rect = metrics.eventRect(dayIndex: index, top: CGFloat(row) * 14 + 2, height: 13)
        let card = Button { open(event) } label: {
            HStack(spacing: 2) {
                if event.isDeadline { Text("DDL").font(.system(size: 7, weight: .bold)) }
                Text(event.title).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(event.isDeadline ? Color.orange : eventColor(event))
            .padding(.horizontal, 3).frame(height: 13)
            .background(eventColor(event).opacity(0.09), in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain).frame(width: rect.width, height: rect.height)
        .opacity(drag?.event.id == event.id ? 0.2 : 1)
        .help("\(event.isDeadline ? "截止 · " : "")\(event.title) · \(event.timeLabel)")
        .accessibilityLabel("\(event.isDeadline ? "截止 " : "全天 ")\(event.title)，\(event.timeLabel)")
        return Group {
            if canDrag(event) {
                card.highPriorityGesture(eventDrag(event, sourceRect: rect, metrics: metrics,
                    timeline: ScheduleWeekTimeline(height: metrics.rowHeight * CGFloat(sections), sectionCount: sections, times: sectionTimes)))
            } else { card }
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
                    Rectangle().fill(theme.ink.opacity(0.025))
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
                Text("第 \(time.section) 节").font(.system(size: 12, weight: .medium))
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
                    .padding(.bottom, 2)
                    .frame(width: metrics.sectionColumnWidth, height: max(1, timeline.height - nightTop), alignment: .bottom)
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
        let vertical = timeRect(event, day: day, timeline: timeline)
        let rect = metrics.eventRect(dayIndex: index, lane: lane.lane, laneCount: lane.laneCount,
                                     top: vertical.minY + metrics.allDayHeight, height: vertical.height)
        let card = Button {
            guard drag == nil, Date().timeIntervalSince(lastDragEnded) > 0.15 else { return }
            open(event)
        } label: { cardContent(event, size: rect.size) }
        .buttonStyle(.plain).frame(width: rect.width, height: rect.height)
        .opacity(drag?.event.id == event.id ? 0.16 : 1)
        .help("\(event.title) · \(event.timeLabel)\(event.location.isEmpty ? "" : " · \(event.location)")\(canDrag(event) ? " · 拖动调整本次安排" : " · 开启编辑固定计划后可拖动")")
        .accessibilityLabel("\(event.title)，\(event.timeLabel)，\(event.location)")
        .contextMenu { Button("查看与编辑…") { open(event) } }
        return Group {
            if canDrag(event) { card.highPriorityGesture(eventDrag(event, sourceRect: rect, metrics: metrics, timeline: timeline)) }
            else { card }
        }
        .offset(x: rect.minX, y: rect.minY - metrics.allDayHeight)
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
        if case .course(let course) = event.source,
           let rect = timeline.sectionRect(start: course.meeting.startSection, count: course.meeting.sectionCount) {
            return rect
        }
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
              point.y >= 0, point.y < metrics.allDayHeight + timeline.height else { return nil }
        let index = Int((point.x - metrics.labelWidth) / metrics.columnWidth)
        let day = days[index]
        if event.isDeadline || event.isAllDay {
            let time = calendar.dateComponents([.hour, .minute, .second], from: event.date)
            let date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day) ?? day
            return WeekPlanDrop(date: date, dayIndex: index, startSection: nil)
        }
        let y = point.y - metrics.allDayHeight - grabOffset
        guard point.y >= metrics.allDayHeight else { return nil }
        if case .course(let course) = event.source {
            guard let term = store.state.timetableTerms.first(where: { $0.id == course.termID }), term.week(containing: day) != nil,
                  let section = timeline.section(at: max(0, min(timeline.height - 0.001, y)), duration: course.meeting.sectionCount) else { return nil }
            return WeekPlanDrop(date: day, dayIndex: index, startSection: section)
        }
        guard let minute = timeline.minute(at: max(0, min(timeline.height - 0.001, y))),
              let date = calendar.date(byAdding: .minute, value: minute, to: day) else { return nil }
        return WeekPlanDrop(date: date, dayIndex: index, startSection: nil)
    }

    private func finishDrag(_ completed: WeekPlanDrag) {
        guard canDrag(completed.event), let target = completed.target else { cancelDrag(); return }
        let event = completed.event
        var saved = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) {
            switch event.source {
            case .course(let course):
                guard let section = target.startSection else { break }
                if calendar.isDate(course.day, inSameDayAs: target.date), course.meeting.startSection == section { break }
                saved = store.changeTimetable(termID: course.termID, label: "移动《\(event.title)》本次安排") { repository in
                    try repository.rescheduleTimetableClass(termID: course.termID, meetingID: course.meeting.id,
                        originalDate: course.originalDate, to: target.date, startSection: section,
                        sectionCount: course.meeting.sectionCount, classroom: course.meeting.classroom)
                }
            case .plan(let occurrence):
                // Clipped multi-day cards retain the effective start clock when
                // moved to another day, rather than truncating their duration.
                var destination = target.date
                if !occurrence.isDeadline, occurrence.task.startsAt < occurrence.date {
                    let delta = occurrence.date.timeIntervalSince(occurrence.task.startsAt)
                    destination = destination.addingTimeInterval(-delta)
                }
                saved = store.changePlan(id: occurrence.task.id, label: event.isDeadline ? "移动截止时间" : "移动《\(event.title)》本次安排") { repository in
                    try repository.movePlanOccurrence(id: occurrence.task.id, originalDate: occurrence.originalDate,
                        isDeadline: occurrence.isDeadline, to: destination)
                }
            }
            if saved { drag = nil; selection.setDate(target.date) }
        }
        if !saved { cancelDrag() }
    }

    @ViewBuilder private func targetPreview(_ metrics: ScheduleWeekMetrics, timeline: ScheduleWeekTimeline) -> some View {
        if let current = drag, let target = current.target {
            let rect = targetRect(current.event, target: target, metrics: metrics, timeline: timeline)
            let shape = RoundedRectangle(cornerRadius: current.event.planOccurrence == nil ? 0 : 5)
            shape.fill(theme.ink.opacity(0.10))
                .overlay { shape.strokeBorder(theme.ink, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
                .overlay(alignment: .topLeading) {
                    Text(target.startSection.map { "第 \($0) 节" } ?? (current.event.isDeadline ? "截止" : TimetableCalendar.formatted(target.date, template: "HHmm")))
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
        if event.isDeadline || event.isAllDay {
            // This overlay lives inside the time canvas; the actual header is
            // immediately above it, in the same unclipped outer coordinate space.
            return CGRect(x: x, y: -metrics.allDayHeight + 2, width: width, height: metrics.allDayHeight - 4)
        }
        if case .course(let course) = event.source, let section = target.startSection,
           let rect = timeline.sectionRect(start: section, count: course.meeting.sectionCount) {
            return CGRect(x: x, y: rect.minY, width: width, height: rect.height)
        }
        let day = calendar.startOfDay(for: target.date), minute = target.date.timeIntervalSince(day) / 60
        let duration = max(15, (event.endDate ?? event.date.addingTimeInterval(1800)).timeIntervalSince(event.date) / 60)
        let rect = timeline.intervalRect(start: minute, end: min(1440, minute + duration), minimumHeight: 13)
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
                                        endMinute: max(start.minute + 15, end.minute + 15))
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
              let minute = timeline.minute(at: point.y - metrics.allDayHeight) else { return nil }
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

    private func canDrag(_ event: PlanDisplayEvent) -> Bool { !isUndated && (!event.isFixed || adjusting) }
    private func dayDate(_ index: Int) -> Date? { days.indices.contains(index) ? days[index] : nil }
    private func bandEvents(on day: Date) -> [PlanDisplayEvent] {
        ScheduleData.planEvents(on: day, in: store.state, selection: selection).filter { $0.isDeadline || $0.isAllDay }
    }
    private func timedEvents(on day: Date) -> [PlanDisplayEvent] {
        ScheduleData.planEvents(on: day, in: store.state, selection: selection).filter { !$0.isDeadline && !$0.isAllDay }
    }
    private func eventColor(_ event: PlanDisplayEvent) -> Color { eventColorForCourse(event.courseID) }
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
    let startSection: Int?
}

private struct WeekCreation {
    let dayIndex: Int
    let startMinute: Int
    let endMinute: Int
}
