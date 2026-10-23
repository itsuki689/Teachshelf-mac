import SwiftUI
import AppKit
import TeachshelfCore

struct CourseEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let course: Course?
    @ViewState private var name: String
    @ViewState private var semester: String
    @ViewState private var teacher: String
    @ViewState private var color: Color
    init(course: Course?) {
        self.course = course
        _name = State(initialValue: course?.name ?? "")
        _semester = State(initialValue: course?.semester ?? "")
        _teacher = State(initialValue: course?.teacher ?? "")
        _color = State(initialValue: Color(hex: course?.colorHex ?? "#39786B"))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "books.vertical.fill").font(.title2).foregroundStyle(color)
                Text(course == nil ? "新建课程" : "编辑课程").font(.title2.weight(.semibold))
                Spacer()
            }.padding(24)
            Form {
                TextField("课程名称", text: $name)
                TextField("学期", text: $semester, prompt: Text("例如：2026 秋季"))
                TextField("教师", text: $teacher)
                ColorPicker("课程颜色", selection: $color, supportsOpacity: false)
            }.formStyle(.grouped)
            Divider()
            HStack {
                if course != nil { Button("删除课程…", role: .destructive, action: delete) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).appPrimaryButton().keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(20)
        }.frame(width: 460, height: 380)
            .dismissColorPanelAutomatically()
    }
    private func save() {
        var value = course ?? Course(name: name)
        value.name = name; value.semester = semester; value.teacher = teacher; value.colorHex = color.hexString
        do { try store.repository.saveCourse(value); store.reload(); store.navigate(to: .course(value.id)); store.status = "课程已保存"; dismiss() }
        catch { store.report(error) }
    }
    private func delete() {
        guard let course else { return }
        let alert = NSAlert(); alert.messageText = "删除课程「\(course.name)」？"
        alert.informativeText = "资料转为未分类，关联计划保留历史课程名称。作业文件夹与实际文件全部保留。"
        alert.addButton(withTitle: "删除课程"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            do { try store.repository.deleteCourse(id: course.id); store.reload(); store.navigate(to: .unassigned); dismiss() }
            catch { store.report(error) }
        }
    }
}

struct ImportSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]
    @ViewState private var courseID: UUID?
    @ViewState private var category = "课件"
    @ViewState private var copy = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "square.and.arrow.down").font(.title).foregroundStyle(theme.ink)
                VStack(alignment: .leading, spacing: 4) {
                    Text("导入资料").font(.title2.weight(.semibold))
                    Text("已选择 \(urls.count) 个文件或文件夹").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) { ForEach(urls, id: \.path) { url in Label(url.lastPathComponent, systemImage: url.hasDirectoryPath ? "folder" : "doc").font(.callout).lineLimit(1).help(url.path) } }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 110).padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("所属课程").frame(width: 57, alignment: .trailing)
                CourseMenu(selection: $courseID, courses: store.state.courses, emptyTitle: "未分类", title: "所属课程")
            }
            HStack {
                Text("类别").frame(width: 57, alignment: .trailing)
                TextField("可输入自定义类别", text: $category)
                Menu {
                    ForEach(store.categories, id: \.self) { value in Button(value) { category = value } }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .accessibilityLabel("选择已有类别")
            }
            Picker("存储方式", selection: $copy) {
                Text("复制到资料库").tag(true)
                Text("引用原文件").tag(false)
            }.pickerStyle(.radioGroup)
            Text(copy ? "原文件保留。副本按课程分文件夹保存，随资料库备份与迁移。" : "文件保持原位置。移动原文件后需要重新定位，外部文件需另行备份。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入") {
                    let target = courseID; let chosenCategory = category; let shouldCopy = copy
                    dismiss()
                    Task { await store.importMaterials(urls: urls, courseID: target, category: chosenCategory, copy: shouldCopy) }
                }.appPrimaryButton().keyboardShortcut(.defaultAction).disabled(urls.isEmpty || category.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(26).frame(width: 490).onAppear { courseID = store.currentCourseID }
    }
}

