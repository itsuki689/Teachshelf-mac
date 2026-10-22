import SwiftUI
import WebKit
import TeachshelfCore

struct TeachingWebsiteSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: TeachingWebsiteController
    @ViewState private var selectedID: UUID?
    @ViewState private var targetCourseID: UUID?
    @ViewState private var remoteInput = "411"
    @ViewState private var timeZone = "Asia/Shanghai"
    @ViewState private var includeHistory = false
    @ViewState private var includeMaterials = true
    @ViewState private var includeAssignments = true
    @ViewState private var includeExperiments = true
    @ViewState private var disconnectID: UUID?

    init(controller: TeachingWebsiteController, initialCourseID: UUID?, connectionID: UUID?) {
        _controller = StateObject(wrappedValue: controller)
        _targetCourseID = ViewState(initialValue: initialCourseID)
        _selectedID = ViewState(initialValue: connectionID)
    }
    private var selected: TeachingConnection? { store.state.teachingConnections.first { $0.id == selectedID } }
    private var working: Bool { controller.updating || controller.reading }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("教学网站").font(.title2.weight(.semibold))
                    Text("南京大学 · 课件、作业与实验").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.updating { Button("取消更新") { controller.cancel() } }
                Button("完成") { controller.suspend(); dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
            }.padding(20)
            TeachingSessionControls(session: controller.client.loginSession).disabled(working)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("已连接课程").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.state.teachingConnections) { connection in
                                Button {
                                    selectedID = connection.id; controller.showWeb = false; controller.preview = nil; controller.messages = []
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(store.courseName(connection.courseID)).font(.callout.weight(.medium)).lineLimit(2)
                                        Text(connection.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未更新")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                                        .background(selectedID == connection.id ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Button { selectedID = nil; controller.preview = nil; controller.showWeb = false; controller.messages = [] } label: {
                        Label("连接课程", systemImage: "plus")
                    }.buttonStyle(.bordered)
                }.padding(16).frame(width: 225).disabled(working)
                Divider()
                VStack(spacing: 14) {
                    if let selected { connectedHeader(selected) } else { connectionHeader }
                    if controller.showWeb {
                        TeachingLoginView(client: controller.client).allowsHitTesting(!controller.updating).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if selected == nil {
                        if let preview = controller.preview { previewView(preview) }
                        else {
                            EmptyStateView(symbol: "globe", title: "连接课程，之后一键更新", detail: "在学校官方网页完成登录，打开课程首页后读取。已有的本地课程、资料和计划会保留。")
                        }
                    } else if let selected { resultsView(selected) }
                }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 9) {
                if working { ProgressView().controlSize(.small) }
                Text(controller.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 44)
        }.frame(width: 1000, height: 660)
            .interactiveDismissDisabled(working)
            .onDisappear { controller.suspend() }
            .confirmationDialog("断开连接？资料、计划和文件会保留。", isPresented: Binding(get: { disconnectID != nil }, set: { if !$0 { disconnectID = nil } })) {
                Button("断开连接", role: .destructive) {
                    if let id = disconnectID { store.perform { try store.repository.disconnectTeachingWebsite(id) }; selectedID = nil }
                    disconnectID = nil
                }
            }
    }
    private var connectionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("课程链接或编号", text: $remoteInput).textFieldStyle(.roundedBorder)
                Button("打开学校登录") {
                    let input = remoteInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let id = TeachingWebsite.identifier(URL(string: input)) ?? input
                    guard !id.isEmpty, id.count <= 16, id.allSatisfy(\.isNumber) else { controller.status = "请输入教学网站课程链接或数字编号。"; return }
                    controller.openCourse(id)
                }.disabled(working)
                Button("读取当前课程") { controller.readCourse() }
                    .disabled(working || controller.client.webView.url == nil)
            }
            if controller.preview != nil {
                HStack {
                    Text("已读取课程，可核对后连接。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(controller.showWeb ? "查看连接预览" : "返回网页") { controller.showWeb.toggle() }.buttonStyle(.plain)
                }
            }
        }
    }
    private func previewView(_ page: TeachingPage) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(page.title).font(.title3.weight(.semibold))
            HStack {
                Text("绑定本地课程").font(.callout)
                SolidChoiceMenu("绑定本地课程", selection: $targetCourseID,
                    options: [ChoiceOption<UUID?>(value: nil, title: "选择课程")] + store.state.courses.filter { !$0.isArchived }.map {
                        ChoiceOption(value: Optional($0.id), title: [$0.name, $0.semester].filter { !$0.isEmpty }.joined(separator: " · "))
                    })
            }
            HStack {
                Text("网页时间使用").font(.callout)
                SolidChoiceMenu("网页时间使用", selection: $timeZone, options: [ChoiceOption(value: "Asia/Shanghai", title: "北京时间（Asia/Shanghai）"), ChoiceOption(value: "UTC", title: "UTC")])
            }
            HStack {
                Toggle("课件", isOn: $includeMaterials)
                Toggle("作业", isOn: $includeAssignments)
                Toggle("实验", isOn: $includeExperiments)
            }.toggleStyle(.checkbox)
            Toggle("同时导入已过期或已提交的历史作业", isOn: $includeHistory).toggleStyle(.checkbox)
            Text("作业按固定计划导入；明确的截止时间自动生成 DDL。网站没有执行时段时，不自动安排执行时间。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(page.activities) { activity in
                        HStack {
                            Image(systemName: activity.kind == "assign" ? "checklist" : "folder")
                            Text(activity.title).lineLimit(2)
                            Spacer(); Text(activity.section).foregroundStyle(.secondary)
                        }.font(.caption).padding(.vertical, 4)
                    }
                }
            }.frame(maxHeight: .infinity)
            HStack {
                Text("\(page.activities.count) 个条目 · 文件将归入「教学网站」文件夹").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("确认连接") {
                    guard let targetCourseID else { return }
                    var connection = TeachingConnection(courseID: targetCourseID, remoteCourseID: page.courseID, remoteTitle: page.title, accountID: page.accountID, timeZone: timeZone)
                    connection.includeHistory = includeHistory; connection.includeMaterials = includeMaterials
                    connection.includeAssignments = includeAssignments; connection.includeExperiments = includeExperiments
                    do {
                        try store.repository.saveTeachingConnection(connection); store.reload(); selectedID = connection.id
                        controller.preview = nil; controller.showWeb = false; controller.status = "连接已保存，点击「更新」开始下载与导入。"
                    } catch { controller.status = error.localizedDescription }
                }.appPrimaryButton().disabled(!store.state.courses.contains { $0.id == targetCourseID && !$0.isArchived } || (!includeMaterials && !includeAssignments && !includeExperiments))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func connectedHeader(_ connection: TeachingConnection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.remoteTitle).font(.headline).lineLimit(1)
                    Text("绑定到 \(store.courseName(connection.courseID))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("登录／查看来源") { controller.openCourse(connection.remoteCourseID) }.disabled(working)
                Button { controller.update(connection, store: store) } label: { Label("更新", systemImage: "arrow.clockwise") }
                    .appPrimaryButton().disabled(working || store.state.courses.first { $0.id == connection.courseID }?.isArchived == true)
                Menu {
                    Toggle("同步课件", isOn: option(connection, \.includeMaterials))
                    Toggle("同步作业", isOn: option(connection, \.includeAssignments))
                    Toggle("同步实验", isOn: option(connection, \.includeExperiments))
                    Toggle("包含历史作业", isOn: option(connection, \.includeHistory))
                    Divider()
                    Button("重新加入已忽略的条目") { store.perform { try store.repository.restoreIgnoredTeachingItems(connection.id) } }
                    Button("断开连接…", role: .destructive) { disconnectID = connection.id }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22).disabled(working)
            }
            if controller.showWeb { Button("返回更新记录") { controller.showWeb = false }.buttonStyle(.plain).font(.caption).disabled(working) }
        }
    }
    private func option(_ connection: TeachingConnection, _ key: WritableKeyPath<TeachingConnection, Bool>) -> Binding<Bool> {
        Binding(get: { connection[keyPath: key] }, set: { value in
            var edited = connection; edited[keyPath: key] = value
            store.perform { try store.repository.saveTeachingConnection(edited) }
        })
    }
    private func resultsView(_ connection: TeachingConnection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(connection.items.filter { $0.pendingDeadline != nil }) { link in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(link.title).font(.callout.weight(.semibold))
                        Text("网站截止时间：\(link.pendingDeadline?.text.isEmpty == false ? link.pendingDeadline!.text : "未设置")").font(.caption)
                        Text("本地：\(store.state.tasks.first { $0.id == link.localID }?.deadline?.formatted(date: .abbreviated, time: .shortened) ?? "未设置")").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("采用网站时间") { resolve(connection.id, link.id, true) }
                            Button("保留本地时间") { resolve(connection.id, link.id, false) }
                        }.disabled(working)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                let messages = controller.messages.isEmpty ? connection.messages : controller.messages
                if messages.isEmpty {
                    Label("点击更新，检查最新课件和作业。", systemImage: "arrow.clockwise").foregroundStyle(.secondary).padding(.top, 55)
                } else {
                    ForEach(messages) { message in
                        Label(message.text, systemImage: message.isIssue ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.caption).foregroundStyle(message.isIssue ? Color.orange : Color.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func resolve(_ connectionID: UUID, _ key: String, _ useWebsite: Bool) {
        store.perform { try store.repository.resolveTeachingDeadline(connectionID: connectionID, key: key, useWebsite: useWebsite) }
    }
}

private struct TeachingSessionControls: View {
    @ObservedObject var session: TeachingLoginSession
    var body: some View {
        HStack(spacing: 12) {
            Toggle("记住此设备登录", isOn: Binding(get: { session.enabled }, set: { session.setEnabled($0) })).toggleStyle(.checkbox)
                .help("只将教学网站会话保存在本机钥匙串，恢复有效期最多 7 天。学校会话过期仍需登录；关闭会清除保存的会话，当前网页登录保留。")
            Text(session.status).font(.caption).foregroundStyle(session.hasIssue ? Color.orange : Color.secondary).lineLimit(2)
            Spacer(minLength: 0)
            if session.hasIssue { Button("重试钥匙串") { session.retry() }.controlSize(.small) }
        }.padding(.horizontal, 20).padding(.bottom, 14)
    }
}

private struct TeachingLoginView: View {
    @ObservedObject var client: TeachingWebClient
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                if client.loading { ProgressView().controlSize(.small) }
                Text(client.address.isEmpty ? "南京大学官方网页" : client.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(client.loginState.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            TeachingOfficialWebView(webView: client.webView).overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
            Text(client.notice).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TeachingOfficialWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
