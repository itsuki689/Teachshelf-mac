import SwiftUI
import TeachshelfCore

/// The weekly surface shares the date, semester and filters with the month and agenda views.
struct ScheduleWeekView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var selection: ScheduleSelection
    @Binding var adjusting: Bool
    let onMeeting: (ScheduleMeetingContext) -> Void
    @ViewState private var drag: WeekCourseDrag?
    @ViewState private var cancelledDrag = false
    @ViewState private var lastDragEnded = Date.distantPast
    @GestureState private var gestureActive = false

    private let calendar = TimetableCalendar.calendar
    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private var term: TimetableTerm? { selection.term(in: store.state) }
    private var days: [Date] { ScheduleData.weekDays(in: store.state, selection: selection) }
    private var isUndated: Bool { term != nil && term?.weekOneMonday == nil }
    private var sections: Int { TimetableLayout.sectionCount(in: term) }
    private var canAdjust: Bool { adjusting && !isUndated && term != nil && selection.showsCourses }
    private var datedPlacements: [ScheduleOccurrencePlacement] {
        days.enumerated().flatMap { index, date in
            ScheduleDragLayout.placements(ScheduleData.classes(on: date, in: store.state, selection: selection), dayIndex: index)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = ScheduleWeekMetrics(viewport: geometry.size, sectionCount: sections)
            VStack(spacing: 0) {
                weekdayHeader(labelWidth: metrics.labelWidth, columnWidth: metrics.columnWidth,
                              height: metrics.headerHeight)
                periodGrid(labelWidth: metrics.labelWidth, columnWidth: metrics.columnWidth,
                           rowHeight: metrics.rowHeight)
            }
            .padding(.horizontal, metrics.horizontalInset)
            .padding(.vertical, metrics.verticalInset)
        }
        .clipped()
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

    private func weekdayHeader(labelWidth: CGFloat, columnWidth: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("节次").font(.caption).foregroundStyle(.secondary)
                .frame(width: labelWidth, height: height)
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
                    .frame(width: columnWidth, height: height)
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

    private func periodGrid(labelWidth: CGFloat, columnWidth: CGFloat, rowHeight: CGFloat) -> some View {
        let grid = ScheduleDragGrid(labelWidth: labelWidth, columnWidth: columnWidth, rowHeight: rowHeight,
                                    sectionCount: sections, days: days)
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
                            let size = CGSize(width: max(1, width - 6),
                                              height: max(1, CGFloat(placement.meeting.sectionCount) * rowHeight - 6))
                            meetingCard(placement.meeting, term: term, day: nil, size: size)
                                .frame(width: size.width, height: size.height)
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
                meetingCardContent(drag.event.meeting, size: drag.sourceRect.size)
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
    }

    private func datedMeetingCard(_ placement: ScheduleOccurrencePlacement, term: TimetableTerm, grid: ScheduleDragGrid) -> some View {
        let event = placement.event
        let laneWidth = grid.columnWidth / CGFloat(placement.laneCount)
        let rect = CGRect(x: grid.labelWidth + CGFloat(placement.dayIndex) * grid.columnWidth + CGFloat(placement.lane) * laneWidth + 3,
                          y: CGFloat(event.meeting.startSection - 1) * grid.rowHeight + 3,
                          width: max(1, laneWidth - 6), height: max(1, CGFloat(event.meeting.sectionCount) * grid.rowHeight - 6))
        let context = ScheduleMeetingContext(term: term, meeting: event.meeting, date: event.day,
                                             selectedDate: selection.selectedDate, originalDate: event.originalDate)
        let card = Button {
            guard drag == nil, Date().timeIntervalSince(lastDragEnded) > 0.15 else { return }
            onMeeting(context)
        } label: { meetingCardContent(event.meeting, size: rect.size) }
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
            Text("第 \(section) 节").font(.system(size: rowHeight < 28 ? 9 : 11, weight: .medium))
                .lineLimit(1)
            if rowHeight >= 28, let time = term?.sectionTimes.first(where: { $0.section == section }) {
                Text("\(TimetableLayout.clock(time.startMinute))–\(TimetableLayout.clock(time.endMinute))")
                    .font(.system(size: 9)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(.secondary).frame(width: labelWidth, height: rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(section) 节")
        .accessibilityValue(term?.sectionTimes.first(where: { $0.section == section }).map {
            "\(TimetableLayout.clock($0.startMinute))–\(TimetableLayout.clock($0.endMinute))"
        } ?? "未设置作息时间")
    }

    private func meetingCard(_ meeting: TimetableMeeting, term: TimetableTerm, day: Date?, size: CGSize) -> some View {
        Button {
            onMeeting(ScheduleMeetingContext(term: term, meeting: meeting, date: day, selectedDate: selection.selectedDate))
        } label: { meetingCardContent(meeting, size: size) }
            .buttonStyle(.plain)
            .help("\(meeting.title) · \(meeting.classroom) · \(TimetableLayout.weeksLabel(meeting.weeks))")
            .accessibilityLabel("\(meeting.title)，第 \(meeting.startSection) 至 \(meeting.endSection) 节，\(meeting.classroom)")
    }

    private func meetingCardContent(_ meeting: TimetableMeeting, size: CGSize) -> some View {
        let color = meeting.courseID.map { store.courseColor($0) } ?? theme.ink
        let padding: CGFloat = size.height < 22 ? 1 : (size.height < 45 ? 4 : (size.width < 65 ? 5 : 7))
        let titleSize = min(size.width < 50 ? 10.0 : (size.width < 80 ? 11.0 : 12.0),
                            max(6, (size.height - 2 * padding) / 1.2))
        let titleLines = size.height >= 58 ? 2 : 1
        return VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.system(size: titleSize, weight: .semibold))
                .lineLimit(titleLines)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !meeting.classroom.isEmpty, size.height >= 40 {
                Text(meeting.classroom).font(.system(size: size.width < 65 ? 9 : 10))
                    .lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(theme.isDark ? 0.18 : 0.11), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 2.5).padding(.vertical, 6)
        }
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.25), lineWidth: 0.7) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
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
