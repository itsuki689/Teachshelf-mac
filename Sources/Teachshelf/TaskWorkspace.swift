import SwiftUI
import TeachshelfCore

private enum TaskWorkspaceFilter: String, CaseIterable {
    case active = "全部计划"
    case unscheduled = "待安排"
    case pending = "未完成"
    case completed = "已完成"
    case cancelled = "已取消"
    case history = "已归档"
}

struct TaskWorkspace: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ViewState<String> private var search = ""
    @ViewState<TaskWorkspaceFilter> private var filter = TaskWorkspaceFilter.active
    @ViewState<UUID?> private var courseID: UUID?
    @ViewState<Set<UUID>> private var selection = Set<UUID>()
    @ViewState<StudyTask?> private var editingTask: StudyTask?
    @ViewState<Bool> private var creating = false
    @ViewState<Bool> private var confirmingDeletion = false

    private var tasks: [StudyTask] {
        store.state.tasks.filter { parent in
            let variants = [parent] + parent.exceptions.map { PlanCalendar.snapshot(of: parent, originalDate: $0.originalDate) }
            return variants.contains { task in
                let matchesFilter: Bool
                switch filter {
                case .active: matchesFilter = !task.isArchived
                case .unscheduled: matchesFilter = !task.isArchived && !task.isCancelled && !task.hasExecutionTime
                case .pending: matchesFilter = !task.isArchived && !task.isCancelled && task.completionRequired && !task.isCompleted
                case .completed: matchesFilter = !task.isArchived && !task.isCancelled && task.completionRequired && task.isCompleted
                case .cancelled: matchesFilter = !task.isArchived && task.isCancelled
                case .history: matchesFilter = task.isArchived
                }
                return matchesFilter && (courseID == nil || task.courseID == courseID)
                    && (search.isEmpty || "\(task.title) \(task.content) \(task.kind) \(task.location) \(store.courseName(task.courseID))".localizedCaseInsensitiveContains(search))
            }
        }.sorted { first, second in
            if first.isCancelled != second.isCancelled { return !first.isCancelled }
            if first.isCompleted != second.isCompleted { return !first.isCompleted }
            let firstDate = first.deadline ?? (first.hasExecutionTime ? first.startsAt : .distantFuture)
            let secondDate = second.deadline ?? (second.hasExecutionTime ? second.startsAt : .distantFuture)
            if firstDate != secondDate { return firstDate < secondDate }
            return first.title.localizedStandardCompare(second.title) == .orderedAscending
        }
    }

    private var selectedTask: StudyTask? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return store.state.tasks.first { $0.id == id }
    }
    private var pendingCount: Int { store.pendingTaskCount }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("计划列表").font(.system(size: 25, weight: .bold, design: .rounded))
                    Text(pendingCount == 0 ? "查看安排、截止时间与尚未排期的事情。" : "\(pendingCount) 项需要完成，其余安排按各自时间进行。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { creating = true } label: { Label("新建计划", systemImage: "plus") }
                    .appPrimaryButton().controlSize(.regular)
            }.padding(20)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    statusPicker
                    CourseMenu(selection: $courseID, courses: store.state.courses).frame(width: 145)
                    Spacer(minLength: 0)
                    searchField.frame(width: 200)
                }
                VStack(alignment: .leading, spacing: 10) {
                    statusPicker
                    HStack(spacing: 12) {
                        CourseMenu(selection: $courseID, courses: store.state.courses).frame(width: 145)
                        searchField
                    }
                }
            }.padding(.horizontal, 20).padding(.bottom, 15)
            Divider()
            WorkspaceSplitView {
                list
                if let task = selectedTask {
                    taskDetail(task).frame(minWidth: 230, idealWidth: 255, maxWidth: 290)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: selection.count > 1 ? "calendar" : "sidebar.right")
                            .font(.system(size: 32)).foregroundStyle(.tertiary)
                        Text(selection.count > 1 ? "已选择 \(selection.count) 项计划" : "选择计划查看详情")
                            .foregroundStyle(.secondary)
                    }.frame(minWidth: 230, idealWidth: 255, maxWidth: 290, maxHeight: .infinity)
                }
            }
        }
        .sheet(item: $editingTask) { TaskEditor(task: $0, compact: true, calendar: PlanCalendar.calendar) }
        .sheet(isPresented: $creating) {
            TaskEditor(task: StudyTask(title: "", kind: "自主规划", courseID: courseID,
                                      hasExecutionTime: false, completionRequired: false),
                       isNew: true, compact: true, calendar: PlanCalendar.calendar)
        }
        .confirmationDialog("删除所选 \(selection.count) 项计划？", isPresented: $confirmingDeletion) {
            Button("删除计划", role: .destructive) { deleteSelection() }
            Button("返回", role: .cancel) {}
        } message: {
            Text("对应的 DDL 一并移除，关联课程、资料和文件保留。")
        }
        .onChange(of: filter) { _, _ in selection = [] }
        .onChange(of: courseID) { _, _ in selection = [] }
        .onChange(of: store.state.tasks) { _, _ in selection.formIntersection(Set(tasks.map(\.id))) }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if tasks.isEmpty {
                EmptyStateView(symbol: "calendar", title: "这里暂时没有计划", detail: "新建计划，或调整筛选条件。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(tasks, selection: $selection) {
                    TableColumn("状态") { task in statusControl(task) }.width(38)
                    TableColumn("计划") { task in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).fontWeight(.medium)
                                .strikethrough(task.isCompleted || task.isCancelled)
                                .foregroundStyle(task.isCompleted || task.isCancelled ? .secondary : .primary).lineLimit(1)
                            Text("\(task.kind) · \(task.origin == .fixed ? "固定" : "活动")\(task.isCancelled ? " · 已取消" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                            if !task.isCancelled {
                                let cancelledCount = task.exceptions.filter { $0.cancelledAt != nil }.count
                                if cancelledCount > 0 { Text("\(cancelledCount) 次安排已取消").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical, 5)
                    }.width(min: 145, ideal: 220)
                    TableColumn("执行") { task in
                        if task.hasExecutionTime {
                            Text(task.startsAt.formatted(task.isAllDay ? .dateTime.month().day() : .dateTime.month().day().hour().minute()))
                                .foregroundStyle(.secondary).lineLimit(1)
                        } else { Text("待安排").foregroundStyle(.tertiary) }
                    }.width(min: 70, ideal: 100)
                    TableColumn("截止") { task in
                        if let deadline = task.deadline {
                            Text(deadline.formatted(.dateTime.month().day()))
                                .foregroundStyle(isOverdue(task) ? Color.red : Color.secondary)
                        } else { Text("—").foregroundStyle(.tertiary) }
                    }.width(70)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let id = ids.first, let task = store.state.tasks.first(where: { $0.id == id }) {
                        Button("编辑计划") { editingTask = task }.disabled(task.isArchived)
                        if task.completionRequired {
                            Button(task.isCompleted ? "标为未完成" : task.repeatRule == nil ? "完成计划" : "完成整组计划") { toggleCompletion(task) }
                                .disabled(task.isArchived || task.isCancelled)
                        }
                        Button(task.isCancelled ? "恢复安排" : "取消安排") { toggleCancellation(task) }.disabled(task.isArchived)
                        Button(task.isArchived ? "恢复计划" : "归档计划") { toggleArchive(task) }
                        Divider()
                    }
                    Button("删除所选计划", role: .destructive) { selection = ids; confirmingDeletion = true }.disabled(ids.isEmpty)
                } primaryAction: { ids in
                    if let id = ids.first, let task = store.state.tasks.first(where: { $0.id == id }), !task.isArchived { editingTask = task }
                }
            }
            Divider()
            HStack {
                Text(selection.isEmpty ? "\(tasks.count) 项计划" : "已选择 \(selection.count) 项")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !selection.isEmpty {
                    Button("删除所选", role: .destructive) { confirmingDeletion = true }.buttonStyle(.borderless)
                }
                Button { store.undoPlanChange() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                    .disabled(!store.canUndoPlanChange).buttonStyle(.borderless)
                    .help(store.planUndoLabel.map { "撤销\($0)" } ?? "暂无可撤销的计划修改")
            }.padding(12)
        }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusPicker: some View {
        Picker("筛选", selection: $filter) {
            ForEach(TaskWorkspaceFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.menu).frame(width: 120)
    }
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索计划", text: $search).textFieldStyle(.plain)
        }.padding(.horizontal, 9).frame(height: 32)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private func statusControl(_ task: StudyTask) -> some View {
        if task.isCancelled {
            Image(systemName: "xmark.circle").foregroundStyle(.secondary).help("已取消")
        } else if task.completionRequired {
            Button { toggleCompletion(task) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(task.isCompleted ? theme.ink : Color.secondary)
            }.buttonStyle(.plain).help(task.isCompleted ? "标为未完成" : task.repeatRule == nil ? "完成计划" : "完成整组计划").disabled(task.isArchived)
        } else {
            Image(systemName: task.hasExecutionTime ? "calendar" : "tray")
                .foregroundStyle(.secondary).help(task.hasExecutionTime ? "按时间安排" : "待安排")
        }
    }

    private func isOverdue(_ task: StudyTask) -> Bool {
        guard task.completionRequired, !task.isCompleted, !task.isCancelled, let due = task.deadline else { return false }
        if task.deadlineIsAllDay { return PlanCalendar.calendar.startOfDay(for: due) < PlanCalendar.calendar.startOfDay(for: Date()) }
        return due < Date()
    }

    private func taskDetail(_ task: StudyTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(task.kind).font(.caption.weight(.medium))
                        .padding(.horizontal, 9).padding(.vertical, 4).background(theme.selection, in: Capsule())
                    Spacer()
                    Button { editingTask = task } label: { Image(systemName: "pencil") }.help("编辑计划").disabled(task.isArchived)
                }
                Text(task.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Label(task.origin == .fixed ? "固定计划" : "活动计划", systemImage: task.origin == .fixed ? "lock" : "hand.draw")
                    .font(.caption).foregroundStyle(.secondary)
                if task.isCancelled {
                    Label("已取消", systemImage: "xmark.circle").foregroundStyle(.secondary)
                } else if task.completionRequired {
                    Button { toggleCompletion(task) } label: {
                        Label(task.isCompleted ? "已完成 · 点击重新打开" : task.repeatRule == nil ? "标记为完成" : "将整组标记为完成", systemImage: task.isCompleted ? "checkmark.circle.fill" : "circle")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).disabled(task.isArchived)
                }
                VStack(alignment: .leading, spacing: 11) {
                    if task.courseID != nil || task.courseNameSnapshot != nil {
                        Label(task.courseID == nil ? task.courseNameSnapshot ?? "" : store.courseName(task.courseID), systemImage: "graduationcap")
                    }
                    if task.hasExecutionTime {
                        Label(task.startsAt.formatted(task.isAllDay ? .dateTime.year().month().day() : .dateTime.month().day().hour().minute()), systemImage: "calendar")
                        if let end = task.endsAt {
                            Text("至 \(end.formatted(task.isAllDay ? .dateTime.year().month().day() : .dateTime.month().day().hour().minute()))").padding(.leading, 22)
                        }
                    } else {
                        Label("尚未安排执行时间", systemImage: "tray")
                    }
                    if let deadline = task.deadline {
                        Label("DDL · \(deadline.formatted(task.deadlineIsAllDay ? .dateTime.month().day() : .dateTime.month().day().hour().minute()))", systemImage: "flag")
                            .foregroundStyle(isOverdue(task) ? Color.red : Color.secondary)
                    }
                    if let rule = task.repeatRule { Label(repeatDescription(rule), systemImage: "repeat") }
                    if !task.location.isEmpty { Label(task.location, systemImage: "mappin.and.ellipse") }
                }.font(.callout).foregroundStyle(.secondary)
                if !task.content.isEmpty {
                    Divider()
                    Text(task.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !task.exceptions.isEmpty {
                    Divider()
                    Text("临时变更 · \(task.exceptions.count)").font(.headline)
                    PlanExceptionHistory(plan: task)
                }
                if !task.materialIDs.isEmpty {
                    Divider()
                    Text("关联资料").font(.headline)
                    ForEach(store.state.materials.filter { task.materialIDs.contains($0.id) }) { material in
                        Button { store.openMaterial(material) } label: {
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(theme.ink)
                                Text(material.title).lineLimit(2)
                                Spacer()
                                Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
                Divider()
                Button(task.isCancelled ? "恢复安排" : "取消安排") { toggleCancellation(task) }
                    .buttonStyle(.borderless).disabled(task.isArchived)
                Button(task.isArchived ? "恢复到计划" : "归档计划") { toggleArchive(task) }.buttonStyle(.borderless)
            }.padding(20)
        }
    }

    private func repeatDescription(_ rule: PlanRepeatRule) -> String {
        let unit: String
        switch rule.frequency { case .daily: unit = "天"; case .weekly: unit = "周"; case .monthly: unit = "月" }
        let prefix = "每 \(rule.interval) \(unit)重复"
        return rule.until.map { prefix + "，至 " + $0.formatted(.dateTime.month().day()) } ?? prefix
    }

    private func toggleCompletion(_ task: StudyTask) {
        _ = store.changePlan(id: task.id, label: task.isCompleted ? "重新打开计划" : "完成计划") {
            try $0.setTaskCompleted(id: task.id, completed: !task.isCompleted)
        }
    }

    private func toggleCancellation(_ task: StudyTask) {
        _ = store.changePlan(id: task.id, label: task.isCancelled ? "恢复安排" : "取消安排") { repository in
            if task.isCancelled {
                var restored = task; restored.cancelledAt = nil
                try repository.saveTask(restored)
            } else {
                try repository.cancelPlan(id: task.id)
            }
        }
    }

    private func toggleArchive(_ task: StudyTask) {
        _ = store.changePlan(id: task.id, label: task.isArchived ? "恢复计划" : "归档计划") { repository in
            if task.isArchived { try repository.restoreTask(id: task.id) }
            else { try repository.archiveTask(id: task.id) }
        }
    }

    private func deleteSelection() {
        let ids = selection
        guard let first = ids.first else { return }
        let saved = store.changePlan(id: first, label: "删除计划") { repository in
            try repository.deleteTasks(ids: ids)
        }
        if saved { selection = [] }
    }
}
