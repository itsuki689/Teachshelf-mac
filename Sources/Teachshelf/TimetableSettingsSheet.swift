import AppKit
import SwiftUI
import TeachshelfCore

struct TimetableSettingsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    let term: TimetableTerm
    @ViewState private var hasStartDate: Bool
    @ViewState private var monday: Date
    @ViewState private var weekCount: Int
    @ViewState private var times: [SectionTimeInput]
    @ViewState private var error: String?

    init(term: TimetableTerm) {
        self.term = term
        _hasStartDate = ViewState(initialValue: term.weekOneMonday != nil)
        let calendar = TimetableLayout.academicCalendar
        let today = calendar.startOfDay(for: Date())
        let offset = (calendar.component(.weekday, from: today) + 5) % 7
        _monday = ViewState(initialValue: term.weekOneMonday ?? calendar.date(byAdding: .day, value: -offset, to: today)!)
        _weekCount = ViewState(initialValue: term.weekCount)
        let count = max(12, max(term.meetings.filter(\.isScheduled).map(\.endSection).max() ?? 0, term.sectionTimes.map(\.section).max() ?? 0))
        _times = ViewState(initialValue: (1...count).map { section in
            let saved = term.sectionTimes.first { $0.section == section }
            return SectionTimeInput(section: section, start: saved.map { TimetableLayout.clock($0.startMinute) } ?? "", end: saved.map { TimetableLayout.clock($0.endMinute) } ?? "")
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("学期与作息").font(.title2.weight(.semibold))
                Text(term.name).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            Toggle("设置学期开始日期", isOn: $hasStartDate).tint(theme.controlAccent)
            if hasStartDate {
                DatePicker("第 1 周的周一", selection: $monday, displayedComponents: .date)
                    .environment(\.calendar, TimetableLayout.academicCalendar)
                    .environment(\.timeZone, TimetableLayout.academicCalendar.timeZone)
            }
            Text("设置后可显示实际日期，并在日历中查看上课安排。按南京所在的北京时间计算周次。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Stepper("学期共 \(weekCount) 周", value: $weekCount, in: 1...60)
            Divider()
            HStack {
                Text("每节课的时间").font(.headline)
                Spacer()
                Button("清空") { for index in times.indices { times[index].start = ""; times[index].end = "" } }.buttonStyle(.plain).foregroundStyle(theme.ink)
            }
            Text("填写 24 小时制时间，如 08:00。留空的节次仍按节次显示。").font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 9) {
                    HStack {
                        Text("节次").frame(width: 64, alignment: .leading)
                        Text("开始").frame(maxWidth: .infinity, alignment: .leading)
                        Text("结束").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach($times) { $time in
                        HStack(spacing: 10) {
                            Text("第 \(time.section) 节").frame(width: 64, alignment: .leading)
                            TextField("HH:mm", text: $time.start).monospacedDigit().accessibilityLabel("第\(time.section)节开始时间")
                            Text("–").foregroundStyle(.tertiary)
                            TextField("HH:mm", text: $time.end).monospacedDigit().accessibilityLabel("第\(time.section)节结束时间")
                        }
                    }
                }.padding(.trailing, 4)
            }.padding(.trailing, 4)
            }
            Divider()
            HStack {
                Button("移除此课表…", role: .destructive, action: remove)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存设置", action: save).appPrimaryButton().keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 550, height: 620)
            .alert("无法保存设置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
    }

    private func save() {
        do {
            var edited = term
            edited.weekCount = weekCount
            edited.weekOneMonday = hasStartDate ? TimetableLayout.academicCalendar.startOfDay(for: monday) : nil
            edited.sectionTimes = try times.compactMap { input in
                let start = input.start.trimmingCharacters(in: .whitespacesAndNewlines)
                let end = input.end.trimmingCharacters(in: .whitespacesAndNewlines)
                if start.isEmpty && end.isEmpty { return nil }
                guard let startMinute = Self.parseClock(start), let endMinute = Self.parseClock(end, allowDayEnd: true) else {
                    throw LibraryError.invalidInput("请为第 \(input.section) 节填写完整的开始和结束时间，格式为 HH:mm。")
                }
                return TimetableSectionTime(section: input.section, startMinute: startMinute, endMinute: endMinute)
            }
            try store.repository.saveTimetableTerm(edited)
            store.reload(); store.status = "课表设置已保存"; dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func remove() {
        let alert = NSAlert()
        alert.messageText = "移除「\(term.name)」的课表？"
        alert.informativeText = "仅移除上课时段与学期设置。课程、资料和待办会保留；可重新导入课表。"
        alert.addButton(withTitle: "移除课表"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.repository.deleteTimetableTerm(id: term.id)
            store.reload(); store.status = "已移除课表，课程与资料已保留"; dismiss()
        } catch { self.error = error.localizedDescription }
    }

    static func parseClock(_ text: String, allowDayEnd: Bool = false) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count <= 2, parts[1].count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        if allowDayEnd && hour == 24 && minute == 0 { return 1440 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

private struct SectionTimeInput: Identifiable {
    let section: Int
    var start: String
    var end: String
    var id: Int { section }
}
