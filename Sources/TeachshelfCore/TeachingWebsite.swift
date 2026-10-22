import Foundation
import CryptoKit

public enum TeachingWebsite {
    public static let host = "selearning.nju.edu.cn"
    public static func courseURL(_ id: String) -> URL { URL(string: "https://\(host)/course/view.php?id=\(id)")! }
    public static func isPage(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == host, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["/course/view.php", "/mod/folder/view.php", "/mod/assign/view.php", "/mod/resource/view.php"].contains(url.path)
    }
    public static func isDownload(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == host, url.port == nil || url.port == 443,
              url.user == nil, url.password == nil else { return false }
        return url.path.hasPrefix("/pluginfile.php/") &&
            ["/mod_folder/content/", "/mod_resource/content/", "/mod_assign/introattachment/", "/mod_assign/intro/"].contains(where: url.path.contains)
    }
    public static func allowsNavigation(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return false }
        return [host, "authserver.nju.edu.cn"].contains(url.host ?? "")
    }
    public static func identifier(_ url: URL?) -> String? {
        guard isPage(url), let url, let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty, id.count <= 16, id.allSatisfy(\.isNumber) else { return nil }
        return id
    }
    public static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func validateFile(_ url: URL, name: String) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard size.isRegularFile == true, size.isSymbolicLink != true, let bytes = size.fileSize, bytes > 0, bytes <= 512 * 1_048_576 else {
            throw LibraryError.invalidInput("下载文件为空、不是普通文件或超过 512 MB。")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 4096) ?? Data()
        let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.hasPrefix("<!doctype html"), !text.hasPrefix("<html"), !text.contains("type=\"password\"") else {
            throw LibraryError.invalidInput("下载结果是网页，请重新登录后再试。")
        }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if ext == "pdf", !prefix.starts(with: Data("%PDF-".utf8)) { throw LibraryError.invalidInput("下载结果不是有效的 PDF。") }
        if ["pptx", "docx", "xlsx", "zip"].contains(ext), !prefix.starts(with: [0x50, 0x4b]) {
            throw LibraryError.invalidInput("下载结果不是有效的 Office 文件或 ZIP。")
        }
    }
    public static func deadline(_ text: String, timeZone: String) -> (date: Date?, allDay: Bool) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let zone = TimeZone(identifier: timeZone) else { return (nil, true) }
        if let iso = ISO8601DateFormatter().date(from: value) { return (iso, false) }
        let pattern = #"(\d{4})[年/\-](\d{1,2})[月/\-](\d{1,2})日?(?:[^\d]*(\d{1,2}):(\d{2})(?::(\d{2}))?)?"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return (nil, true) }
        func number(_ index: Int) -> Int? { Range(match.range(at: index), in: value).flatMap { Int(value[$0]) } }
        guard let year = number(1), let month = number(2), let day = number(3), (1900...2200).contains(year) else { return (nil, true) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let hour = number(4), minute = number(5)
        let parts = DateComponents(year: year, month: month, day: day, hour: hour ?? 0, minute: minute ?? 0, second: number(6) ?? 0)
        guard let date = calendar.date(from: parts), calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day,
              calendar.component(.hour, from: date) == (hour ?? 0), calendar.component(.minute, from: date) == (minute ?? 0) else { return (nil, true) }
        return (date, hour == nil)
    }
}

public struct TeachingActivity: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var sectionID: String
    public var section: String
    public var url: URL
    public init(id: String, kind: String, title: String, sectionID: String = "", section: String = "课件", url: URL) {
        self.id = id; self.kind = kind; self.title = title; self.sectionID = sectionID; self.section = section; self.url = url
    }
    public var key: String { "\(kind):\(id)" }
    public var isExperiment: Bool { section.contains("实验") || title.localizedCaseInsensitiveContains("lab") }
}

public struct TeachingFile: Codable, Hashable, Sendable {
    public var key: String
    public var name: String
    public var url: URL
    public var subfolders: [String]
    public init(key: String, name: String, url: URL, subfolders: [String] = []) {
        self.key = key; self.name = name; self.url = url; self.subfolders = subfolders
    }
}

public struct TeachingPage: Codable, Hashable, Sendable {
    public var kind: String
    public var accountID: String
    public var courseID: String
    public var title: String
    public var activities: [TeachingActivity]
    public var files: [TeachingFile]
    public var intro: String
    public var deadlineText: String
    public var submitted: Bool
    public init(kind: String = "course", accountID: String = "", courseID: String = "", title: String = "", activities: [TeachingActivity] = [], files: [TeachingFile] = [], intro: String = "", deadlineText: String = "", submitted: Bool = false) {
        self.kind = kind; self.accountID = accountID; self.courseID = courseID; self.title = title
        self.activities = activities; self.files = files; self.intro = intro; self.deadlineText = deadlineText; self.submitted = submitted
    }
}

public struct TeachingDeadlineChange: Codable, Hashable, Sendable {
    public var date: Date?
    public var allDay: Bool
    public var text: String
}

public enum TeachingFileState: Equatable, Sendable { case new, existing, missing, ignored }

public struct TeachingAssignmentChange: Sendable {
    public let before: StudyTask?
    public let proposed: StudyTask
    public let pendingDeadline: TeachingDeadlineChange?
    public let message: String
}

public struct TeachingItemLink: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var localID: UUID?
    public var title: String
    public var content: String = ""
    public var digest: String = ""
    public var folderID: UUID?
    public var remoteDeadline: Date?
    public var appliedDeadline: Date?
    public var remoteDeadlineIsAllDay: Bool?
    public var appliedDeadlineIsAllDay: Bool?
    public var pendingDeadline: TeachingDeadlineChange?
    public var ignored: Bool = false
    public var submitted: Bool = false
    public init(id: String, localID: UUID? = nil, title: String) { self.id = id; self.localID = localID; self.title = title }
}

public struct TeachingFolderLink: Codable, Hashable, Sendable {
    public var key: String
    public var localID: UUID?
}

public struct TeachingSyncMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var text: String
    public var isIssue: Bool
    public init(_ text: String, isIssue: Bool = false) { self.text = text; self.isIssue = isIssue }
}

public struct TeachingConnection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var courseID: UUID
    public var remoteCourseID: String
    public var remoteTitle: String
    public var accountID: String
    public var timeZone: String
    public var includeMaterials = true
    public var includeAssignments = true
    public var includeExperiments = true
    public var includeHistory = false
    public var lastSyncAt: Date?
    public var messages: [TeachingSyncMessage] = []
    public var items: [TeachingItemLink] = []
    public var folders: [TeachingFolderLink] = []
    public init(id: UUID = UUID(), courseID: UUID, remoteCourseID: String, remoteTitle: String, accountID: String, timeZone: String = "Asia/Shanghai") {
        self.id = id; self.courseID = courseID; self.remoteCourseID = remoteCourseID
        self.remoteTitle = remoteTitle; self.accountID = accountID; self.timeZone = timeZone
    }
}
