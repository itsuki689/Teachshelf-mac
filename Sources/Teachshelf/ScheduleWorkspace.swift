import SwiftUI
import TeachshelfCore

struct ScheduleWorkspace: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { ScheduleContent(selection: store.scheduleSelection) }
}

private struct ScheduleContent: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var selection: ScheduleSelection
    @AppStorage("scheduleViewMode") private var savedMode = ScheduleMode.week.rawValue
    @ViewState private var panel: SchedulePanel?
    @ViewState private var choosingDate = false

    private var terms: [TimetableTerm] { store.state.timetableTerms.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending } }
    private var term: TimetableTerm? { selection.term(in: store.state) }
    private var undatedWeek: Bool { selection.mode == .week && term != nil && term?.weekOneMonday == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            navigationControls
            filters
            Divider()
            dateNotice
            cancellationNotice
            Group {
                switch selection.mode {
                case .month:
                    ScheduleMonthView(selection: selection, onMeeting: showMeeting, onTask: editTask, onCreateTask: createTask)
                case .week:
                    ScheduleWeekView(selection: selection, onMeeting: showMeeting, onTask: editTask, onSettings: { panel = .settings($0) })
                case .agenda:
                    ScheduleAgendaView(selection: selection, onMeeting: showMeeting, onTask: editTask, onCreateTask: createTask)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.85), value: store.state.timetableTerms)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.calendar, TimetableTerm.academicCalendar)
        .environment(\.timeZone, TimetableTerm.academicCalendar.timeZone)
        .sheet(item: $panel) { item in
            sheet(item).environmentObject(store)
                .environment(\.calendar, TimetableTerm.academicCalendar)
                .environment(\.timeZone, TimetableTerm.academicCalendar.timeZone)
        }
        .onAppear {
            selection.setMode(ScheduleMode(rawValue: savedMode) ?? .week, in: store.state)
            selection.reconcile(store.state)
        }
        .onChange(of: selection.mode) { _, mode in savedMode = mode.rawValue }
        .onChange(of: store.state) { _, state in selection.reconcile(state) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("日程").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("课程、作业与截止时间，一起安排。").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selection.mode != .week && store.canUndoTimetableChange {
                Button { store.undoTimetableChange() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help(store.timetableUndoLabel.map { "撤销\($0)" } ?? "撤销课表调整")
                    .accessibilityLabel("撤销课表调整")
            }
            Button { panel = .importCourses } label: { Label("导入课表", systemImage: "square.and.arrow.down") }.buttonStyle(.bordered)
            Button { createTask(selection.selectedDate) } label: { Label("新建待办", systemImage: "plus") }.appPrimaryButton()
        }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
    }

    private var navigationControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { dateNavigation; Spacer(minLength: 8); modePicker }
            VStack(alignment: .leading, spacing: 12) { modePicker; dateNavigation }
        }.padding(.horizontal, 24).padding(.bottom, 14)
    }

    private var modePicker: some View {
        Picker("日程视图", selection: Binding(get: { selection.mode }, set: { selection.setMode($0, in: store.state) })) {
            ForEach(ScheduleMode.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
    }

    private var dateNavigation: some View {
        HStack(spacing: 9) {
            Button { selection.shift(-1, in: store.state) } label: { Image(systemName: "chevron.left") }
                .disabled(undatedWeek && (selection.week(in: store.state) ?? 1) <= 1).help(selection.mode == .month ? "上个月" : "上一周")
            if selection.mode == .week, let term {
                Menu {
                    ForEach(1...max(1, term.weekCount), id: \.self) { week in
                        Button { selection.setWeek(week, in: store.state) } label: {
                            if selection.week(in: store.state) == week { Label("第 \(week) 周", systemImage: "checkmark") }
                            else { Text("第 \(week) 周") }
                        }
                    }
                } label: {
                    Text(selection.week(in: store.state).map { "第 \($0) 周" } ?? "学期外").font(.callout.weight(.semibold)).monospacedDigit()
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("日程周次")
            }
            if !undatedWeek {
                Text(dateTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1).monospacedDigit()
                    .help("按北京时间显示")
            }
            Button { selection.shift(1, in: store.state) } label: { Image(systemName: "chevron.right") }
                .disabled(undatedWeek && (selection.week(in: store.state) ?? 1) >= (term?.weekCount ?? 1)).help(selection.mode == .month ? "下个月" : "下一周")
            Button(selection.mode == .week ? "本周" : "今天") { selection.today(in: store.state) }.disabled(undatedWeek)
            Button { choosingDate = true } label: { Image(systemName: "calendar.badge.clock") }
                .disabled(undatedWeek).help("跳转到日期").accessibilityLabel("跳转到日期")
                .popover(isPresented: $choosingDate) {
                    VStack(alignment: .leading, spacing: 12) {
                        DatePicker("选择日期", selection: Binding(get: { selection.selectedDate }, set: { selection.setDate($0) }), displayedComponents: .date)
                            .datePickerStyle(.graphical).labelsHidden()
                        HStack { Spacer(); Button("完成") { choosingDate = false } }
                    }.padding(16).frame(width: 300)
                        .environment(\.calendar, TimetableTerm.academicCalendar).environment(\.timeZone, TimetableTerm.academicCalendar.timeZone)
                }
        }.buttonStyle(.borderless)
    }

    private var dateTitle: String {
        if selection.mode == .month { return TimetableCalendar.formatted(selection.selectedDate, template: "yMMMM") }
        let days = selection.mode == .week ? ScheduleData.weekDays(in: store.state, selection: selection) : ScheduleData.agendaDays(selection: selection)
        guard let first = days.first, let last = days.last else { return TimetableCalendar.formatted(selection.selectedDate, template: "yMMMd") }
        return "\(TimetableCalendar.formatted(first, template: "MMMd"))–\(TimetableCalendar.formatted(last, template: "MMMd"))"
    }

    private var filters: some View {
        HStack(spacing: 12) {
            ChoiceMenu("日程学期", selection: Binding(get: { selection.termID }, set: { selection.setTerm($0, in: store.state) }), selectedTitle: term?.name ?? "全部学期") {
                if selection.mode != .week || terms.isEmpty { Text("全部学期").tag(nil as UUID?) }
                ForEach(terms) { Text($0.name).tag(Optional($0.id)) }
            }.frame(width: 235).disabled(terms.isEmpty)
            CourseMenu(selection: $selection.courseID, courses: selection.filteredCourses(in: store.state)).frame(width: 180)
            Spacer(minLength: 4)
            Menu {
                Toggle("显示课程", isOn: $selection.showsCourses)
                Toggle("显示待办", isOn: $selection.showsTasks)
            } label: { Label("显示内容", systemImage: "line.3.horizontal.decrease.circle") }.menuStyle(.borderlessButton).fixedSize()
            if let term {
                Button { panel = .settings(term) } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).help("学期与作息设置").accessibilityLabel("学期与作息设置")
            }
        }.padding(.horizontal, 24).padding(.bottom, 16)
    }

    @ViewBuilder private var dateNotice: some View {
        if selection.mode != .week, let term, term.weekOneMonday == nil {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                Text("设置开学日期后，课程与待办即可按真实日期对应。")
                Spacer(minLength: 4)
                Button("设置学期") { panel = .settings(term) }.buttonStyle(.plain).foregroundStyle(theme.ink)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10).background(theme.ink.opacity(0.045))
        } else if selection.termID == nil {
            let undated = terms.filter { $0.weekOneMonday == nil }
            if !undated.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark")
                    Text("\(undated.count) 个学期尚未设置开学日期，课程可在周课表中查看。")
                    Spacer(minLength: 4)
                    Menu("设置学期") { ForEach(undated) { term in Button(term.name) { panel = .settings(term) } } }.menuStyle(.borderlessButton).fixedSize()
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10).background(theme.ink.opacity(0.045))
            }
        }
    }

    private func showMeeting(_ context: ScheduleMeetingContext) {
        if let date = context.date { selection.setDate(date) }
        panel = .meeting(context)
    }

    private var cancellationGroups: [(term: TimetableTerm, count: Int)] {
        guard selection.showsCourses else { return [] }
        let calendar = TimetableTerm.academicCalendar
        let days = selection.mode == .week ? ScheduleData.weekDays(in: store.state, selection: selection) : ScheduleData.agendaDays(selection: selection)
        return terms.compactMap { term in
            guard selection.termID == nil || selection.termID == term.id else { return nil }
            let count = term.cancellations.filter { cancellation in
                let matchesDate = selection.mode == .month
                    ? calendar.isDate(cancellation.date, equalTo: selection.selectedDate, toGranularity: .month)
                    : days.contains { calendar.isDate($0, inSameDayAs: cancellation.date) }
                let matchesCourse = selection.courseID == nil || term.meetings.contains { $0.id == cancellation.meetingID && $0.courseID == selection.courseID }
                return matchesDate && matchesCourse
            }.count
            return count > 0 ? (term, count) : nil
        }
    }

    @ViewBuilder private var cancellationNotice: some View {
        let groups = cancellationGroups
        if !groups.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle")
                Text("当前范围有 \(groups.reduce(0) { $0 + $1.count }) 次停课，课程安排已同步更新。")
                Spacer(minLength: 4)
                Menu("查看记录") {
                    ForEach(groups.map(\.term)) { term in Button(term.name) { panel = .settings(term) } }
                }.menuStyle(.borderlessButton).fixedSize()
            }.font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }
    private func editTask(_ task: StudyTask) { panel = .task(task, false) }
    private func createTask(_ date: Date) { panel = .task(StudyTask(title: "", courseID: selection.courseID, startsAt: date), true) }

    @ViewBuilder private func sheet(_ item: SchedulePanel) -> some View {
        switch item {
        case .importCourses:
            NJUImportSheet { id in
                selection.setTerm(id, in: store.state)
                selection.setMode(.week, in: store.state)
            }
        case .settings(let term): TimetableSettingsSheet(term: term)
        case .task(let task, let isNew): TaskEditor(task: task, isNew: isNew, compact: true, calendar: TimetableTerm.academicCalendar)
        case .meeting(let context): ScheduleMeetingSheet(context: context)
        }
    }
}

private enum SchedulePanel: Identifiable {
    case importCourses
    case settings(TimetableTerm)
    case task(StudyTask, Bool)
    case meeting(ScheduleMeetingContext)
    var id: String {
        switch self {
        case .importCourses: return "import"
        case .settings(let term): return "settings-\(term.id)"
        case .task(let task, _): return "task-\(task.id)"
        case .meeting(let context): return "meeting-\(context.id)"
        }
    }
}
