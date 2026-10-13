import SwiftUI
import TeachshelfCore


private enum TaskWorkspaceFilter: String, CaseIterable {
    case active = "全部待办"
    case pending = "未完成"
    case completed = "已完成"
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

    private var tasks: [StudyTask] {
        store.state.tasks.filter { task in
            let matchesFilter: Bool
            switch filter {
            case .active: matchesFilter = !task.isArchived
            case .pending: matchesFilter = !task.isArchived && !task.isCompleted
            case .completed: matchesFilter = !task.isArchived && task.isCompleted
            case .history: matchesFilter = task.isArchived
            }
            return matchesFilter && (courseID == nil || task.courseID == courseID)
                && (search.isEmpty || "\(task.title) \(task.content) \(store.courseName(task.courseID))".localizedCaseInsensitiveContains(search))
        }.sorted { first, second in
            if first.isCompleted != second.isCompleted { return !first.isCompleted }
            let firstDate = first.deadline ?? .distantFuture
            let secondDate = second.deadline ?? .distantFuture
            if firstDate != secondDate { return firstDate < secondDate }
            return first.startsAt > second.startsAt
        }
    }

    private var selectedTask: StudyTask? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return store.state.tasks.first { $0.id == id }
    }

    private var pendingCount: Int { store.state.tasks.filter { !$0.isCompleted && !$0.isArchived }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("待办").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(pendingCount == 0 ? "把学习安排在这里，每一步都看得见。" : "还有 \(pendingCount) 项待办，慢慢来，一件一件完成。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { creating = true } label: { Label("新建待办", systemImage: "plus") }
                    .appPrimaryButton().controlSize(.regular)
            }.padding(24)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    statusPicker
                    CourseMenu(selection: $courseID, courses: store.state.courses).frame(width: 160)
                    Spacer(minLength: 0)
                    searchField.frame(width: 220)
                }
                VStack(alignment: .leading, spacing: 10) {
                    statusPicker
                    HStack(spacing: 12) {
                        CourseMenu(selection: $courseID, courses: store.state.courses).frame(width: 160)
                        searchField
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 18)

            Divider()
            WorkspaceSplitView {
                VStack(spacing: 0) {
                    if tasks.isEmpty {
                        EmptyStateView(symbol: "checkmark.circle", title: "这里暂时没有待办", detail: "新建一个任务，或调整筛选条件。")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(tasks, selection: $selection) {
                            TableColumn("完成") { task in
                                Button { store.setTaskCompleted(task) } label: {
                                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(task.isCompleted ? theme.ink : Color.secondary)
                                }.buttonStyle(.plain).help(task.isCompleted ? "标为未完成" : "完成待办").disabled(task.isArchived)
                            }.width(42)
                            TableColumn("任务") { task in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(task.title).fontWeight(.medium).strikethrough(task.isCompleted).foregroundStyle(task.isCompleted ? .secondary : .primary).lineLimit(1)
                                    Text(task.kind).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 5)
                            }.width(min: 180, ideal: 290)
                            TableColumn("课程") { task in
                                Text(task.courseID == nil ? (task.courseNameSnapshot ?? "未分配") : store.courseName(task.courseID)).foregroundStyle(.secondary).lineLimit(1)
                            }.width(min: 95, ideal: 130)
                            TableColumn("截止") { task in
                                if let deadline = task.deadline {
                                    Text(deadline.formatted(.dateTime.month().day()))
                                        .foregroundStyle(isOverdue(task) ? Color.red : Color.secondary)
                                } else { Text("—").foregroundStyle(.tertiary) }
                            }.width(85)
                        }
                        .contextMenu(forSelectionType: UUID.self) { ids in
                            if ids.count == 1, let id = ids.first, let task = store.state.tasks.first(where: { $0.id == id }) {
                                Button("编辑待办") { editingTask = task }.disabled(task.isArchived)
                                Button(task.isCompleted ? "标为未完成" : "完成待办") { store.setTaskCompleted(task) }.disabled(task.isArchived)
                                Button(task.isArchived ? "恢复待办" : "归档待办") { task.isArchived ? store.restoreTask(task) : store.archiveTask(task) }
                                Divider()
                            }
                            Button("删除所选待办", role: .destructive) { store.deleteTasks(ids); selection = [] }.disabled(ids.isEmpty)
                        } primaryAction: { ids in
                            if let id = ids.first, let task = store.state.tasks.first(where: { $0.id == id }), !task.isArchived { editingTask = task }
                        }
                    }
                    Divider()
                    HStack {
                        Text(selection.isEmpty ? "\(tasks.count) 项待办" : "已选择 \(selection.count) 项").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !selection.isEmpty {
                            Button("删除所选", role: .destructive) { store.deleteTasks(selection); selection = [] }.buttonStyle(.borderless)
                        }
                        Button { store.undoTaskDeletion() } label: { Label("撤销删除", systemImage: "arrow.uturn.backward") }
                            .disabled(!store.canUndoTaskDeletion).buttonStyle(.borderless)
                    }.padding(12)
                }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

                if let task = selectedTask {
                    taskDetail(task).frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: selection.count > 1 ? "checklist" : "sidebar.right").font(.system(size: 32)).foregroundStyle(.tertiary)
                        Text(selection.count > 1 ? "已选择 \(selection.count) 项待办" : "选择待办查看详情").foregroundStyle(.secondary)
                    }.frame(minWidth: 240, idealWidth: 280, maxWidth: 340, maxHeight: .infinity)
                }
            }
        }
        .sheet(item: $editingTask) { TaskEditor(task: $0) }
        .sheet(isPresented: $creating) { TaskEditor(task: StudyTask(title: "", courseID: courseID), isNew: true) }
        .onChange(of: filter) { _, _ in selection = [] }
        .onChange(of: courseID) { _, _ in selection = [] }
        .onChange(of: store.state.tasks) { _, _ in selection.formIntersection(Set(tasks.map(\.id))) }
    }

    private var statusPicker: some View {
        Picker("状态", selection: $filter) {
            ForEach(TaskWorkspaceFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden().pickerStyle(.segmented).tint(theme.controlAccent).frame(maxWidth: 410)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索待办", text: $search).textFieldStyle(.plain)
        }.padding(.horizontal, 9).frame(height: 32)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private func isOverdue(_ task: StudyTask) -> Bool {
        guard !task.isCompleted, let due = task.deadline else { return false }
        if task.isAllDay { return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: Date()) }
        return due < Date()
    }

    private func taskDetail(_ task: StudyTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(task.kind).font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 4).background(theme.selection, in: Capsule())
                    Spacer()
                    Button { editingTask = task } label: { Image(systemName: "pencil") }.help("编辑待办").disabled(task.isArchived)
                }
                Text(task.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Button { store.setTaskCompleted(task) } label: {
                    Label(task.isCompleted ? "已完成 · 点击重新打开" : "标记为完成", systemImage: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).disabled(task.isArchived)
                VStack(alignment: .leading, spacing: 12) {
                    Label(task.courseID == nil ? (task.courseNameSnapshot ?? "未分配课程") : store.courseName(task.courseID), systemImage: "graduationcap")
                    Label(task.startsAt.formatted(.dateTime.year().month().day()), systemImage: "calendar")
                    if let deadline = task.deadline {
                        Label("截止 \(deadline.formatted(task.isAllDay ? .dateTime.month().day() : .dateTime.month().day().hour().minute()))", systemImage: "clock")
                            .foregroundStyle(isOverdue(task) ? Color.red : Color.secondary)
                    }
                }.font(.callout).foregroundStyle(.secondary)
                if !task.content.isEmpty {
                    Divider()
                    Text(task.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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
                Button(task.isArchived ? "恢复到待办" : "归档待办") { task.isArchived ? store.restoreTask(task) : store.archiveTask(task) }
                    .buttonStyle(.borderless)
            }.padding(22)
        }
    }
}
