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
    @AppStorage("planViewMode") private var savedMode = ScheduleMode.week.rawValue
    @ViewState private var panel: SchedulePanel?
    @ViewState private var choosingDate = false
    @ViewState private var adjusting = false

    private var terms: [TimetableTerm] { store.state.timetableTerms.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending } }
    private var term: TimetableTerm? { selection.term(in: store.state) }
    private var undatedWeek: Bool { selection.mode == .week && term != nil && term?.weekOneMonday == nil }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    dateNavigation
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).frame(height: 48)
                    Divider()
                    Group {
                        switch selection.mode {
                        case .month:
                            ScheduleMonthView(selection: selection)
                        case .week:
                            ScheduleWeekView(selection: selection, adjusting: $adjusting, onMeeting: showMeeting,
                                             onPlan: editOccurrence, onCreate: createEmptyPlan)
                        case .agenda:
                            ScheduleAgendaView(selection: selection, onMeeting: showMeeting, onPlan: editOccurrence, onCreateTask: createTask)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.85), value: store.state.timetableTerms)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector.frame(width: min(300, max(224, geometry.size.width * 0.26)))
            }
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

    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Text("计划").font(.system(size: 18, weight: .semibold))
                        Spacer(minLength: 0)
                        Button { panel = .list } label: { Image(systemName: "list.bullet") }
                            .help("计划列表").accessibilityLabel("计划列表")
                        Button { panel = .importCourses } label: { Image(systemName: "square.and.arrow.down") }
                            .help("导入课表").accessibilityLabel("导入课表")
                        if let term {
                            Button { panel = .settings(term) } label: { Image(systemName: "slider.horizontal.3") }
                                .help("学期与作息设置").accessibilityLabel("学期与作息设置")
                        }
                    }.buttonStyle(.borderless)
                    modePicker
                    filters
                    if selection.mode == .week { adjustmentControls }
                    if store.canUndoTimetableChange {
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) {
                                store.undoTimetableChange()
                            }
                        } label: { Label("撤销上次调整", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(.borderless)
                            .help(store.timetableUndoLabel.map { "撤销\($0)" } ?? "撤销课表调整")
                            .accessibilityLabel(store.timetableUndoLabel.map { "撤销\($0)" } ?? "撤销课表调整")
                    }
                    if store.canUndoPlanChange {
                        Button { store.undoPlanChange() } label: { Label("撤销计划修改", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(.borderless).help(store.planUndoLabel ?? "撤销计划修改")
                    }
                    dateNotice
                    cancellationNotice
                    Divider()
                    ScheduleSideAgenda(selection: selection, onMeeting: showMeeting, onPlan: editOccurrence, onTask: editTask)
                }.padding(16)
            }
            Divider()
            HStack(spacing: 8) {
            Button { createUnplanned() } label: {
                Label("新建计划", systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).controlSize(.large)
            Menu {
                Button("新建“空”") {
                    let calendar = TimetableTerm.academicCalendar
                    let begin = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: selection.selectedDate) ?? selection.selectedDate
                    createEmptyPlan(begin, begin.addingTimeInterval(3600))
                }
                Button("添加全天安排") { createTask(selection.selectedDate) }
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多新建计划方式")
            }.padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .accessibilityElement(children: .contain).accessibilityLabel("计划选项与当天安排")
    }

    private var modePicker: some View {
        Picker("计划视图", selection: Binding(get: { selection.mode }, set: { selection.setMode($0, in: store.state) })) {
            ForEach(ScheduleMode.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().pickerStyle(.segmented).controlSize(.small)
    }

    private var dateNavigation: some View {
        HStack(spacing: 10) {
            Button { selection.shift(-1, in: store.state) } label: { Image(systemName: "chevron.left") }
                .disabled(undatedWeek && (selection.week(in: store.state) ?? 1) <= 1).help(selection.mode == .month ? "上个月" : (selection.mode == .agenda ? "前一天" : "上一周"))
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
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("计划周次")
            }
            if !undatedWeek {
                Text(dateTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1).monospacedDigit()
                    .help("按北京时间显示")
            }
            Button { selection.shift(1, in: store.state) } label: { Image(systemName: "chevron.right") }
                .disabled(undatedWeek && (selection.week(in: store.state) ?? 1) >= (term?.weekCount ?? 1)).help(selection.mode == .month ? "下个月" : (selection.mode == .agenda ? "后一天" : "下一周"))
            Spacer(minLength: 0)
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
        if selection.mode == .agenda { return TimetableCalendar.formatted(selection.selectedDate, template: "MMMdEEEE") }
        let days = selection.mode == .week ? ScheduleData.weekDays(in: store.state, selection: selection) : ScheduleData.agendaDays(selection: selection)
        guard let first = days.first, let last = days.last else { return TimetableCalendar.formatted(selection.selectedDate, template: "yMMMd") }
        return "\(TimetableCalendar.formatted(first, template: "MMMd"))–\(TimetableCalendar.formatted(last, template: "MMMd"))"
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChoiceMenu("计划学期", selection: Binding(get: { selection.termID }, set: { selection.setTerm($0, in: store.state) }), selectedTitle: term?.name ?? "全部学期", compact: true) {
                if selection.mode != .week || terms.isEmpty { Text("全部学期").tag(nil as UUID?) }
                ForEach(terms) { Text($0.name).tag(Optional($0.id)) }
            }.disabled(terms.isEmpty)
            CourseMenu(selection: $selection.courseID, courses: selection.filteredCourses(in: store.state))
            ChoiceMenu("计划筛选", selection: $selection.planFilter, selectedTitle: selection.planFilter.rawValue, compact: true) {
                ForEach(SchedulePlanFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            HStack(spacing: 16) {
                Toggle("固定", isOn: $selection.showsCourses).help("显示导入课程与自动 DDL 等固定计划")
                Toggle("活动", isOn: $selection.showsTasks).help("显示手动创建的活动计划")
            }.toggleStyle(.checkbox).controlSize(.small).font(.caption)
        }
    }

    private var adjustmentControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("编辑固定计划", isOn: $adjusting).toggleStyle(.switch).controlSize(.small)
                .disabled(!selection.showsCourses)
                .help("开启后可拖动课程和 DDL；活动计划始终可以拖动")
            Text("活动计划可直接拖动；空白处拖出“空”。课程和 DDL 需先开启编辑。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var dateNotice: some View {
        if let term, term.weekOneMonday == nil {
            VStack(alignment: .leading, spacing: 8) {
                Label("课表按周次显示。设置开学日期后，可与真实日期和活动计划对应。", systemImage: "calendar.badge.exclamationmark")
                Button("设置开学日期") { panel = .settings(term) }.buttonStyle(.borderless).foregroundStyle(theme.ink)
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if selection.mode == .week, term == nil {
            Label("可以直接创建活动计划，也可导入本科课表。", systemImage: "rectangle.split.3x3")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if selection.mode == .week, selection.week(in: store.state) == nil {
            Label("当前周在学期之外，活动计划仍可正常安排。", systemImage: "calendar")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if selection.termID == nil {
            let undated = terms.filter { $0.weekOneMonday == nil }
            if !undated.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(undated.count) 个学期尚未设置开学日期，课程可在周课表中查看。", systemImage: "calendar.badge.exclamationmark")
                    Menu("设置学期") { ForEach(undated) { term in Button(term.name) { panel = .settings(term) } } }.menuStyle(.borderlessButton).fixedSize()
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Menu {
                ForEach(groups.map(\.term)) { term in Button(term.name) { panel = .settings(term) } }
            } label: {
                Label("\(groups.reduce(0) { $0 + $1.count }) 次停课 · 查看记录", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("查看停课记录")
        }
    }
    private func editTask(_ task: StudyTask) { panel = .task(task, false, nil) }
    private func editOccurrence(_ occurrence: PlanOccurrence) {
        guard let source = store.state.tasks.first(where: { $0.id == occurrence.task.id }) else { return }
        panel = .task(source, false, occurrence)
    }
    private func createUnplanned() {
        panel = .task(StudyTask(title: "", courseID: selection.courseID, startsAt: selection.selectedDate,
                                hasExecutionTime: false, completionRequired: false), true, nil)
    }
    private func createTask(_ date: Date) {
        panel = .task(StudyTask(title: "", courseID: selection.courseID, startsAt: date,
                                hasExecutionTime: true, endsAt: TimetableTerm.academicCalendar.date(byAdding: .day, value: 1, to: date),
                                completionRequired: false), true, nil)
    }
    private func createEmptyPlan(_ begin: Date, _ end: Date) {
        panel = .task(StudyTask(title: "空", kind: "空", courseID: selection.courseID, startsAt: begin, isAllDay: false,
                                hasExecutionTime: true, endsAt: end, completionRequired: false), true, nil)
    }

    @ViewBuilder private func sheet(_ item: SchedulePanel) -> some View {
        switch item {
        case .importCourses:
            NJUImportSheet { id in
                selection.setTerm(id, in: store.state)
                selection.setMode(.week, in: store.state)
            }
        case .settings(let term): TimetableSettingsSheet(term: term)
        case .task(let task, let isNew, let occurrence):
            TaskEditor(task: task, isNew: isNew, compact: true, calendar: TimetableTerm.academicCalendar,
                       occurrence: occurrence, focusDeadline: occurrence?.isDeadline ?? false)
        case .list:
            VStack(spacing: 0) {
                TaskWorkspace()
                Divider()
                HStack {
                    Spacer()
                    Button("完成") { panel = nil }.keyboardShortcut(.cancelAction)
                }.padding(12)
            }.frame(width: 900, height: 650)
        case .meeting(let context): ScheduleMeetingSheet(context: context)
        }
    }
}

private enum SchedulePanel: Identifiable {
    case importCourses
    case settings(TimetableTerm)
    case task(StudyTask, Bool, PlanOccurrence?)
    case list
    case meeting(ScheduleMeetingContext)
    var id: String {
        switch self {
        case .importCourses: return "import"
        case .settings(let term): return "settings-\(term.id)"
        case .task(let task, _, let occurrence): return occurrence?.id ?? "task-\(task.id)"
        case .list: return "list"
        case .meeting(let context): return "meeting-\(context.id)"
        }
    }
}
