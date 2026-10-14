import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import TeachshelfCore

struct NJUImportSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var importer = NJUWebImporter()
    @ViewState private var showingWeb = false
    @ViewState private var isImporting = false
    @ViewState private var importError: String?
    @ViewState private var warningsExpanded = true
    let onImported: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.plus").font(.title2).foregroundStyle(theme.ink)
                VStack(alignment: .leading, spacing: 3) {
                    Text("导入本科课表").font(.title2.weight(.semibold))
                    Text(importer.schedule == nil ? "南京大学 · 读取课表" : "南京大学 · 核对并导入")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { cancel() }.keyboardShortcut(.cancelAction).disabled(isImporting)
            }.padding(22)
            Divider()

            if let schedule = importer.schedule {
                preview(schedule)
            } else {
                sourceChooser
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let importError { Label(importError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                Text(importer.status).foregroundStyle(.secondary)
            }.font(.caption).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 13)
        }
        .frame(width: 860, height: 620)
        .interactiveDismissDisabled(isImporting)
        .onDisappear { importer.close() }
    }

    private var sourceChooser: some View {
        VStack(spacing: 15) {
            HStack(spacing: 10) {
                Button {
                    showingWeb = true
                    importError = nil
                    importer.openLogin()
                } label: { Label(importer.hasOpenedLogin ? "重新打开学校登录" : "打开学校登录", systemImage: "globe") }
                    .buttonStyle(.bordered).disabled(importer.isReading)
                Button { chooseJSON() } label: { Label("选择 JSON 文件…", systemImage: "doc.badge.arrow.up") }
                    .buttonStyle(.bordered)
                Spacer()
                if showingWeb {
                    if importer.isLoading || importer.isReading { ProgressView().controlSize(.small) }
                    Button("读取当前课表") { importer.readCurrentTimetable() }
                        .appPrimaryButton().disabled(importer.isReading || importer.isLoading || !importer.isTimetablePage)
                }
            }
            if !importer.tableChoices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择要导入的课程表").font(.headline)
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(Array(importer.tableChoices.enumerated()), id: \.element.id) { index, table in
                                Button { importer.readCurrentTimetable(tableID: table.id) } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("课程表 \(index + 1) · \(table.rowCount) 条课程记录").font(.callout.weight(.medium))
                                            Text(table.preview.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(theme.ink)
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(theme.selection, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain).disabled(importer.isReading)
                            }
                        }
                    }.frame(maxHeight: 155)
                }
            }
            if showingWeb {
                NJUOfficialWebView(webView: importer.webView)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary) }
                Text("在官方网页选择学期并切换到课表列表。登录会话仅在本次窗口中保留。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "calendar").font(.system(size: 45, weight: .light)).foregroundStyle(theme.ink)
                    Text("先读取，再核对").font(.title3.weight(.semibold))
                    Text("通过南京大学官方网页登录读取本科课表，\n或选择已有的课表 JSON 文件。预览确认后才会写入资料库。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Text("支持周次、单双周、多时段与自由时间课程。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func preview(_ schedule: UndergraduateSchedule) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(schedule.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text("\(uniqueCourseCount(schedule)) 门课程 · \(schedule.courses.count) 条时段 · \(importer.sourceDescription)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新选择") { importer.returnToSource(); importError = nil }.disabled(isImporting)
            }
            Text("相同学期再次导入时，会更新该学期的课表时段；已有课程、资料和学期日期设置会保留。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !schedule.warnings.isEmpty {
                DisclosureGroup("\(schedule.warnings.count) 条需核对的提示", isExpanded: $warningsExpanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(schedule.warnings.enumerated()), id: \.offset) { _, warning in
                                Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.frame(maxHeight: 95)
                }.padding(11).background(theme.selection, in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(schedule.courses.enumerated()), id: \.offset) { index, course in
                        HStack(alignment: .top, spacing: 14) {
                            Text(String(index + 1)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(course.name).font(.system(size: 13, weight: .semibold))
                                Text([course.teacher, course.classNumber].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 230, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(course.displayPeriod).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.ink)
                                Text(course.weeks.isEmpty ? "周次未指定" : "第 \(weekSummary(course.weeks)) 周")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(course.classroom ?? "地点待定").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 155, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).padding(.horizontal, 10)
                        if index < schedule.courses.count - 1 { Divider() }
                    }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
            HStack {
                Text("导入后可设置第 1 周周一日期与节次作息。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(isImporting ? "正在导入…" : "确认并导入") { confirm(schedule) }
                    .appPrimaryButton().keyboardShortcut(.defaultAction).disabled(isImporting || store.isBusy)
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseJSON() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "选择南京大学本科课表 JSON 文件"
        if panel.runModal() == .OK, let url = panel.url {
            showingWeb = false
            importError = nil
            importer.readJSON(at: url)
        }
    }

    private func confirm(_ schedule: UndergraduateSchedule) {
        guard !isImporting, !store.isBusy, importer.schedule == schedule else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try store.repository.importUndergraduateTimetable(schedule)
            store.reload()
            store.status = "已导入 \(result.meetingsImported) 条课表时段，新增 \(result.coursesCreated) 门课程"
            importer.close()
            dismiss()
            onImported(result.termID)
        } catch { importError = error.localizedDescription }
    }

    private func cancel() { importer.close(); dismiss() }

    private func uniqueCourseCount(_ schedule: UndergraduateSchedule) -> Int {
        Set(schedule.courses.map { ($0.classNumber?.isEmpty == false ? $0.classNumber! : $0.name) }).count
    }

    private func weekSummary(_ weeks: [Int]) -> String {
        let sorted = Array(Set(weeks)).sorted()
        guard let first = sorted.first else { return "" }
        var start = first, end = first, parts: [String] = []
        for value in sorted.dropFirst() {
            if value == end + 1 { end = value }
            else { parts.append(start == end ? "\(start)" : "\(start)–\(end)"); start = value; end = value }
        }
        parts.append(start == end ? "\(start)" : "\(start)–\(end)")
        return parts.joined(separator: "、")
    }
}

private struct NJUOfficialWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
