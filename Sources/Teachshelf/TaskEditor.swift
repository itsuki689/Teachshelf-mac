import SwiftUI
import TeachshelfCore


struct TaskEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ViewState<StudyTask> private var draft: StudyTask
    @ViewState<Bool> private var hasDeadline: Bool
    @ViewState<Date> private var deadline: Date
    @ViewState<String> private var materialSearch = ""
    private let isNew: Bool

    init(task: StudyTask, isNew: Bool = false) {
        _draft = State(initialValue: task)
        _hasDeadline = State(initialValue: task.deadline != nil)
        _deadline = State(initialValue: task.deadline ?? Calendar.current.date(byAdding: .day, value: 7, to: task.startsAt) ?? task.startsAt)
        self.isNew = isNew
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
            HStack {
                Image(systemName: "checklist").font(.title2).foregroundStyle(AppPalette.accent)
                Text(isNew ? "新建待办" : "编辑待办").font(.title2.weight(.semibold))
                Spacer()
            }.padding(24)

            Form {
                Section("任务内容") {
                    TextField("标题", text: $draft.title, prompt: Text("例如：完成第三章习题"))
                    HStack {
                        Picker("类型", selection: $draft.kind) {
                            ForEach(Array(Set(["任务", "作业", "考试", "阅读", "复习", draft.kind])).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        LabeledContent("课程") {
                            CourseMenu(selection: $draft.courseID,
                                       courses: store.state.courses.filter { !$0.isArchived || $0.id == draft.courseID },
                                       emptyTitle: "未分配课程")
                        }
                    }
                    TextEditor(text: $draft.content)
                        .font(.body)
                        .frame(minHeight: 86, maxHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if draft.content.isEmpty {
                                Text("说明、要求或学习计划…").foregroundStyle(.tertiary).padding(5).allowsHitTesting(false)
                            }
                        }
                }
                Section("时间安排") {
                    Toggle("全天任务", isOn: $draft.isAllDay)
                    DatePicker("开始", selection: $draft.startsAt, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    Toggle("设置截止时间", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("截止", selection: $deadline, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    }
                    Toggle("在日历中显示", isOn: $draft.showOnCalendar)
                }
                Section("关联资料 · \(draft.materialIDs.count)") {
                    TextField("搜索资料", text: $materialSearch)
                    if matchingMaterials.isEmpty {
                        Text("当前课程还没有可关联的资料").foregroundStyle(.secondary).padding(.vertical, 8)
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
                        }.frame(minHeight: 70, maxHeight: 150)
                    }
                }
            }.formStyle(.grouped).disabled(draft.isArchived)

            Divider()
            HStack {
                Text(draft.isArchived ? "恢复待办后可以继续编辑" : "资料会保持在原来的位置").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "创建待办" : "保存") {
                    draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.deadline = hasDeadline ? deadline : nil
                    if let courseID = draft.courseID { draft.courseNameSnapshot = store.courseName(courseID) }
                    guard !store.isBusy else { return }
                    guard !draft.isArchived, store.state.tasks.first(where: { $0.id == draft.id })?.isArchived != true else {
                        store.report(LibraryError.invalidInput("请先恢复已归档的待办，再进行编辑。"))
                        return
                    }
                    do {
                        try store.repository.saveTask(draft)
                        store.status = "待办已保存"
                        store.reload()
                        dismiss()
                    } catch { store.report(error) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy || draft.isArchived)
                .keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 650, height: 760)
    }
}
