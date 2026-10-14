import SwiftUI
import TeachshelfCore

struct TimetableWorkspace: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ViewState private var selectedTermID: UUID?
    @ViewState private var week = 1
    @ViewState private var presentation = "week"
    @ViewState private var showingImport = false
    @ViewState private var editingTerm: TimetableTerm?
    @ViewState private var selectedMeeting: TimetableMeeting?

    private var terms: [TimetableTerm] { store.state.timetableTerms.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending } }
    private var term: TimetableTerm? { terms.first { $0.id == selectedTermID } ?? terms.first }
    private var weekdays: [String] { ["周一", "周二", "周三", "周四", "周五", "周六", "周日"] }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let term {
                controls(term)
                Divider()
                if term.weekOneMonday == nil {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.clock")
                        Text("尚未设置开学日期，当前按周次与节次显示。")
                        Spacer()
                        Button("设置学期") { editingTerm = term }.buttonStyle(.plain).foregroundStyle(theme.ink)
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
                        .background(theme.ink.opacity(0.045))
                }
                if presentation == "week" { weeklyGrid(term) }
                else { agenda(term) }
            } else {
                VStack(spacing: 0) {
                    EmptyStateView(symbol: "rectangle.split.3x3", title: "把这一周的课程放在眼前", detail: "从南京大学本科教务导入课表，保留周次、节次和教室，并关联你的课程资料。")
                    Button("导入本科课表") { showingImport = true }.appPrimaryButton().padding(.bottom, 100)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showingImport) {
            NJUImportSheet { id in
                selectedTermID = id
                if let term = store.state.timetableTerms.first(where: { $0.id == id }) { week = term.week(containing: Date()) ?? 1 }
            }.environmentObject(store)
        }
        .sheet(item: $editingTerm) { TimetableSettingsSheet(term: $0).environmentObject(store) }
        .sheet(item: $selectedMeeting) { meeting in
            if let term { TimetableMeetingSheet(term: term, meeting: meeting).environmentObject(store) }
        }
        .onAppear { selectInitialTerm() }
        .onChange(of: selectedTermID) { _, _ in week = term?.week(containing: Date()) ?? 1 }
        .onChange(of: store.state.timetableTerms) { _, _ in
            if !terms.contains(where: { $0.id == selectedTermID }) { selectedTermID = terms.first?.id }
            week = min(max(1, week), term?.weekCount ?? 1)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("课表").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("一周的节奏，和每门课的资料相连。").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { showingImport = true } label: { Label("导入本科课表", systemImage: "square.and.arrow.down") }.appPrimaryButton()
        }.padding(24)
    }

    private func controls(_ term: TimetableTerm) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { termPicker; weekControls(term); Spacer(minLength: 0); viewControls(term) }
            VStack(spacing: 12) {
                HStack { termPicker; Spacer(minLength: 0); viewControls(term) }
                HStack { weekControls(term); Spacer(minLength: 0) }
            }
        }.padding(.horizontal, 24).padding(.bottom, 18)
    }

    private var termPicker: some View {
        ChoiceMenu("课表学期", selection: Binding(get: { term?.id }, set: { selectedTermID = $0 }), selectedTitle: term?.name ?? "选择学期") {
            ForEach(terms) { Text($0.name).tag(Optional($0.id)) }
        }.frame(width: 235)
    }

    private func weekControls(_ term: TimetableTerm) -> some View {
        HStack(spacing: 8) {
            Button { week -= 1 } label: { Image(systemName: "chevron.left") }.disabled(week <= 1).help("上一周")
            Menu {
                ForEach(1...max(1, term.weekCount), id: \.self) { value in
                    Button { week = value } label: { if value == week { Label("第 \(value) 周", systemImage: "checkmark") } else { Text("第 \(value) 周") } }
                }
            } label: { Text("第 \(week) 周").font(.callout.weight(.semibold)).monospacedDigit().frame(minWidth: 60) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("课表周次")
            Button { week += 1 } label: { Image(systemName: "chevron.right") }.disabled(week >= term.weekCount).help("下一周")
            Button("本周") { if let current = term.week(containing: Date()) { week = current } }.disabled(term.week(containing: Date()) == nil)
        }.buttonStyle(.borderless)
    }

    private func viewControls(_ term: TimetableTerm) -> some View {
        HStack(spacing: 12) {
            Picker("课表显示", selection: $presentation) {
                Image(systemName: "rectangle.split.3x3").tag("week")
                Image(systemName: "list.bullet").tag("list")
            }.labelsHidden().pickerStyle(.segmented).frame(width: 82).help("周课表 / 课程列表")
            Button { editingTerm = term } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).help("学期与作息设置").accessibilityLabel("学期与作息设置")
        }
    }

    private func weeklyGrid(_ term: TimetableTerm) -> some View {
        GeometryReader { geometry in
            let labelWidth: CGFloat = 55
            let columnWidth = max(96, (geometry.size.width - 32 - labelWidth) / 7)
            let rowHeight: CGFloat = 65
            let sections = max(12, max(term.meetings.filter(\.isScheduled).map(\.endSection).max() ?? 0,
                               term.sectionTimes.map(\.section).max() ?? 0))
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("节次").font(.caption).foregroundStyle(.secondary).frame(width: labelWidth, height: 54)
                        ForEach(1...7, id: \.self) { day in
                            VStack(spacing: 4) {
                                Text(weekdays[day - 1]).font(.system(size: 12, weight: .semibold))
                                if let date = term.date(week: week, weekday: day) {
                                    Text(TimetableLayout.dateLabel(date))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }.frame(width: columnWidth, height: 54)
                                .background(isToday(term, weekday: day) ? theme.selection : .clear)
                        }
                    }
                    ZStack(alignment: .topLeading) {
                        Path { path in
                            for index in 0...sections {
                                let y = CGFloat(index) * rowHeight
                                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: labelWidth + 7 * columnWidth, y: y))
                            }
                            for index in 0...7 {
                                let x = labelWidth + CGFloat(index) * columnWidth
                                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: CGFloat(sections) * rowHeight))
                            }
                        }.stroke(Color.primary.opacity(0.065), lineWidth: 1).accessibilityHidden(true)
                        ForEach(1...sections, id: \.self) { section in
                            VStack(spacing: 3) {
                                Text("\(section)").font(.system(size: 12, weight: .medium))
                                if let time = term.sectionTimes.first(where: { $0.section == section }) {
                                    Text(TimetableLayout.clock(time.startMinute)).font(.system(size: 9)).monospacedDigit()
                                    Text(TimetableLayout.clock(time.endMinute)).font(.system(size: 9)).monospacedDigit()
                                }
                            }.foregroundStyle(.secondary).frame(width: labelWidth, height: rowHeight)
                                .offset(y: CGFloat(section - 1) * rowHeight)
                        }
                        ForEach(1...7, id: \.self) { day in
                            let placements = TimetableLayout.placements(activeMeetings(term).filter { $0.weekday == day && $0.isScheduled })
                            ForEach(placements) { placement in
                                let width = columnWidth / CGFloat(placement.laneCount)
                                meetingCard(placement.meeting, term: term, compact: true)
                                    .frame(width: max(1, width - 6), height: CGFloat(placement.meeting.sectionCount) * rowHeight - 6)
                                    .offset(x: labelWidth + CGFloat(day - 1) * columnWidth + CGFloat(placement.lane) * width + 3,
                                            y: CGFloat(placement.meeting.startSection - 1) * rowHeight + 3)
                            }
                        }
                    }.frame(width: labelWidth + 7 * columnWidth, height: CGFloat(sections) * rowHeight)
                    unscheduled(term).frame(width: labelWidth + 7 * columnWidth)
                }.padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
    }

    private func agenda(_ term: TimetableTerm) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(1...7, id: \.self) { day in
                    let meetings = activeMeetings(term).filter { $0.weekday == day && $0.isScheduled }.sorted { $0.startSection < $1.startSection }
                    if !meetings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(weekdays[day - 1]).font(.headline)
                                if let date = term.date(week: week, weekday: day) { Text(TimetableLayout.dateLabel(date)).font(.caption).foregroundStyle(.secondary) }
                            }
                            ForEach(meetings) { meeting in meetingCard(meeting, term: term, compact: false).frame(minHeight: 80) }
                        }
                    }
                }
                if activeMeetings(term).filter(\.isScheduled).isEmpty {
                    Text("第 \(week) 周没有固定时段的课程").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                }
                unscheduled(term)
            }.padding(24)
        }
    }

    private func meetingCard(_ meeting: TimetableMeeting, term: TimetableTerm, compact: Bool) -> some View {
        let color = meeting.courseID.map { store.courseColor($0) } ?? theme.ink
        return Button { selectedMeeting = meeting } label: {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                Text(meeting.title).font(.system(size: compact ? 12 : 14, weight: .semibold)).lineLimit(compact ? (meeting.sectionCount == 1 ? 1 : 2) : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(TimetableLayout.sectionLabel(meeting)).font(.system(size: 10)).foregroundStyle(.secondary)
                if !meeting.classroom.isEmpty { Text(meeting.classroom).font(.system(size: compact ? 10 : 12)).lineLimit(1).foregroundStyle(.secondary) }
                if !compact, let time = TimetableLayout.timeLabel(meeting, in: term) { Text(time).font(.caption).foregroundStyle(.secondary) }
                if compact { Spacer(minLength: 0) }
            }.padding(compact ? 8 : 12).frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .topLeading)
                .background(color.opacity(theme.isDark ? 0.18 : 0.11), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 7) }
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.25), lineWidth: 0.7) }
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
            .help("\(meeting.title) · \(meeting.classroom) · \(TimetableLayout.weeksLabel(meeting.weeks))")
            .accessibilityLabel("\(meeting.title)，\(meeting.isScheduled ? "第\(meeting.startSection)至\(meeting.endSection)节" : "自由时间")，\(meeting.classroom)")
    }

    @ViewBuilder private func unscheduled(_ term: TimetableTerm) -> some View {
        let meetings = activeMeetings(term).filter { !$0.isScheduled }
        if !meetings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("自由时间 · \(meetings.count) 项").font(.headline).padding(.top, 18)
                ForEach(meetings) { meeting in meetingCard(meeting, term: term, compact: false) }
            }.padding(.vertical, 8)
        }
    }

    private func activeMeetings(_ term: TimetableTerm) -> [TimetableMeeting] { term.meetings.filter { $0.weeks.contains(week) || (!$0.isScheduled && $0.weeks.isEmpty) } }
    private func isToday(_ term: TimetableTerm, weekday: Int) -> Bool {
        guard let date = term.date(week: week, weekday: weekday) else { return false }
        return TimetableLayout.academicCalendar.isDateInToday(date)
    }
    private func selectInitialTerm() {
        guard selectedTermID == nil else { return }
        let initial = terms.first(where: { $0.week(containing: Date()) != nil }) ?? terms.first
        selectedTermID = initial?.id; week = initial?.week(containing: Date()) ?? 1
    }
}

