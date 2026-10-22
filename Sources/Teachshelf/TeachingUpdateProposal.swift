import Foundation
import TeachshelfCore

struct TeachingUpdateProposal: Identifiable {
    let connection: TeachingConnection
    let activity: TeachingActivity
    let file: TeachingFile?
    let page: TeachingPage?
    let before: StudyTask?
    let change: TeachingAssignmentChange?
    var repair = false
    var id: String { connection.id.uuidString + ":" + (file.map { "file:\(activity.key):\($0.key)" } ?? "plan:\(activity.id)") }
    var title: String { file?.name ?? activity.title }
    var kind: String {
        if file != nil { return repair ? "补下载" : "新增文件" }
        if change?.pendingDeadline != nil { return "截止时间冲突" }
        return before == nil ? "新增计划" : "更新计划"
    }
    var detail: String {
        if let file {
            let folder = ([activity.section, activity.title] + file.subfolders).joined(separator: " / ")
            return repair ? "本地副本缺失，可选择重新下载 · " + folder : folder
        }
        guard let change else { return "关联新增或尚未关联的作业附件" }
        let old = before?.deadline
        let new = change.pendingDeadline.map(\.date) ?? change.proposed.deadline
        func date(_ value: Date?, allDay: Bool) -> String {
            guard let value else { return "无截止时间" }
            let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: connection.timeZone)
            formatter.dateFormat = allDay ? "yyyy-MM-dd（全天）" : "yyyy-MM-dd HH:mm"
            return formatter.string(from: value)
        }
        let deadline = date(new, allDay: change.pendingDeadline?.allDay ?? change.proposed.deadlineIsAllDay)
        if let before, old != new || before.deadlineIsAllDay != (change.pendingDeadline?.allDay ?? change.proposed.deadlineIsAllDay) {
            return "截止：\(date(old, allDay: before.deadlineIsAllDay)) → \(deadline)"
        }
        if change.message.contains("待核对") { return change.message }
        return before == nil ? "固定计划 · \(deadline)" : "更新作业信息与附件 · \(deadline)"
    }
}