struct MaterialInspector: View {
    @EnvironmentObject private var store: AppStore
    let material: MaterialRecord
    @ViewState private var title: String
    @ViewState private var courseID: UUID?
    @ViewState private var category: String
    @ViewState private var tags: String
    @ViewState private var notes: String
    @ViewState private var taskToCreate: StudyTask?
    init(material: MaterialRecord) {
        self.material = material
        _title = State(initialValue: material.title); _courseID = State(initialValue: material.courseID)
        _category = State(initialValue: material.category); _tags = State(initialValue: material.tags); _notes = State(initialValue: material.notes)
    }
    private var hasEdits: Bool { title != material.title || courseID != material.courseID || category != material.category || tags != material.tags || notes != material.notes }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("资料信息").font(.headline); Spacer(); Button { if confirmEdits() { store.selectMaterials([]) } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                CoverThumbnail(material: material, url: try? store.repository.resolveURL(material), color: store.courseColor(material.courseID)).frame(width: 130, height: 175).frame(maxWidth: .infinity).padding(.vertical, 5)
                HStack(spacing: 8) {
                    Button("打开") { if confirmEdits() { store.openMaterial(material) } }.appPrimaryButton()
                    Button { QuickLookController.shared.show(try? store.repository.resolveURL(material)) } label: { Image(systemName: "eye") }.help("快速查看 · 空格")
                    Button { store.favorite(material) } label: { Image(systemName: material.isFavorite ? "star.fill" : "star").foregroundStyle(material.isFavorite ? .orange : .secondary) }.help("收藏")
                    Button { if let url = try? store.repository.resolveURL(material) { store.revealURL(url) } } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                }.controlSize(.small)
                Divider()
                field("名称") { TextField("资料名称", text: $title) }
                field("课程") {
                    CourseMenu(selection: $courseID, courses: store.state.courses, emptyTitle: "未分类")
                }
                field("类别") { TextField("类别，可自定义", text: $category) }
                field("标签") { TextField("用空格或逗号分隔", text: $tags) }
                field("备注") { TextEditor(text: $notes).font(.callout).frame(minHeight: 95).padding(5).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6)) }
                Button(hasEdits ? "保存修改" : "已保存", action: { _ = save() }).buttonStyle(.bordered).disabled(!hasEdits)
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text(material.originalName).lineLimit(2)
                    Text("\(material.fileExtension) · \(material.sizeLabel)")
                    Label(material.isManaged ? "已复制到资料库" : "引用原文件", systemImage: material.isManaged ? "internaldrive" : "link")
                    if material.isMissing == true { Label("位置丢失，请重新定位文件", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Text(material.addedAt, format: .dateTime.year().month().day())
                }.font(.caption).foregroundStyle(.secondary)
                Button("创建关联计划") {
                    if confirmEdits() {
                        taskToCreate = StudyTask(title: "", kind: "自主规划", courseID: material.courseID,
                                                materialIDs: [material.id], hasExecutionTime: false,
                                                completionRequired: false)
                    }
                }.controlSize(.small)
                if !material.isManaged || material.isMissing == true { Button("重新定位文件…", action: relink).controlSize(.small) }
            }.padding(22)
        }.background(.bar)
            .onAppear { store.beforeLeavingMaterial = confirmEdits }
            .onChange(of: material) { old, new in
                // Rebase unchanged fields while preserving the user's unsaved draft.
                if title == old.title { title = new.title }
                if courseID == old.courseID { courseID = new.courseID }
                if category == old.category { category = new.category }
                if tags == old.tags { tags = new.tags }
                if notes == old.notes { notes = new.notes }
                store.beforeLeavingMaterial = confirmEdits
            }
            .onDisappear { store.beforeLeavingMaterial = nil }
            .onReceive(NotificationCenter.default.publisher(for: .saveMaterial)) { _ in _ = save() }
            .sheet(item: $taskToCreate) { task in TaskEditor(task: task, isNew: true).environmentObject(store) }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }
    private func save() -> Bool {
        guard var value = store.state.materials.first(where: { $0.id == material.id }) else { return true }
        value.title = title; value.courseID = courseID; value.category = category; value.tags = tags; value.notes = notes
        do { try store.repository.updateMaterial(value); store.reload(); store.status = "资料信息已保存"; return true }
        catch { store.report(error); return false }
    }
    private func confirmEdits() -> Bool {
        guard hasEdits else { return true }
        let alert = NSAlert(); alert.messageText = "保存资料信息的修改？"
        alert.informativeText = "「\(material.title)」有尚未保存的修改。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "不保存"); alert.addButton(withTitle: "取消")
        switch alert.runModal() { case .alertFirstButtonReturn: return save(); case .alertSecondButtonReturn: return true; default: return false }
    }
    private func relink() {
        guard confirmEdits() else { return }
        let panel = NSOpenPanel(); panel.message = material.isManaged ? "选择文件，将其复制回资料库并保留原记录、备注和关联计划" : "重新定位原文件"; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.repository.relinkMaterial(id: material.id, to: url)
            store.reload(); store.status = material.isManaged ? "文件已复制回资料库" : "原文件位置已更新"
        } catch { store.report(error) }
    }
}
