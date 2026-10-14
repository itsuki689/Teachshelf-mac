import SwiftUI
import TeachshelfCore

/// The weekly surface shares the date, semester and filters with the month and agenda views.
struct ScheduleWeekView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var selection: ScheduleSelection
    let onMeeting: (ScheduleMeetingContext) -> Void
    let onTask: (StudyTask) -> Void
    let onSettings: (TimetableTerm) -> Void
    @ViewState private var adjusting = true
    @ViewState private var drag: WeekCourseDrag?
    @ViewState private var cancelledDrag = false
    @ViewState private var lastDragEnded = Date.distantPast
    @ViewState private var gridOrigin = CGPoint.zero
    @GestureState private var gestureActive = false

    private let calendar = TimetableCalendar.calendar
    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private var term: TimetableTerm? { selection.term(in: store.state) }
    private var days: [Date] { ScheduleData.weekDays(in: store.state, selection: selection) }
    private var isUndated: Bool { term != nil && term?.weekOneMonday == nil }
    private var weekTasks: [StudyTask] {
        days.flatMap { ScheduleData.tasks(on: $0, in: store.state, selection: selection) }
    }
    private var freeMeetings: [TimetableMeeting] {
        ScheduleData.freeMeetings(in: store.state, selection: selection)
    }
    private var sections: Int { TimetableLayout.sectionCount(in: term) }
    private var canAdjust: Bool { adjusting && !isUndated && term != nil && selection.showsCourses }
    private var datedPlacements: [ScheduleOccurrencePlacement] {
        days.enumerated().flatMap { index, date in
            ScheduleDragLayout.placements(ScheduleData.classes(on: date, in: store.state, selection: selection), dayIndex: index)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            adjustmentBar
            if isUndated, let term {
                undatedNotice(term)
            } else if selection.showsTasks {
                taskStrip
            }
            if term == nil && selection.showsCourses {
                inlineNotice("尚未导入课表，可从右上角导入本科课表。", symbol: "rectangle.split.3x3")
            } else if selection.showsCourses, !isUndated, selection.week(in: store.state) == nil {
                inlineNotice("这一周在所选学期之外，仍可查看和安排待办。", symbol: "calendar")
            }
            GeometryReader { geometry in
                let labelWidth: CGFloat = 82
                let columnWidth = max(90, (geometry.size.width - 32 - labelWidth) / 7)
                let rowHeight: CGFloat = 65
                let contentWidth = labelWidth + 7 * columnWidth
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            periodGrid(labelWidth: labelWidth, columnWidth: columnWidth, rowHeight: rowHeight,
                                       viewportSize: geometry.size)
                            if let term, !freeMeetings.isEmpty {
                                freeTimeSection(term).frame(width: contentWidth)
                            }
                        } header: {
                            weekdayHeader(labelWidth: labelWidth, columnWidth: columnWidth)
                                .background(Color(nsColor: .textBackgroundColor))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .coordinateSpace(name: "ScheduleWeekViewport")
                .onPreferenceChange(ScheduleGridOriginKey.self) { gridOrigin = $0 }
            }
        }
        .onExitCommand {
            if drag != nil { cancelledDrag = true }
            cancelDrag()
        }
        .onDisappear { drag = nil }
        .onChange(of: adjusting) { _, _ in cancelDrag() }
        .onChange(of: selection.selectedDate) { _, _ in cancelDrag() }
        .onChange(of: selection.termID) { _, _ in cancelDrag() }
        .onChange(of: selection.courseID) { _, _ in cancelDrag() }
        .onChange(of: selection.showsCourses) { _, _ in cancelDrag() }
        .onChange(of: scenePhase) { _, value in if value != .active { cancelDrag() } }
        .onChange(of: gestureActive) { _, active in
            guard !active else { return }
            // GestureState also resets when macOS cancels a drag before onEnded.
            Task { @MainActor in
                await Task.yield()
                if !gestureActive { cancelDrag(); cancelledDrag = false }
            }
        }
    }

    private var adjustmentBar: some View {
        HStack(spacing: 10) {
            Toggle("调整课表", isOn: $adjusting).toggleStyle(.switch).controlSize(.small)
                .fixedSize().disabled(isUndated || term == nil || !selection.showsCourses)
                .help("开启后拖动课程卡片，仅调整这一次课；按 Esc 取消拖动")
            Text(isUndated ? "设置开学日期后可拖动" : (adjusting ? "拖动仅调整本次课 · 跨周请在课程详情中调整" : "点击课程查看详情"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 8)
            if store.canUndoTimetableChange {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) {
                        store.undoTimetableChange()
                    }
                } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).font(.caption)
                    .help(store.timetableUndoLabel.map { "撤销\($0)" } ?? "撤销上次课表调整")
                    .accessibilityLabel(store.timetableUndoLabel.map { "撤销\($0)" } ?? "撤销上次课表调整")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func undatedNotice(_ term: TimetableTerm) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
            Text("设置开学日期后关联本周待办；目前课程按周次显示。")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("设置开学日期") { onSettings(term) }
                .buttonStyle(.plain).foregroundStyle(theme.ink)
                .accessibilityLabel("设置 \(term.name) 的开学日期")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 11)
        .background(theme.ink.opacity(0.045))
    }

    private func inlineNotice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var taskStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label("本周待办", systemImage: "checklist").font(.caption.weight(.semibold))
                Text("\(weekTasks.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if weekTasks.isEmpty {
                    Text("这一周没有待办").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !weekTasks.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(weekTasks) { task in weeklyTaskCard(task) }
                    }.padding(.bottom, 2)
                }.scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.primary.opacity(theme.isDark ? 0.025 : 0.015))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func weeklyTaskCard(_ task: StudyTask) -> some View {
        let date = task.deadline ?? task.startsAt
        let color = task.courseID.map { store.courseColor($0) } ?? theme.ink
        return HStack(spacing: 9) {
            Button { store.setTaskCompleted(task) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(task.isCompleted ? theme.ink : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(task.isCompleted ? "标为未完成" : "完成待办")
            .accessibilityLabel("\(task.isCompleted ? "重新打开" : "完成")待办：\(task.title)")
            Button {
                selection.setDate(date)
                onTask(task)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.system(size: 12, weight: .medium))
                        .strikethrough(task.isCompleted).lineLimit(1)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    HStack(spacing: 5) {
                        Text(TimetableCalendar.formatted(date, template: "EEE M d"))
                        Text(task.isCompleted ? "已完成" : (task.deadline == nil ? "开始" : "截止"))
                        if !task.isAllDay {
                            Text(TimetableCalendar.formatted(date, template: "HHmm"))
                        }
                    }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("编辑待办：\(task.title)")
            .accessibilityLabel("编辑待办：\(task.title)，\(TimetableCalendar.formatted(date, template: "MMM d EEEE"))，\(task.isCompleted ? "已完成" : "未完成")")
        }
        .padding(10).frame(width: 230)
        .background(color.opacity(theme.isDark ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.16), lineWidth: 0.7) }
    }

    private func weekdayHeader(labelWidth: CGFloat, columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("节次").font(.caption).foregroundStyle(.secondary)
                .frame(width: labelWidth, height: 57)
            ForEach(1...7, id: \.self) { weekday in
                let date = dayDate(weekday)
                let selected = date.map { calendar.isDate($0, inSameDayAs: selection.selectedDate) } ?? false
                let today = date.map { calendar.isDateInToday($0) } ?? false
                Button {
                    if let date { selection.setDate(date) }
                } label: {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Text(weekdays[weekday - 1]).font(.system(size: 12, weight: .semibold))
                            if today {
                                Circle().fill(theme.ink).frame(width: 4, height: 4).accessibilityHidden(true)
                            }
                        }
                        if let date {
                            Text(TimetableLayout.dateLabel(date)).font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: columnWidth, height: 57)
                    .contentShape(Rectangle())
                    .background(selected ? theme.selection : .clear)
                    .overlay(alignment: .bottom) {
                        if selected { Rectangle().fill(theme.ink).frame(height: 2) }
                    }
                }
                .buttonStyle(.plain).disabled(date == nil)
                .help(date.map { "选择 \(TimetableCalendar.formatted($0, template: "MMM d EEEE"))" } ?? "设置开学日期后可选择日期")
                .accessibilityLabel(date.map { TimetableCalendar.formatted($0, template: "MMM d EEEE") } ?? weekdays[weekday - 1])
                .accessibilityValue(selected ? "已选择" : (today ? "今天" : ""))
            }
        }
    }

    private func periodGrid(labelWidth: CGFloat, columnWidth: CGFloat, rowHeight: CGFloat, viewportSize: CGSize) -> some View {
        let visibleRect = CGRect(x: -gridOrigin.x, y: 57 - gridOrigin.y,
                                 width: viewportSize.width, height: max(0, viewportSize.height - 57))
        let grid = ScheduleDragGrid(labelWidth: labelWidth, columnWidth: columnWidth, rowHeight: rowHeight,
                                    sectionCount: sections, days: days, visibleRect: visibleRect)
        return ZStack(alignment: .topLeading) {
            ForEach(1...7, id: \.self) { weekday in
                if let date = dayDate(weekday), calendar.isDate(date, inSameDayAs: selection.selectedDate) {
                    Rectangle().fill(theme.ink.opacity(0.025))
                        .frame(width: columnWidth, height: CGFloat(sections) * rowHeight)
                        .offset(x: labelWidth + CGFloat(weekday - 1) * columnWidth)
                        .accessibilityHidden(true)
                }
            }
            gridLines(labelWidth: labelWidth, columnWidth: columnWidth, rowHeight: rowHeight)
            ForEach(1...sections, id: \.self) { section in
                sectionLabel(section, labelWidth: labelWidth, rowHeight: rowHeight)
                    .offset(y: CGFloat(section - 1) * rowHeight)
            }
            if let target = drag?.target {
                let rect = grid.rect(for: target)
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.ink.opacity(0.10))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.ink, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])) }
                    .overlay(alignment: .topLeading) {
                        Text("第 \(target.startSection)–\(target.startSection + target.sectionCount - 1) 节")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.ink)
                            .padding(7)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: target)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            if let term {
                if days.isEmpty {
                    ForEach(1...7, id: \.self) { weekday in
                        let placements = TimetableLayout.placements(meetings(on: weekday))
                        ForEach(placements) { placement in
                            let width = columnWidth / CGFloat(placement.laneCount)
                            meetingCard(placement.meeting, term: term, day: nil, compact: true)
                                .frame(width: max(1, width - 6), height: CGFloat(placement.meeting.sectionCount) * rowHeight - 6)
                                .offset(x: labelWidth + CGFloat(weekday - 1) * columnWidth + CGFloat(placement.lane) * width + 3,
                                        y: CGFloat(placement.meeting.startSection - 1) * rowHeight + 3)
                        }
                    }
                } else {
                    ForEach(datedPlacements) { placement in
                        datedMeetingCard(placement, term: term, grid: grid)
                    }
                }
            }
            if let drag {
                meetingCardContent(drag.event.meeting, compact: true)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .frame(width: drag.sourceRect.width, height: drag.sourceRect.height)
                    .scaleEffect(reduceMotion ? 1 : 1.025)
                    .shadow(color: .black.opacity(reduceMotion ? 0 : 0.20), radius: 12, y: 5)
                    .offset(x: drag.sourceRect.minX + drag.translation.width,
                            y: drag.sourceRect.minY + drag.translation.height - (reduceMotion ? 0 : 3))
                    .allowsHitTesting(false).accessibilityHidden(true)
                    .zIndex(10)
            }
        }
        .frame(width: grid.width, height: grid.height)
        .coordinateSpace(name: "ScheduleWeekGrid")
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ScheduleGridOriginKey.self,
                                       value: proxy.frame(in: .named("ScheduleWeekViewport")).origin)
            }
        }
    }

    private func datedMeetingCard(_ placement: ScheduleOccurrencePlacement, term: TimetableTerm, grid: ScheduleDragGrid) -> some View {
        let event = placement.event
        let laneWidth = grid.columnWidth / CGFloat(placement.laneCount)
        let rect = CGRect(x: grid.labelWidth + CGFloat(placement.dayIndex) * grid.columnWidth + CGFloat(placement.lane) * laneWidth + 3,
                          y: CGFloat(event.meeting.startSection - 1) * grid.rowHeight + 3,
                          width: max(1, laneWidth - 6), height: CGFloat(event.meeting.sectionCount) * grid.rowHeight - 6)
        let context = ScheduleMeetingContext(term: term, meeting: event.meeting, date: event.day,
                                             selectedDate: selection.selectedDate, originalDate: event.originalDate)
        let card = Button {
            guard drag == nil, Date().timeIntervalSince(lastDragEnded) > 0.15 else { return }
            onMeeting(context)
        } label: { meetingCardContent(event.meeting, compact: true) }
            .buttonStyle(.plain)
            .frame(width: rect.width, height: rect.height)
            .opacity(drag?.event.id == event.id ? 0.16 : 1)
            .help("\(event.meeting.title) · \(event.meeting.classroom)\(canAdjust ? " · 拖动调整本次课，点击查看详情" : " · 点击查看详情")")
            .accessibilityLabel("\(event.meeting.title)，\(TimetableCalendar.formatted(event.day, template: "MMM d EEEE"))，\(TimetableLayout.sectionLabel(event.meeting))，\(event.meeting.classroom)")
            .accessibilityHint(canAdjust ? "可拖动调整本次课程；或打开课程详情调整安排" : "打开课程详情")
            .contextMenu {
                Button("课程详情与调整…") { onMeeting(context) }
            }
        return Group {
            if canAdjust {
                card.highPriorityGesture(courseDrag(event: event, term: term, sourceRect: rect, grid: grid))
            } else { card }
        }.offset(x: rect.minX, y: rect.minY)
    }

    private func courseDrag(event: TimetableCalendar.DayClass, term: TimetableTerm, sourceRect: CGRect, grid: ScheduleDragGrid) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("ScheduleWeekGrid"))
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard canAdjust, !cancelledDrag, !store.isBusy else { return }
                if drag?.event.id != event.id || drag?.isReturning == true {
                    drag = WeekCourseDrag(event: event, sourceRect: sourceRect,
                                          grabOffsetY: value.startLocation.y - sourceRect.minY,
                                          translation: .zero, target: nil)
                }
                guard var updated = drag else { return }
                updated.translation = value.translation
                updated.target = grid.target(at: value.location, grabOffsetY: updated.grabOffsetY,
                                             duration: event.meeting.sectionCount, term: term)
                drag = updated
            }
            .onEnded { value in
                lastDragEnded = Date()
                guard !cancelledDrag else { cancelledDrag = false; cancelDrag(); return }
                guard var completed = drag, completed.event.id == event.id else { return }
                completed.target = grid.target(at: value.location, grabOffsetY: completed.grabOffsetY,
                                               duration: event.meeting.sectionCount, term: term)
                finishDrag(completed, term: term)
            }
    }

    private func finishDrag(_ completed: WeekCourseDrag, term: TimetableTerm) {
        guard canAdjust, let target = completed.target else { cancelDrag(); return }
        let event = completed.event
        guard !calendar.isDate(event.day, inSameDayAs: target.date) || event.meeting.startSection != target.startSection else {
            cancelDrag(); return
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) {
            let saved = store.changeTimetable(termID: term.id, label: "移动《\(event.meeting.title)》本次课") { repository in
                try repository.rescheduleTimetableClass(termID: term.id, meetingID: event.meeting.id,
                                                        originalDate: event.originalDate, to: target.date,
                                                        startSection: target.startSection,
                                                        sectionCount: event.meeting.sectionCount,
                                                        classroom: event.meeting.classroom)
            }
            drag = nil
            if saved { selection.setDate(target.date) }
        }
    }

    private func cancelDrag() {
        guard let current = drag, !current.isReturning else { return }
        lastDragEnded = Date()
        guard !reduceMotion else { drag = nil; return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            drag?.translation = .zero
            drag?.target = nil
            drag?.isReturning = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard drag?.sessionID == current.sessionID, drag?.isReturning == true else { return }
            withAnimation(.easeOut(duration: 0.08)) { drag = nil }
        }
    }

    private func gridLines(labelWidth: CGFloat, columnWidth: CGFloat, rowHeight: CGFloat) -> some View {
        Path { path in
            for index in 0...sections {
                let y = CGFloat(index) * rowHeight
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: labelWidth + 7 * columnWidth, y: y))
            }
            for index in 0...7 {
                let x = labelWidth + CGFloat(index) * columnWidth
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: CGFloat(sections) * rowHeight))
            }
        }.stroke(Color.primary.opacity(0.065), lineWidth: 1).accessibilityHidden(true)
    }

    private func sectionLabel(_ section: Int, labelWidth: CGFloat, rowHeight: CGFloat) -> some View {
        VStack(spacing: 3) {
            Text("第 \(section) 节").font(.system(size: 11, weight: .medium))
            if let time = term?.sectionTimes.first(where: { $0.section == section }) {
                Text("\(TimetableLayout.clock(time.startMinute))–\(TimetableLayout.clock(time.endMinute))")
                    .font(.system(size: 9)).monospacedDigit().lineLimit(1)
            }
        }
        .foregroundStyle(.secondary).frame(width: labelWidth, height: rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(section) 节")
        .accessibilityValue(term?.sectionTimes.first(where: { $0.section == section }).map {
            "\(TimetableLayout.clock($0.startMinute))–\(TimetableLayout.clock($0.endMinute))"
        } ?? "未设置作息时间")
    }

    private func meetingCard(_ meeting: TimetableMeeting, term: TimetableTerm, day: Date?, compact: Bool) -> some View {
        Button {
            onMeeting(ScheduleMeetingContext(term: term, meeting: meeting, date: day, selectedDate: selection.selectedDate))
        } label: { meetingCardContent(meeting, compact: compact) }
            .buttonStyle(.plain)
            .help("\(meeting.title) · \(meeting.classroom) · \(TimetableLayout.weeksLabel(meeting.weeks))")
            .accessibilityLabel("\(meeting.title)，\(meeting.isScheduled ? "第 \(meeting.startSection) 至 \(meeting.endSection) 节" : "自由时间")，\(meeting.classroom)")
    }

    private func meetingCardContent(_ meeting: TimetableMeeting, compact: Bool) -> some View {
        let color = meeting.courseID.map { store.courseColor($0) } ?? theme.ink
        return VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                Text(meeting.title).font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .lineLimit(compact ? (meeting.sectionCount == 1 ? 1 : 2) : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(TimetableLayout.sectionLabel(meeting)).font(.system(size: 10)).foregroundStyle(.secondary)
                if !meeting.classroom.isEmpty {
                    Text(meeting.classroom).font(.system(size: compact ? 10 : 12))
                        .lineLimit(1).foregroundStyle(.secondary)
                }
                if !compact, let term, let time = TimetableLayout.timeLabel(meeting, in: term) {
                    Text(time).font(.caption).foregroundStyle(.secondary)
                }
                if compact { Spacer(minLength: 0) }
            }
            .padding(compact ? 8 : 12)
            .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .topLeading)
            .background(color.opacity(theme.isDark ? 0.18 : 0.11), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 7)
            }
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.25), lineWidth: 0.7) }
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    private func freeTimeSection(_ term: TimetableTerm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自由时间 · \(freeMeetings.count) 项").font(.headline).padding(.top, 18)
            Text("这些课程没有固定上课日期，不放入每天的日程。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(freeMeetings) { meeting in
                meetingCard(meeting, term: term, day: nil, compact: false)
            }
        }.padding(.vertical, 8)
    }

    private func dayDate(_ weekday: Int) -> Date? {
        days.indices.contains(weekday - 1) ? days[weekday - 1] : nil
    }

    private func meetings(on weekday: Int) -> [TimetableMeeting] {
        guard selection.showsCourses, let term else { return [] }
        if let date = dayDate(weekday) {
            return ScheduleData.classes(on: date, in: store.state, selection: selection).map(\.meeting)
        }
        // An undated timetable has academic weeks, but no civil date to attach tasks to.
        guard term.weekOneMonday == nil, let week = selection.week(in: store.state) else { return [] }
        return term.meetings.filter {
            $0.isScheduled && $0.weekday == weekday && $0.weeks.contains(week)
                && (selection.courseID == nil || $0.courseID == selection.courseID)
        }
    }
}

private struct WeekCourseDrag {
    let sessionID = UUID()
    let event: TimetableCalendar.DayClass
    let sourceRect: CGRect
    let grabOffsetY: CGFloat
    var translation: CGSize
    var target: ScheduleDropTarget?
    var isReturning = false
}

private struct ScheduleGridOriginKey: PreferenceKey {
    static var defaultValue: CGPoint { .zero }
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}
