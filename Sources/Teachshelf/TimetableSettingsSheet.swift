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
    @ViewState private var hasEndDate: Bool
    @ViewState private var endDate: Date
    @ViewState private var referenceDate: Date
    @ViewState private var referenceWeek: Int
    @ViewState private var times: [SectionTimeInput]
    @ViewState private var cancellations: [TimetableCancellation]
    @ViewState private var reschedules: [TimetableReschedule]
    @ViewState private var error: String?

    init(term: TimetableTerm) {
        self.term = term
        _hasStartDate = ViewState(initialValue: term.weekOneMonday != nil)
        let calendar = TimetableLayout.academicCalendar
        let today = calendar.startOfDay(for: Date())
        let offset = (calendar.component(.weekday, from: today) + 5) % 7
        _monday = ViewState(initialValue: term.weekOneMonday ?? calendar.date(byAdding: .day, value: -offset, to: today)!)
        _weekCount = ViewState(initialValue: term.weekCount)
        _hasEndDate = ViewState(initialValue: term.endDate != nil)
        _endDate = ViewState(initialValue: term.endDate ?? calendar.date(byAdding: .day, value: (term.weekCount - 1) * 7 + 4,
            to: term.weekOneMonday ?? today) ?? today)
        _referenceDate = ViewState(initialValue: today)
        _referenceWeek = ViewState(initialValue: term.week(containing: today) ?? 1)
        _cancellations = ViewState(initialValue: term.cancellations)
        _reschedules = ViewState(initialValue: term.reschedules)
        let count = TimetableLayout.sectionCount(in: term)
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
            Text("设置后可在日程的三种视图中同步查看课程与待办。按南京所在的北京时间计算周次。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("按已知日期和周次推算") {
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker("参考日期", selection: $referenceDate, displayedComponents: .date)
                        .environment(\.calendar, TimetableLayout.academicCalendar)
                        .environment(\.timeZone, TimetableLayout.academicCalendar.timeZone)
                    HStack {
                        Stepper("该日期是第 \(referenceWeek) 周", value: $referenceWeek, in: 1...60)
                            .accessibilityLabel("参考周次")
                        Spacer(minLength: 12)
                        Button("应用推算日期") {
                            if let inferred = TimetableTerm.firstMonday(referenceDate: referenceDate, academicWeek: referenceWeek) {
                                monday = inferred; hasStartDate = true
                            }
                        }.buttonStyle(.bordered)
                    }
                    if let inferred = TimetableTerm.firstMonday(referenceDate: referenceDate, academicWeek: referenceWeek) {
                        Text("第 1 周周一：\(TimetableCalendar.formatted(inferred, template: "yMMMd"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 8)
            }
            Stepper("学期共 \(weekCount) 周", value: $weekCount, in: 1...60)
            Toggle("设置学期结束日期", isOn: $hasEndDate)
                .onChange(of: hasEndDate) { _, enabled in
                    if enabled, term.endDate == nil { updateDefaultEndDate() }
                }
            if hasEndDate {
                DatePicker("最后上课日期（含当天）", selection: $endDate, displayedComponents: .date)
                    .environment(\.calendar, TimetableLayout.academicCalendar)
                    .environment(\.timeZone, TimetableLayout.academicCalendar.timeZone)
                Text("结束日期之后不再显示课程，个人待办可继续安排。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            rescheduleRecords
            if !cancellations.isEmpty {
                DisclosureGroup("停课记录 · \(cancellations.count) 次") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(cancellations.sorted { $0.date > $1.date }) { cancellation in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cancellation.title).font(.callout.weight(.medium))
                                    Text(TimetableCalendar.formatted(cancellation.date, template: "yMMMdEEEE"))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !cancellation.reason.isEmpty {
                                        Text(cancellation.reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button("恢复") { restoreCancellation(cancellation) }
                                    .buttonStyle(.bordered).accessibilityLabel("恢复 \(cancellation.title) \(TimetableCalendar.formatted(cancellation.date, template: "MMMd")) 的课程")
                            }
                        }
                        Text("恢复后保存设置，即可重新显示该次课程。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }
            Divider()
            HStack {
                Text("每节课的时间").font(.headline)
                Spacer()
                Button("填入本科作息", action: applyUndergraduateTimes).buttonStyle(.bordered)
                Button("清空") { for index in times.indices { times[index].start = ""; times[index].end = "" } }.buttonStyle(.plain).foregroundStyle(theme.ink)
            }
            Text("本科作息按提供的截图整理，共 11 节，可逐节修改。填写 24 小时制时间；留空的节次仍按节次显示。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Button {
                        times.append(SectionTimeInput(section: (times.last?.section ?? 0) + 1, start: "", end: ""))
                    } label: { Label("添加节次", systemImage: "plus") }
                        .buttonStyle(.borderless).disabled((times.last?.section ?? 0) >= 30)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
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

    @ViewBuilder private var rescheduleRecords: some View {
        if !reschedules.isEmpty {
            DisclosureGroup("临时调课 · \(reschedules.count) 次") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(reschedules.sorted { $0.date < $1.date }) { change in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.meeting.title).font(.callout.weight(.medium))
                                Text("\(TimetableCalendar.formatted(change.originalDate, template: "MMMd")) → \(TimetableCalendar.formatted(change.date, template: "MMMdEEEE")) · \(TimetableLayout.sectionLabel(change.meeting))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !term.meetings.contains(where: { $0.id == change.meetingID }) {
                                    Text("原时段已不在来源课表中，这次临时安排仍单独保留。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(term.meetings.contains(where: { $0.id == change.meetingID }) ? "恢复原安排" : "移除临时安排") {
                                reschedules.removeAll { $0.id == change.id }
                            }.buttonStyle(.bordered)
                        }
                    }
                    Text("修改后保存设置生效。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }
    }

    private func updateDefaultEndDate() {
        if let date = TimetableLayout.academicCalendar.date(byAdding: .day, value: (weekCount - 1) * 7 + 4, to: monday) {
            endDate = date
        }
    }

    private func restoreCancellation(_ cancellation: TimetableCancellation) {
        if let saved = cancellation.savedReschedule, !reschedules.contains(where: { $0.id == saved.id }) {
            reschedules.append(saved)
        }
        cancellations.removeAll { $0.id == cancellation.id }
    }

    private func applyUndergraduateTimes() {
        for index in times.indices {
            if let time = UndergraduateTimetableDefaults.sectionTimes.first(where: { $0.section == times[index].section }) {
                times[index].start = TimetableLayout.clock(time.startMinute)
                times[index].end = TimetableLayout.clock(time.endMinute)
            }
        }
    }

    private func save() {
        do {
            var edited = term
            edited.weekCount = weekCount
            edited.endDate = hasEndDate ? TimetableLayout.academicCalendar.startOfDay(for: endDate) : nil
            edited.cancellations = cancellations
            edited.reschedules = reschedules
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
            if store.changeTimetable(termID: term.id, label: "更新学期设置", action: { try $0.saveTimetableTerm(edited) }) { dismiss() }
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
