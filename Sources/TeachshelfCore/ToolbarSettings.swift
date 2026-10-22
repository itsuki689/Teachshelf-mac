import Foundation

public enum ToolbarAction: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case update, settings
    case importMaterials = "import"
    case create, schedule, allMaterials, favorites, recent, homework, pendingTasks

    public var id: Self { self }
    public var title: String {
        switch self {
        case .update: return "全局更新"
        case .settings: return "设置"
        case .importMaterials: return "导入资料"
        case .create: return "新建"
        case .schedule: return "计划"
        case .allMaterials: return "全部资料"
        case .favorites: return "收藏"
        case .recent: return "最近打开"
        case .homework: return "作业文件夹"
        case .pendingTasks: return "待完成计划"
        }
    }
    public var symbol: String {
        switch self {
        case .update: return "arrow.triangle.2.circlepath"
        case .settings: return "gearshape"
        case .importMaterials: return "square.and.arrow.down"
        case .create: return "plus"
        case .schedule: return "calendar"
        case .allMaterials: return "tray.full"
        case .favorites: return "star"
        case .recent: return "clock"
        case .homework: return "folder"
        case .pendingTasks: return "checklist"
        }
    }
}

/// The capsule's ordered shortcuts travel with the library's other workspace preferences.
public struct ToolbarSettings: Codable, Hashable, Sendable {
    public var actions: [ToolbarAction]

    public static let maximumActionCount = 6
    public static let `default` = ToolbarSettings()

    public init(actions: [ToolbarAction] = [.update, .settings, .importMaterials, .create]) {
        self.actions = actions
    }

    public var isValid: Bool {
        actions.count <= Self.maximumActionCount && Set(actions).count == actions.count
    }
}
