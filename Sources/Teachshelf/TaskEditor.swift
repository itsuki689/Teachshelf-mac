import SwiftUI
import TeachshelfCore

struct TaskEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ViewState<StudyTask> private var draft: StudyTask
    @ViewState<Bool> private var hasDeadline: Bool
    @ViewState<Date> private var deadline: Date
    @ViewState<Date> private var executionEnd: Date
    @ViewState<Bool> private var repeats: Bool
    @ViewState<PlanRepeatFrequency> private var repeatFrequency: PlanRepeatFrequency
    @ViewState<Int> private var repeatInterval: Int
    @ViewState<Bool> private var repeatHasEnd: Bool
    @ViewState<Date> private var repeatEnd: Date
    @ViewState<String> private var materialSearch = ""
    @ViewState<PlanEditScope> private var editScope: PlanEditScope
    @ViewState<Bool> private var confirmingDeletion = false
    private let isNew: Bool
    private let compact: Bool
    private let calendar: Calendar
    private let occurrence: PlanOccurrence?
    private let focusDeadline: Bool
    private let originalPlan: StudyTask

    init(task: StudyTask, isNew: Bool = false, compact: Bool = false, calendar: Calendar = .current,
         occurrence: PlanOccurrence? = nil, focusDeadline: Bool = false) {
        let effective = occurrence?.task ?? task
        _draft = State(initialValue: effective)
        _hasDeadline = State(initialValue: effective.deadline != nil)
        _deadline = State(initialValue: effective.deadline ?? calendar.date(byAdding: .day, value: 7, to: effective.startsAt) ?? effective.startsAt)
        _executionEnd = State(initialValue: effective.endsAt ?? calendar.date(byAdding: .hour, value: 1, to: effective.startsAt) ?? effective.startsAt)
        _repeats = State(initialValue: task.repeatRule != nil)
        _repeatFrequency = State(initialValue: task.repeatRule?.frequency ?? .weekly)
        _repeatInterval = State(initialValue: task.repeatRule?.interval ?? 1)
        _repeatHasEnd = State(initialValue: task.repeatRule?.until != nil)
        _repeatEnd = State(initialValue: task.repeatRule?.until ?? calendar.date(byAdding: .month, value: 3, to: effective.startsAt) ?? effective.startsAt)
        _editScope = State(initialValue: occurrence != nil && task.repeatRule != nil ? .thisOccurrence : .all)
        self.isNew = isNew
        self.compact = compact
        self.calendar = calendar
        self.occurrence = occurrence
        self.focusDeadline = focusDeadline
        self.originalPlan = task
    }

    private var isSingleOccurrence: Bool { occurrence != nil && originalPlan.repeatRule != nil && editScope == .thisOccurrence }
    private var currentParent: StudyTask { store.state.tasks.first { $0.id == originalPlan.id } ?? originalPlan }
    private var scopeDescription: String {
        switch editScope {
        case .thisOccurrence: return "只调整本次，不改变后续重复安排。"
        case .thisAndFuture: return "本次及以后的安排使用新规则，之前的安排保留。"
        case .all: return "修改整组计划的内容与重复规则。"
        }
    }
    private var hasValidTitle: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var interactionHint: String {
        if focusDeadline { return "固定 DDL · 修改会同步主计划的截止时间" }
        let origin = draft.origin == .fixed ? "固定计划" : "活动计划"
        if !draft.hasExecutionTime { return "\(origin) · 可稍后安排执行时间" }
        if draft.isAllDay { return "\(origin) · 全天安排显示在日期旁的青色圆点中" }
        return draft.origin == .fixed ? "固定计划 · 开启固定计划编辑后可拖曳" : "活动计划 · 可以直接拖曳调整"
    }
    private var validationMessage: String? {
        if draft.hasExecutionTime && executionEnd < draft.startsAt { return "结束时间不能早于开始时间。" }
        if repeats && !draft.hasExecutionTime && !hasDeadline { return "重复计划需要执行时间或截止时间。" }
        let repeatStart = draft.hasExecutionTime ? draft.startsAt : (hasDeadline ? deadline : draft.startsAt)
        if repeats && !isSingleOccurrence && repeatHasEnd && calendar.startOfDay(for: repeatEnd) < calendar.startOfDay(for: repeatStart) {
            return "重复结束日期不能早于首次安排日期。"
        }
        return nil
    }
    private var matchingMaterials: [MaterialRecord] {
        store.state.materials.filter { material in
            let matchesCourse = draft.courseID == nil || material.courseID == draft.courseID || draft.materialIDs.contains(material.id)
            let matchesSearch = materialSearch.isEmpty || "\(material.title) \(material.originalName)".localizedCaseInsensitiveContains(materialSearch)
            return matchesCourse && matchesSearch
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                if occurrence != nil && originalPlan.repeatRule != nil {
                    Section("修改范围") {
                        Picker("应用于", selection: $editScope) {
                            Text("仅本次").tag(PlanEditScope.thisOccurrence)
                            Text("本次及以后").tag(PlanEditScope.thisAndFuture)
                            Text("整组计划").tag(PlanEditScope.all)
                        }.pickerStyle(.segmented)
                        Text(scopeDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                contentSection
                if focusDeadline { deadlineSection; executionSection }
                else { executionSection; deadlineSection }
                repeatSection
                materialSection
                if !isNew && !currentParent.exceptions.isEmpty {
                    Section("临时变更 · \(currentParent.exceptions.count)") {
                        PlanExceptionHistory(plan: currentParent, onRestored: syncRestoredOccurrence)
                    }
                }
                if !isNew { managementSection }
            }
            .formStyle(.grouped)
            .disabled(draft.isArchived)
            Divider()
            footer
        }
        .frame(width: 650, height: compact ? 620 : 760)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .onChange(of: editScope) { _, scope in
            draft = scope == .all ? currentParent : occurrence.map { PlanCalendar.snapshot(of: currentParent, originalDate: $0.originalDate) } ?? currentParent
            hasDeadline = draft.deadline != nil
            deadline = draft.deadline ?? calendar.date(byAdding: .day, value: 7, to: draft.startsAt) ?? draft.startsAt
            executionEnd = draft.endsAt ?? calendar.date(byAdding: .hour, value: 1, to: draft.startsAt) ?? draft.startsAt
            repeats = draft.repeatRule != nil
            repeatFrequency = draft.repeatRule?.frequency ?? .weekly
            repeatInterval = draft.repeatRule?.interval ?? 1
            repeatHasEnd = draft.repeatRule?.until != nil
            repeatEnd = draft.repeatRule?.until ?? calendar.date(byAdding: .month, value: 3, to: draft.startsAt) ?? draft.startsAt
        }
        .confirmationDialog(removalTitle + "？", isPresented: $confirmingDeletion) {
            Button(removalTitle, role: .destructive) { deletePlan() }
            Button("返回", role: .cancel) {}
        } message: {
            Text(isSingleOccurrence ? "本次安排及其 DDL 将移除，其他重复安排保留。可以撤销。" : editScope == .thisAndFuture ? "本次及以后的安排与 DDL 将移除，之前的安排保留。可以撤销。" : "关联的 DDL 一并移除，课程、资料和文件保留。可以撤销。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: focusDeadline ? "flag" : "calendar.badge.plus")
                .font(.title2).foregroundStyle(theme.ink)
            VStack(alignment: .leading, spacing: 4) {
                Text(isNew ? "新建计划" : focusDeadline ? "编辑截止安排" : "编辑计划")
                    .font(.title2.weight(.semibold))
                Text(interactionHint)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.horizontal, 24).padding(.vertical, 19)
    }

    private var contentSection: some View {
        Section("计划内容") {
            TextField("名称", text: $draft.title, prompt: Text("想安排什么？"))
            HStack {
                TextField("类型", text: $draft.kind, prompt: Text("可以自定义"))
                Menu("常用类型") {
                    ForEach(["课程", "考试", "自主规划", "志愿活动", "作业", "阅读", "复习", "空", "其他"], id: \.self) { kind in
                        Button(kind) {
                            draft.kind = kind
                            if isNew { draft.completionRequired = ["作业", "阅读", "复习"].contains(kind) }
                        }
                    }
                }.fixedSize()
            }
            TextField("地点", text: $draft.location, prompt: Text("教室、活动地点或线上地址"))
            LabeledContent("关联课程") {
                CourseMenu(selection: $draft.courseID,
                           courses: store.state.courses.filter { !$0.isArchived || $0.id == draft.courseID },
                           emptyTitle: "未关联课程")
            }
            TextEditor(text: $draft.content)
                .font(.body).frame(minHeight: 58, maxHeight: 90)
                .overlay(alignment: .topLeading) {
                    if draft.content.isEmpty {
                        Text("备注、要求或活动说明…").foregroundStyle(.tertiary).padding(5).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("计划备注")
            Toggle("需要手动确认完成", isOn: $draft.completionRequired)
        }
    }

    private var executionSection: some View {
        Section("执行安排") {
            Toggle("安排执行时间", isOn: $draft.hasExecutionTime)
            if draft.hasExecutionTime {
                Toggle("全天", isOn: $draft.isAllDay)
                DatePicker("开始", selection: Binding(get: { draft.startsAt }, set: { date in
                    let offset = date.timeIntervalSince(draft.startsAt)
                    draft.startsAt = date
                    executionEnd = executionEnd.addingTimeInterval(offset)
                }), displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("结束", selection: $executionEnd, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                Toggle("将执行安排加入月历", isOn: $draft.showInMonth)
                Text("周、日视图显示执行安排；月历只在开启此选项时显示。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("可以先记下来，稍后再安排时间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var deadlineSection: some View {
        Section("截止安排") {
            Toggle("设置截止时间", isOn: $hasDeadline)
            if hasDeadline {
                Toggle("按日期截止", isOn: $draft.deadlineIsAllDay)
                DatePicker("截止", selection: $deadline, displayedComponents: draft.deadlineIsAllDay ? [.date] : [.date, .hourAndMinute])
                Label("自动生成固定的 DDL 子计划，默认显示在月历。", systemImage: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var repeatSection: some View {
        Section("重复规则") {
            Toggle("重复安排", isOn: $repeats).disabled(isSingleOccurrence)
            if repeats {
                HStack {
                    Stepper("每 \(repeatInterval)", value: $repeatInterval, in: 1...99).frame(maxWidth: 160)
                    Picker("频率", selection: $repeatFrequency) {
                        Text("天").tag(PlanRepeatFrequency.daily)
                        Text("周").tag(PlanRepeatFrequency.weekly)
                        Text("月").tag(PlanRepeatFrequency.monthly)
                    }.labelsHidden()
                }.disabled(isSingleOccurrence)
                Toggle("设置重复结束日期", isOn: $repeatHasEnd).disabled(isSingleOccurrence)
                if repeatHasEnd {
                    DatePicker("重复至", selection: $repeatEnd, displayedComponents: [.date]).disabled(isSingleOccurrence)
                }
                if isSingleOccurrence {
                    Text("如需修改重复规则，请切换到整组计划。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var materialSection: some View {
        Section("关联资料 · \(draft.materialIDs.count)") {
            TextField("搜索资料", text: $materialSearch)
            if matchingMaterials.isEmpty {
                Text("当前没有可关联的资料").foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(matchingMaterials) { material in
                            Toggle(isOn: Binding(
                                get: { draft.materialIDs.contains(material.id) },
                                set: { selected in
                                    draft.materialIDs.removeAll { $0 == material.id }
                                    if selected { draft.materialIDs.append(material.id) }
                                }
                            )) {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    Text(material.title).lineLimit(1)
                                    Spacer()
                                    Text(material.fileType).font(.caption).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.padding(.vertical, 4)
                }.frame(minHeight: 55, maxHeight: 120)
            }
        }
    }

    private var managementSection: some View {
        Section("管理安排") {
            HStack {
                Button(draft.cancelledAt == nil ? (isSingleOccurrence ? "取消本次安排" : editScope == .thisAndFuture ? "取消本次及以后" : "取消安排") : "恢复安排") { toggleCancellation() }
                Spacer()
                Button(removalTitle, role: .destructive) { confirmingDeletion = true }
            }
            Text(isSingleOccurrence ? "这些操作仅影响本次安排，关联资料保留。" : editScope == .thisAndFuture ? "这些操作影响本次及以后的安排，之前的记录保留。" : "取消保留计划记录，删除移除计划及其 DDL。关联资料保留。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var removalTitle: String {
        if isSingleOccurrence { return "移除本次计划" }
        if editScope == .thisAndFuture { return "移除本次及以后" }
        return "删除计划"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            } else {
                Text(draft.isArchived ? "恢复计划后可以继续编辑" : "名称为必填项，其余内容可稍后补充")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(isNew ? "创建计划" : "保存") { save() }
                .appPrimaryButton()
                .disabled(!hasValidTitle || validationMessage != nil || store.isBusy || draft.isArchived)
                .keyboardShortcut(.defaultAction)
        }.padding(20)
    }

    private func save() {
        guard !store.isBusy, !draft.isArchived else { return }
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.kind = draft.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.kind.isEmpty { draft.kind = "其他" }
        draft.location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.deadline = hasDeadline ? deadline : nil
        draft.endsAt = draft.hasExecutionTime ? executionEnd : nil
        if !draft.completionRequired { draft.completedAt = nil }
        draft.showOnCalendar = true
        draft.exceptions = currentParent.exceptions
        if !isSingleOccurrence {
            draft.repeatRule = repeats ? PlanRepeatRule(frequency: repeatFrequency, interval: repeatInterval, until: repeatHasEnd ? repeatEnd : nil) : nil
        }
        if let courseID = draft.courseID { draft.courseNameSnapshot = store.courseName(courseID) }
        let saved = store.changePlan(id: draft.id, label: isNew ? "创建计划" : isSingleOccurrence ? "调整本次计划" : "编辑计划") { repository in
            try repository.savePlan(draft, originalDate: occurrence?.originalDate, scope: editScope)
        }
        if saved { dismiss() }
    }

    private func syncRestoredOccurrence(_ date: Date, kind: PlanExceptionRestoreKind) {
        draft.exceptions = currentParent.exceptions
        guard editScope != .all, occurrence?.originalDate == date else { return }
        let effective = PlanCalendar.snapshot(of: currentParent, originalDate: date)
        switch kind {
        case .cancellation: draft.cancelledAt = effective.cancelledAt
        case .completion: draft.completedAt = effective.completedAt
        case .all:
            draft = effective
            hasDeadline = draft.deadline != nil
            deadline = draft.deadline ?? calendar.date(byAdding: .day, value: 7, to: draft.startsAt) ?? draft.startsAt
            executionEnd = draft.endsAt ?? calendar.date(byAdding: .hour, value: 1, to: draft.startsAt) ?? draft.startsAt
        }
    }

    private func toggleCancellation() {
        let cancelling = draft.cancelledAt == nil
        let saved = store.changePlan(id: draft.id, label: cancelling ? "取消安排" : "恢复安排") { repository in
            if cancelling {
                try repository.cancelPlan(id: draft.id, originalDate: occurrence?.originalDate, scope: editScope)
            } else if isSingleOccurrence, let occurrence {
                try repository.setPlanOccurrenceCancelled(id: draft.id, originalDate: occurrence.originalDate, cancelled: cancelling)
            } else {
                var plan = editScope == .all ? currentParent : draft
                plan.cancelledAt = nil
                try repository.savePlan(plan, originalDate: occurrence?.originalDate, scope: editScope)
            }
        }
        if saved { dismiss() }
    }

    private func deletePlan() {
        let saved = store.changePlan(id: draft.id, label: isSingleOccurrence ? "移除本次计划" : "删除计划") { repository in
            try repository.deletePlan(id: draft.id, originalDate: occurrence?.originalDate, scope: editScope)
        }
        if saved { dismiss() }
    }
}
