import Foundation

public struct Course: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var semester: String
    public var teacher: String
    public var colorHex: String
    public var isArchived: Bool
    public var homeworkFolder: String?

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

    public init(id: UUID = UUID(), title: String, content: String = "", kind: String = "任务", courseID: UUID? = nil, materialIDs: [UUID] = [], startsAt: Date = Date(), deadline: Date? = nil, isAllDay: Bool = true, showOnCalendar: Bool = true, completedAt: Date? = nil, archivedAt: Date? = nil, courseNameSnapshot: String? = nil) {
        self.id = id; self.title = title; self.content = content; self.kind = kind
        self.courseID = courseID; self.materialIDs = materialIDs; self.startsAt = startsAt
        self.deadline = deadline; self.isAllDay = isAllDay; self.showOnCalendar = showOnCalendar
        self.completedAt = completedAt; self.archivedAt = archivedAt; self.courseNameSnapshot = courseNameSnapshot
    }
    public var isCompleted: Bool { completedAt != nil }
    public var isArchived: Bool { archivedAt != nil }
}

public struct LibraryState: Codable, Hashable, Sendable {
    public var schemaVersion: Int = 1
    public var courses: [Course] = []
    public var materials: [MaterialRecord] = []
    public var tasks: [StudyTask] = []
    public var customCategories: [String] = []
    public var accentColor: String = "#39786B"
    public var appearance: String = "system"
    public init() {}
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
