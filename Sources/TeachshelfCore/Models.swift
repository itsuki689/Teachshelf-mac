import Foundation

public struct Course: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var semester: String
    public var teacher: String
    public var colorHex: String
    public var isArchived: Bool
    public var homeworkFolder: String?
    public var materialSort: MaterialSortMode?
    public var storageDirectory: String?
    public var materialRootName: String?
    public var isMissing: Bool?

    public init(id: UUID = UUID(), name: String, semester: String = "", teacher: String = "", colorHex: String = "#39786B", isArchived: Bool = false, homeworkFolder: String? = nil) {
        self.id = id; self.name = name; self.semester = semester; self.teacher = teacher
        self.colorHex = colorHex; self.isArchived = isArchived; self.homeworkFolder = homeworkFolder
    }
}

public struct MaterialRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var courseID: UUID?
    public var title: String
    public var originalName: String
    public var sourcePath: String
    public var storedPath: String
    public var isManaged: Bool
    public var category: String
    public var tags: String
    public var notes: String
    public var isFavorite: Bool
    public var size: Int64
    public var addedAt: Date
    public var lastOpenedAt: Date?
    public var folderID: UUID?
    public var customOrder: Int?
    public var storageName: String?
    public var storageDirectory: String?
    public var isMissing: Bool?

    public init(id: UUID = UUID(), courseID: UUID? = nil, title: String, originalName: String, sourcePath: String, storedPath: String, isManaged: Bool, category: String = "课件", tags: String = "", notes: String = "", isFavorite: Bool = false, size: Int64 = 0, addedAt: Date = Date(), lastOpenedAt: Date? = nil) {
        self.id = id; self.courseID = courseID; self.title = title; self.originalName = originalName
        self.sourcePath = sourcePath; self.storedPath = storedPath; self.isManaged = isManaged
        self.category = category; self.tags = tags; self.notes = notes; self.isFavorite = isFavorite
        self.size = size; self.addedAt = addedAt; self.lastOpenedAt = lastOpenedAt
    }

    public var fileExtension: String { URL(fileURLWithPath: originalName).pathExtension.lowercased() }
    public var fileType: String {
        switch fileExtension {
        case "pdf": return "PDF"
        case "doc", "docx", "pages", "rtf", "txt", "md": return "文档"
        case "ppt", "pptx", "key": return "演示文稿"
        case "xls", "xlsx", "csv", "numbers": return "表格"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "svg": return "图片"
        case "mp4", "mov", "m4v", "mkv": return "视频"
        case "mp3", "m4a", "wav", "aac", "flac": return "音频"
        case "zip", "rar", "7z", "tar", "gz": return "压缩包"
        default: return fileExtension.isEmpty ? "文件" : fileExtension.uppercased()
        }
    }
    public var sizeLabel: String { Self.formatBytes(size) }
    static func formatBytes(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, size), countStyle: .file)
    }
}

public struct StudyTask: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var content: String
    public var kind: String
    public var courseID: UUID?
    public var materialIDs: [UUID]
    public var startsAt: Date
    public var deadline: Date?
    public var isAllDay: Bool
    public var showOnCalendar: Bool
    public var completedAt: Date?
    public var archivedAt: Date?
    public var courseNameSnapshot: String?
    public var origin: PlanOrigin
    public var hasExecutionTime: Bool
    public var endsAt: Date?
    public var location: String
    public var showInMonth: Bool
    public var repeatRule: PlanRepeatRule?
    public var completionRequired: Bool
    public var cancelledAt: Date?
    public var deadlineIsAllDay: Bool
    public var exceptions: [PlanException]
    public var colorHex: String?

    public init(id: UUID = UUID(), title: String, content: String = "", kind: String = "任务", courseID: UUID? = nil, materialIDs: [UUID] = [], startsAt: Date = Date(), deadline: Date? = nil, isAllDay: Bool = true, showOnCalendar: Bool = true, completedAt: Date? = nil, archivedAt: Date? = nil, courseNameSnapshot: String? = nil, origin: PlanOrigin = .activity, hasExecutionTime: Bool = true, endsAt: Date? = nil, location: String = "", showInMonth: Bool = false, repeatRule: PlanRepeatRule? = nil, completionRequired: Bool = true, cancelledAt: Date? = nil, deadlineIsAllDay: Bool = true, exceptions: [PlanException] = [], colorHex: String? = nil) {
        self.id = id; self.title = title; self.content = content; self.kind = kind
        self.courseID = courseID; self.materialIDs = materialIDs; self.startsAt = startsAt
        self.deadline = deadline; self.isAllDay = isAllDay; self.showOnCalendar = showOnCalendar
        self.completedAt = completedAt; self.archivedAt = archivedAt; self.courseNameSnapshot = courseNameSnapshot
        self.origin = origin; self.hasExecutionTime = hasExecutionTime; self.endsAt = endsAt
        self.location = location; self.showInMonth = showInMonth; self.repeatRule = repeatRule
        self.completionRequired = completionRequired; self.cancelledAt = cancelledAt
        self.deadlineIsAllDay = deadlineIsAllDay; self.exceptions = exceptions
        self.colorHex = colorHex
    }
    public var isCompleted: Bool { completedAt != nil }
    public var isArchived: Bool { archivedAt != nil }
    public var isCancelled: Bool { cancelledAt != nil }
    public var isFixed: Bool { origin == .fixed }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, kind, courseID, materialIDs, startsAt, deadline, isAllDay, showOnCalendar, completedAt, archivedAt, courseNameSnapshot
        case origin, hasExecutionTime, endsAt, location, showInMonth, repeatRule, completionRequired, cancelledAt, deadlineIsAllDay, exceptions
        case colorHex
    }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(UUID.self, forKey: .id); title = try v.decode(String.self, forKey: .title)
        content = try v.decode(String.self, forKey: .content); kind = try v.decode(String.self, forKey: .kind)
        courseID = try v.decodeIfPresent(UUID.self, forKey: .courseID)
        materialIDs = try v.decode([UUID].self, forKey: .materialIDs)
        startsAt = try v.decode(Date.self, forKey: .startsAt); deadline = try v.decodeIfPresent(Date.self, forKey: .deadline)
        isAllDay = try v.decode(Bool.self, forKey: .isAllDay); showOnCalendar = try v.decode(Bool.self, forKey: .showOnCalendar)
        completedAt = try v.decodeIfPresent(Date.self, forKey: .completedAt)
        archivedAt = try v.decodeIfPresent(Date.self, forKey: .archivedAt)
        courseNameSnapshot = try v.decodeIfPresent(String.self, forKey: .courseNameSnapshot)
        origin = v.contains(.origin) ? try v.decode(PlanOrigin.self, forKey: .origin) : .activity
        // Older tasks displayed their deadline instead of execution when both existed.
        hasExecutionTime = v.contains(.hasExecutionTime) ? try v.decode(Bool.self, forKey: .hasExecutionTime) : deadline == nil
        endsAt = try v.decodeIfPresent(Date.self, forKey: .endsAt)
        location = v.contains(.location) ? try v.decode(String.self, forKey: .location) : ""
        showInMonth = v.contains(.showInMonth) ? try v.decode(Bool.self, forKey: .showInMonth) : false
        repeatRule = try v.decodeIfPresent(PlanRepeatRule.self, forKey: .repeatRule)
        completionRequired = v.contains(.completionRequired) ? try v.decode(Bool.self, forKey: .completionRequired) : true
        cancelledAt = try v.decodeIfPresent(Date.self, forKey: .cancelledAt)
        deadlineIsAllDay = v.contains(.deadlineIsAllDay) ? try v.decode(Bool.self, forKey: .deadlineIsAllDay) : isAllDay
        exceptions = v.contains(.exceptions) ? try v.decode([PlanException].self, forKey: .exceptions) : []
        colorHex = try v.decodeIfPresent(String.self, forKey: .colorHex)
    }
}

