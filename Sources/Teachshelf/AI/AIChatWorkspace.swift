import SwiftUI
import TeachshelfCore

struct AIChatWorkspace: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @ObservedObject var controller: AIChatController
    @ViewState private var input = ""
    @ViewState private var showingConfiguration = false
    private let examples = ["今天有哪些待完成的计划？", "每门课程各有多少份资料？", "帮我整理当前课程的资料分类"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI 助手").font(.title3.weight(.semibold))
                    Text(controller.configuration.isConfigured ? controller.configuration.model : "连接模型，用自然语言管理课屿")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("新对话", systemImage: "square.and.pencil") { controller.reset() }.disabled(controller.isRunning)
                Button("模型设置", systemImage: "slider.horizontal.3") { showingConfiguration = true }.disabled(controller.isRunning)
            }.padding(20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if controller.items.isEmpty { welcome }
                        ForEach(controller.items) { item in message(item) }
                        if controller.isRunning {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(controller.progress).font(.caption).foregroundStyle(.secondary) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: 800).frame(maxWidth: .infinity).padding(24)
                }
                .onChange(of: controller.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: controller.pending?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingConfiguration) { AIConfigurationSheet(controller: controller) }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("把想做的事告诉课屿").font(.system(size: 25, weight: .semibold))
                Text("查询课程与资料、安排计划，或调整文件夹。修改前先确认，结果会同步到资料库。")
                    .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !controller.configuration.isConfigured {
                SettingsCard {
                    HStack(spacing: 16) {
                        SettingsIcon(symbol: "network")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("先连接一个模型").font(.headline)
                            Text("支持云端 API 和你部署的本地模型服务。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("设置模型") { showingConfiguration = true }.buttonStyle(.borderedProminent)
                    }.padding(20)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("可以这样开始").font(.caption).foregroundStyle(.secondary)
                ForEach(examples, id: \.self) { example in
                    Button { input = example } label: {
                        HStack { Text(example); Spacer(); Image(systemName: "arrow.up.left") }
                            .font(.system(size: 13)).padding(14).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            SettingsNote(text: "发送后，对话和工具查询得到的课程、计划、资料元数据会传给所选模型服务。文件正文不会发送。对话仅保留在本次应用会话中。")
        }.padding(.vertical, 28)
    }
    @ViewBuilder private func message(_ item: AIChatItem) -> some View {
        switch item.kind {
        case .user:
            HStack { Spacer(minLength: 60); Text(item.text).textSelection(.enabled).padding(14).background(theme.selection, in: RoundedRectangle(cornerRadius: 14)) }
        case .assistant:
            VStack(alignment: .leading, spacing: 7) {
                Text("课屿助手").font(.caption.weight(.semibold)).foregroundStyle(theme.ink)
                Text(item.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        case .notice:
            Label(item.text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        case .operation:
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Image(systemName: "wrench.and.screwdriver").foregroundStyle(theme.ink); Text(item.text).font(.headline); Spacer(); Text(item.outcome).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if controller.pending?.id == item.id {
                        HStack {
                            Text("确认后才会修改本机资料库").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("拒绝") { controller.decide(false) }
                            Button("确认执行") { controller.decide(true) }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                        }
                    }
                    if !item.links.isEmpty {
                        ForEach(item.links) { link in
                            Button { _ = store.activateSearchResult(WorkspaceSearchResult(kind: link.kind, recordID: link.id, title: link.title, detail: "", colorHex: store.state.accentColor)) } label: {
                                Label(link.title, systemImage: "arrow.up.right.square").lineLimit(2)
                            }.buttonStyle(.link).disabled(controller.isRunning || store.isBusy)
                        }
                    }
                    if item.undoArguments != nil {
                        Button("撤销这次计划修改", systemImage: "arrow.uturn.backward") { controller.undo(item) }.disabled(controller.isRunning || store.isBusy)
                    }
                }.padding(16)
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(controller.contextLabel, systemImage: "scope").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if controller.contextCourseID != nil || !controller.contextMaterialIDs.isEmpty {
                    Button("清除上下文") { controller.clearContext() }.buttonStyle(.link).font(.caption).disabled(controller.isRunning)
                }
                Spacer()
                Text("⌘ Return 发送").font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("例如：把明天的复习计划改到晚上七点", text: $input, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...5).padding(12)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("给 AI 助手的消息")
                if controller.isRunning {
                    Button("停止", systemImage: "stop.fill") { controller.stop() }.controlSize(.large)
                } else {
                    Button("发送", systemImage: "arrow.up") { send() }.buttonStyle(.borderedProminent)
                        .controlSize(.large).keyboardShortcut(.return, modifiers: .command)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controller.configuration.isConfigured || store.isBusy)
                }
            }
            Text("修改以操作卡片的实际结果为准。模型可能出错，请核对名称、日期和作用范围。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(20)
    }
    private func send() { let value = input; input = ""; controller.send(value) }
}
