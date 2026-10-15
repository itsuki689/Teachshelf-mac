import SwiftUI
import TeachshelfCore

private enum ScheduleEditScope: String, CaseIterable {
    case occurrence = "仅这次课"
    case weekly = "每周时段"

    var removeTitle: String { self == .occurrence ? "移除本次" : "移除此时段" }
}

private struct ScheduleEditDraft {
    var date: Date
    var weekday: Int
    var startSection: Int
    var sectionCount: Int
    var classroom: String
    var weeks: Set<Int>
}

struct ScheduleEditSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    let context: ScheduleMeetingContext
    var onSaved: () -> Void = {}
    @ViewState private var scope: ScheduleEditScope
    @ViewState private var occurrenceDraft: ScheduleEditDraft
    @ViewState private var weeklyDraft: ScheduleEditDraft
    @ViewState private var confirmingRemoval = false
    private let calendar = TimetableTerm.academicCalendar

    init(context: ScheduleMeetingContext, onSaved: @escaping () -> Void = {}) {
        self.context = context
        self.onSaved = onSaved
        let date = TimetableTerm.academicCalendar.startOfDay(for: context.date ?? context.selectedDate)
        let master = context.term.meetings.first { $0.id == context.meeting.id } ?? context.meeting
        let weekCount = max(1, min(60, context.term.weekCount))
        func draft(for meeting: TimetableMeeting, assignFreeTime: Bool) -> ScheduleEditDraft {
            let start = meeting.isScheduled ? min(30, max(1, meeting.startSection)) : 1
            let count = meeting.isScheduled ? min(31 - start, max(1, meeting.sectionCount)) : 1
            let weeks = !meeting.isScheduled && assignFreeTime
                ? Set(1...weekCount) : Set(meeting.weeks)
            return ScheduleEditDraft(date: date, weekday: min(7, max(1, meeting.weekday ?? 1)),
                                     startSection: start, sectionCount: count,
                                     classroom: meeting.classroom, weeks: weeks)
        }
        _scope = ViewState(initialValue: context.date == nil ? .weekly : .occurrence)
        _occurrenceDraft = ViewState(initialValue: draft(for: context.meeting, assignFreeTime: false))
        _weeklyDraft = ViewState(initialValue: draft(for: master, assignFreeTime: true))
    }

    private var currentTerm: TimetableTerm? {
        store.state.timetableTerms.first { $0.id == context.term.id }
    }

    private var sourceMeeting: TimetableMeeting? {
        currentTerm?.meetings.first { $0.id == context.meeting.id }
    }

    private var sourceDate: Date? { context.originalDate ?? context.date }
    private var draft: ScheduleEditDraft { scope == .occurrence ? occurrenceDraft : weeklyDraft }
    private var weekCount: Int { max(1, min(60, currentTerm?.weekCount ?? context.term.weekCount)) }
    private var canEditScope: Bool { scope == .occurrence ? sourceDate != nil : sourceMeeting != nil }
    private var canSave: Bool {
        canEditScope && (1...30).contains(draft.startSection)
            && (1...(31 - draft.startSection)).contains(draft.sectionCount)
            && (scope == .occurrence || !draft.weeks.isEmpty)
            && (scope != .occurrence || currentTerm?.week(containing: draft.date) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("调整课程安排").font(.title2.weight(.semibold))
                Text(context.meeting.title).font(.headline).lineLimit(2)
                Text(context.term.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    scopeControl
                    scopeExplanation
                    VStack(alignment: .leading, spacing: 15) {
                        if scope == .occurrence {
                            DatePicker("调整到", selection: dateBinding, displayedComponents: .date)
                                .datePickerStyle(.field)
                            if currentTerm?.week(containing: occurrenceDraft.date) == nil {
                                Text("请选择学期范围内的日期。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Picker("上课日", selection: weekdayBinding) {
                                ForEach(1...7, id: \.self) { day in
                                    Text("星期\(["一", "二", "三", "四", "五", "六", "日"][day - 1])").tag(day)
                                }
                            }.pickerStyle(.menu)
                        }
                        HStack(spacing: 20) {
                            Stepper("第 \(draft.startSection) 节开始", value: startBinding, in: 1...30)
                                .accessibilityLabel("起始节次")
                            Stepper("连续 \(draft.sectionCount) 节", value: countBinding, in: 1...(31 - draft.startSection))
                                .accessibilityLabel("持续节数")
                        }
                        Text("第 \(draft.startSection)\(draft.sectionCount == 1 ? "" : "–\(draft.startSection + draft.sectionCount - 1)") 节")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("教室") {
                            TextField("教室", text: classroomBinding, prompt: Text("可留空"))
                                .textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel("教室")
                        }
                    }.disabled(!canEditScope)
                    if scope == .weekly { weekSelection.disabled(!canEditScope) }
                }.padding(.trailing, 4).padding(.bottom, 4)
            }
            Divider()
            HStack(spacing: 12) {
                Button(scope.removeTitle + "…", role: .destructive) { confirmingRemoval = true }
                    .disabled(!canEditScope || store.isBusy)
                Spacer(minLength: 8)
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存调整", action: save).appPrimaryButton().keyboardShortcut(.defaultAction)
                    .disabled(!canSave || store.isBusy)
            }
        }
        .padding(24)
        .frame(minWidth: 440, idealWidth: 550, maxWidth: 550,
               minHeight: 460, idealHeight: 620, maxHeight: 620)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .confirmationDialog(scope == .occurrence ? "移除这次课程？" : "移除此每周时段？",
                            isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(scope.removeTitle, role: .destructive, action: remove)
            Button("取消", role: .cancel) {}
        } message: {
            Text(scope == .occurrence
                 ? "只取消这一次上课，其他周次保持原安排。可在日程中撤销。"
                 : "移除此时段及其临时调整。课程、资料和计划会保留。可在日程中撤销。")
        }
    }

    private var scopeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("调整范围").font(.callout.weight(.medium))
            if context.date == nil {
                Text("每周时段").font(.callout).foregroundStyle(theme.ink)
            } else {
                Picker("调整范围", selection: $scope) {
                    Text(ScheduleEditScope.occurrence.rawValue).tag(ScheduleEditScope.occurrence)
                    Text(ScheduleEditScope.weekly.rawValue).tag(ScheduleEditScope.weekly).disabled(sourceMeeting == nil)
                }.labelsHidden().pickerStyle(.segmented)
            }
            if sourceMeeting == nil {
                Text(sourceDate == nil ? "原每周时段已移除，请返回日程选择具体一次课程。" : "原每周时段已移除，目前只能调整这次课。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var scopeExplanation: some View {
        VStack(alignment: .leading, spacing: 7) {
            if scope == .occurrence {
                if let date = sourceDate {
                    Label("原日期：\(TimetableCalendar.formatted(date, template: "yMMMdEEEE"))", systemImage: "calendar")
                        .font(.callout)
                }
                Text("只调整本次上课的日期、节次和教室，其他周次仍使用原时段。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("调整所选周次的固定时段。已单独调整或取消的课程保持各自的安排。")
                    .font(.caption).foregroundStyle(.secondary)
                if !context.meeting.isScheduled {
                    Text("这门课原为自由时间；选择星期、节次和周次后，会显示在课表中。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var weekSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("上课周次").font(.callout.weight(.medium))
                Text("已选 \(weeklyDraft.weeks.count) 周").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("全选") { weeklyDraft.weeks = Set(1...weekCount) }.buttonStyle(.borderless)
                Button("清空") { weeklyDraft.weeks.removeAll() }.buttonStyle(.borderless)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 8), spacing: 7) {
                ForEach(1...weekCount, id: \.self) { week in
                    let selected = weeklyDraft.weeks.contains(week)
                    Button {
                        if selected { weeklyDraft.weeks.remove(week) } else { weeklyDraft.weeks.insert(week) }
                    } label: {
                        Text("\(week)").font(.callout.monospacedDigit())
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .foregroundStyle(selected ? theme.ink : Color.secondary)
                            .background(selected ? theme.selection : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                            .overlay { if selected { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.selectionBorder, lineWidth: 1) } }
                    }.buttonStyle(.plain)
                        .accessibilityLabel("第 \(week) 周")
                        .accessibilityValue(selected ? "已选择" : "未选择")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if weeklyDraft.weeks.isEmpty {
                Text("至少选择一个上课周次后才能保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { occurrenceDraft.date }, set: { occurrenceDraft.date = calendar.startOfDay(for: $0) })
    }

    private var weekdayBinding: Binding<Int> {
        Binding(get: { weeklyDraft.weekday }, set: { weeklyDraft.weekday = $0 })
    }

    private var classroomBinding: Binding<String> {
        Binding(get: { draft.classroom }, set: { newValue in
            if scope == .occurrence { occurrenceDraft.classroom = newValue } else { weeklyDraft.classroom = newValue }
        })
    }

    private var startBinding: Binding<Int> {
        Binding(get: { draft.startSection }, set: { newValue in
            let start = min(30, max(1, newValue))
            if scope == .occurrence {
                occurrenceDraft.startSection = start
                occurrenceDraft.sectionCount = min(occurrenceDraft.sectionCount, 31 - start)
            } else {
                weeklyDraft.startSection = start
                weeklyDraft.sectionCount = min(weeklyDraft.sectionCount, 31 - start)
            }
        })
    }

    private var countBinding: Binding<Int> {
        Binding(get: { draft.sectionCount }, set: { newValue in
            let count = min(31 - draft.startSection, max(1, newValue))
            if scope == .occurrence { occurrenceDraft.sectionCount = count } else { weeklyDraft.sectionCount = count }
        })
    }

    private func save() {
        guard canSave else { return }
        let succeeded: Bool
        if scope == .occurrence {
            guard let original = sourceDate else { return }
            let input = occurrenceDraft
            succeeded = store.changeTimetable(termID: context.term.id, label: "调整本次课程") { repository in
                try repository.rescheduleTimetableClass(termID: context.term.id, meetingID: context.meeting.id,
                                                       originalDate: original, to: input.date,
                                                       startSection: input.startSection, sectionCount: input.sectionCount,
                                                       classroom: input.classroom.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            guard var meeting = sourceMeeting else { return }
            meeting.weekday = weeklyDraft.weekday
            meeting.startSection = weeklyDraft.startSection
            meeting.sectionCount = weeklyDraft.sectionCount
            meeting.classroom = weeklyDraft.classroom.trimmingCharacters(in: .whitespacesAndNewlines)
            meeting.weeks = weeklyDraft.weeks.sorted()
            succeeded = store.changeTimetable(termID: context.term.id, label: "调整每周时段") { repository in
                try repository.updateTimetableMeeting(termID: context.term.id, meeting: meeting)
            }
        }
        if succeeded {
            if scope == .occurrence { store.scheduleSelection.setDate(occurrenceDraft.date) }
            dismiss(); onSaved()
        }
    }

    private func remove() {
        guard canEditScope else { return }
        let succeeded: Bool
        if scope == .occurrence {
            guard let original = sourceDate else { return }
            succeeded = store.changeTimetable(termID: context.term.id, label: "移除本次课程") { repository in
                try repository.cancelTimetableClass(termID: context.term.id, meetingID: context.meeting.id, on: original)
            }
        } else {
            succeeded = store.changeTimetable(termID: context.term.id, label: "移除每周时段") { repository in
                try repository.deleteTimetableMeeting(termID: context.term.id, meetingID: context.meeting.id)
            }
        }
        if succeeded { dismiss(); onSaved() }
    }
}