public struct LibraryState: Codable, Hashable, Sendable {
    public var schemaVersion: Int = 9
    public var courses: [Course] = []
    public var materials: [MaterialRecord] = []
    public var materialFolders: [MaterialFolder] = []
    public var teachingConnections: [TeachingConnection] = []
    public var tasks: [StudyTask] = []
    public var timetableTerms: [TimetableTerm] = []
    public var customCategories: [String] = []
    public var accentColor: String = ColorPalette.defaultAccent
    public var appearance: String = "system"
    public var appearanceTransition: AppearanceTransitionSettings = .default
    public var toolbarSettings: ToolbarSettings = .default
    public var showCourseBorders: Bool = true
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, courses, materials, materialFolders, teachingConnections, tasks, timetableTerms, customCategories, accentColor, appearance, appearanceTransition, toolbarSettings, showCourseBorders
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        courses = try values.decode([Course].self, forKey: .courses)
        materials = try values.decode([MaterialRecord].self, forKey: .materials)
        materialFolders = try values.decodeIfPresent([MaterialFolder].self, forKey: .materialFolders) ?? []
        teachingConnections = try values.decodeIfPresent([TeachingConnection].self, forKey: .teachingConnections) ?? []
        tasks = try values.decode([StudyTask].self, forKey: .tasks)
        timetableTerms = values.contains(.timetableTerms) ? try values.decode([TimetableTerm].self, forKey: .timetableTerms) : []
        customCategories = try values.decode([String].self, forKey: .customCategories)
        accentColor = try values.decode(String.self, forKey: .accentColor)
        appearance = try values.decode(String.self, forKey: .appearance)
        appearanceTransition = values.contains(.appearanceTransition)
            ? try values.decode(AppearanceTransitionSettings.self, forKey: .appearanceTransition) : .default
        toolbarSettings = values.contains(.toolbarSettings)
            ? try values.decode(ToolbarSettings.self, forKey: .toolbarSettings) : .default
        showCourseBorders = values.contains(.showCourseBorders) ? try values.decode(Bool.self, forKey: .showCourseBorders) : true
    }
}

public struct WorkspaceEntry: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modifiedAt: Date
    public init(url: URL, name: String, isDirectory: Bool, size: Int64, modifiedAt: Date) {
        self.url = url; self.name = name; self.isDirectory = isDirectory; self.size = size; self.modifiedAt = modifiedAt
    }
    public var sizeLabel: String { isDirectory ? "文件夹" : MaterialRecord.formatBytes(size) }
}

public struct ImportSummary: Equatable, Sendable {
    public var imported: Int
    public var skipped: Int
    public var errors: [String]
    public init(imported: Int = 0, skipped: Int = 0, errors: [String] = []) {
        self.imported = imported; self.skipped = skipped; self.errors = errors
    }
}

public enum LibraryError: LocalizedError {
    case locked
    case invalidLibrary(String)
    case missingRecord(String)
    case unsafePath(String)
    case missingFile(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .locked: return "此资料库已在另一个课屿窗口中打开。"
        case .invalidLibrary(let reason): return "资料库无法读取，原文件已保留：\(reason)"
        case .missingRecord(let name): return "找不到\(name)，请刷新后重试。"
        case .unsafePath(let path): return "为保护资料库，无法访问此路径或符号链接：\(path)"
        case .missingFile(let path): return "文件不存在：\(path)"
        case .invalidInput(let reason): return reason
        }
    }
}
