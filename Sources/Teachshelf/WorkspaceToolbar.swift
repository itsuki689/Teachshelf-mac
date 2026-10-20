import SwiftUI

extension View {
    @ViewBuilder func workspaceWindowTitle(_ title: String) -> some View {
        if #available(macOS 15.0, *) {
            navigationTitle(title).toolbar(removing: .title)
        } else {
            navigationTitle("课屿")
        }
    }
}

struct WorkspaceSearchPopover: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @ViewState private var query = ""
    @ViewState private var selectedID: String?
    private var results: [WorkspaceSearchResult] { WorkspaceSearch.results(for: query, in: store.state) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("名称、标签、备注或地点", text: $query).textFieldStyle(.plain)
                    .focused($focused).accessibilityLabel("全局搜索关键词")
                    .onSubmit { activateSelected() }
                if !query.isEmpty {
                    Button { query = ""; focused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除全局搜索")
                }
            }.font(.system(size: 15)).padding(18)
            Divider()
            if results.isEmpty {
                VStack(spacing: 8) {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "搜索整个资料库" : "没有匹配结果")
                        .font(.headline)
                    Text(query.isEmpty ? "跨课程查找资料，也能直接打开计划。" : "尝试缩短关键词，或使用空格组合多个词。")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 148)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(WorkspaceSearchKind.allCases) { kind in
                                let matches = results.filter { $0.kind == kind }
                                if !matches.isEmpty {
                                    Text(kind.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                                    ForEach(matches) { result in resultRow(result).id(result.id) }
                                }
                            }
                        }.padding(8)
                    }.frame(height: min(390, CGFloat(results.count) * 57 + CGFloat(Set(results.map(\.kind)).count) * 30 + 16))
                        .onChange(of: selectedID) { _, id in
                            if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                        }
                }
            }
            Divider()
            HStack {
                Text("当前资料库").lineLimit(1)
                Spacer()
                Text("↑↓ 选择    ↩ 打开    esc 关闭")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10)
        }.frame(width: 460)
            .onAppear { focused = true }
            .onChange(of: query) { _, _ in selectedID = results.first?.id }
            .onChange(of: results.map(\.id)) { _, ids in if !ids.contains(selectedID ?? "") { selectedID = ids.first } }
            .onKeyPress(.downArrow) { moveSelection(1) }
            .onKeyPress(.upArrow) { moveSelection(-1) }
            .onExitCommand { store.showingWorkspaceSearch = false }
    }

    private func resultRow(_ result: WorkspaceSearchResult) -> some View {
        Button { store.activateSearchResult(result) } label: {
            HStack(spacing: 12) {
                Image(systemName: result.kind.symbol).font(.system(size: 18)).foregroundStyle(Color(hex: result.colorHex))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !result.detail.isEmpty { Text(result.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if selectedID == result.id { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).frame(height: 53)
                .background(selectedID == result.id ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel("\(result.kind.rawValue)：\(result.title)，\(result.detail)")
    }

    private func moveSelection(_ offset: Int) -> KeyPress.Result {
        let results = results
        guard !results.isEmpty else { return .ignored }
        let index = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : results.count)
        selectedID = results[min(max(index + offset, 0), results.count - 1)].id
        return .handled
    }

    private func activateSelected() {
        if let result = results.first(where: { $0.id == selectedID }) ?? results.first { store.activateSearchResult(result) }
    }
}
