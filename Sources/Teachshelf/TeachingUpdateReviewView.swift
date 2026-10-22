import SwiftUI
import TeachshelfCore

struct TeachingUpdateReviewView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var controller: TeachingWebsiteController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("更新清单").font(.title3.weight(.semibold))
                Spacer()
                Text("\(controller.proposals.count) 项 · 跳过 \(controller.skippedFiles) 份已有资料").font(.caption).foregroundStyle(.secondary)
            }
            Text("已有文件不重复下载；确认后仅执行勾选项目。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if controller.proposals.isEmpty {
                        Label(controller.messages.contains(where: \.isIssue) ? "暂无可确认项目，请检查下方记录。" : "没有新增内容，已有资料无需重复下载。", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach(controller.reviewSources.filter { source in controller.proposals.contains { $0.connection.id == source.id } }) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.courseName(source.courseID)).font(.callout.weight(.semibold)).padding(.bottom, 4)
                            ForEach(controller.proposals.filter { $0.connection.id == source.id }) { proposal in
                                proposalRow(proposal)
                                Divider()
                            }
                        }
                    }
                    ForEach(controller.messages) { message in
                        Label(message.text, systemImage: message.isIssue ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.caption).foregroundStyle(message.isIssue ? Color.orange : Color.secondary)
                            .textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 12) {
                Button("全选") { controller.selectAllProposals(true) }.buttonStyle(.plain)
                Button("全不选") { controller.selectAllProposals(false) }.buttonStyle(.plain)
                Spacer()
                Text("已选 \(controller.selectedProposalIDs.count) 项").foregroundStyle(.secondary)
            }.font(.caption)
            Divider()
            HStack {
                Button(controller.proposals.isEmpty ? "完成检查" : "暂不更新") { controller.discardReview() }
                Button("重新检查") { controller.check(controller.reviewSources, store: store, global: controller.reviewIsGlobal) }
                Spacer()
                Button("确认更新 \(controller.selectedProposalIDs.count) 项") { controller.applySelected(store: store) }
                    .buttonStyle(.borderedProminent).disabled(controller.selectedProposalIDs.isEmpty)
            }
        }
    }

    private func proposalRow(_ proposal: TeachingUpdateProposal) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: Binding(get: { controller.selectedProposalIDs.contains(proposal.id) }, set: { value in
                if value { controller.selectedProposalIDs.insert(proposal.id) } else { controller.selectedProposalIDs.remove(proposal.id) }
            })) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: proposal.file == nil ? "calendar.badge.clock" : "doc.badge.plus").frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(proposal.title).font(.callout.weight(.medium)).lineLimit(2)
                        Text(proposal.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(proposal.kind).font(.caption).foregroundStyle(proposal.change?.pendingDeadline != nil ? Color.orange : Color.secondary)
                }
            }.toggleStyle(.checkbox)
            if proposal.change?.pendingDeadline != nil {
                Picker("截止时间处理", selection: Binding(get: { controller.adoptWebsiteDeadlineIDs.contains(proposal.id) }, set: { value in
                    if value { controller.adoptWebsiteDeadlineIDs.insert(proposal.id) } else { controller.adoptWebsiteDeadlineIDs.remove(proposal.id) }
                })) {
                    Text("保留本地时间").tag(false)
                    Text("采用网站时间").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.leading, 28)
                    .disabled(!controller.selectedProposalIDs.contains(proposal.id))
            }
        }.padding(.vertical, 7)
    }
}