private struct TimetableMeetingSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let term: TimetableTerm
    let meeting: TimetableMeeting

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(meeting.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭课程信息")
            }
            Text(term.name).font(.callout).foregroundStyle(.secondary)
            Divider()
            LabeledContent("上课时段", value: meeting.isScheduled ? "\(TimetableLayout.weekdayLabel(meeting.weekday)) · \(TimetableLayout.sectionLabel(meeting))" : "自由时间")
            if let time = TimetableLayout.timeLabel(meeting, in: term) { LabeledContent("作息时间", value: time) }
            LabeledContent("上课周次", value: TimetableLayout.weeksLabel(meeting.weeks))
            LabeledContent("教室", value: meeting.classroom.isEmpty ? "未提供" : meeting.classroom)
            LabeledContent("教师", value: meeting.teacher.isEmpty ? "未提供" : meeting.teacher)
            if !meeting.courseCode.isEmpty { LabeledContent("课程号", value: meeting.courseCode) }
            if !meeting.note.isEmpty { Text(meeting.note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Spacer()
                if let id = meeting.courseID, store.state.courses.contains(where: { $0.id == id }) {
                    Button("查看课程资料") { dismiss(); store.navigate(to: .course(id)) }.appPrimaryButton()
                }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(26)
        }.frame(width: 500, height: 460)
    }
}
