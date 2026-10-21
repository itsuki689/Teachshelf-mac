import SwiftUI
import WebKit
import CryptoKit
import TeachshelfCore

@MainActor final class TeachingWebsiteController: ObservableObject {
    let client: TeachingWebClient
    let dataStore: WKWebsiteDataStore
    @Published var preview: TeachingPage?
    @Published var status = "登录后，将网站课程绑定到现有课程。"
    @Published var messages: [TeachingSyncMessage] = []
    @Published var updating = false
    @Published var reading = false
    @Published var showWeb = false
    private(set) var operation: Task<Void, Never>?
    private var worker: TeachingWebsiteTransport?
    private let transport: TeachingWebsiteTransport?

    init(root: URL, dataStore: WKWebsiteDataStore? = nil, transport: TeachingWebsiteTransport? = nil) {
        // Isolate sessions per library. Session data is managed by WebKit, outside library backups.
        let hex = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let uuid = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.suffix(12))"
        self.dataStore = dataStore ?? WKWebsiteDataStore(forIdentifier: UUID(uuidString: uuid)!)
        client = TeachingWebClient(dataStore: self.dataStore)
        self.transport = transport
    }
    func openCourse(_ remoteID: String = "411") { showWeb = true; (transport ?? client).open(TeachingWebsite.courseURL(remoteID)) }
    func readCourse() {
        guard !reading, !updating else { return }
        reading = true; status = "正在读取当前课程…"
        operation = Task { [weak self] in
            guard let self else { return }; defer { self.reading = false; self.operation = nil }
            do {
                let page = try await self.client.read(); try Task.checkCancellation()
                guard page.kind == "course" else { throw LibraryError.invalidInput("请先打开课程首页，再读取课程。") }
                self.preview = page; self.status = "已读取 \(page.title) · \(page.activities.count) 个课件、作业或实验条目。"
            } catch is CancellationError { self.status = "已取消读取" }
            catch { self.status = error.localizedDescription }
        }
    }
    func update(_ connection: TeachingConnection, store: AppStore) {
        guard !updating, !reading, !store.isBusy else { return }
        updating = true; store.isBusy = true; messages = []; showWeb = true
        let repository = store.repository
        operation = Task { [weak self, weak store] in
            guard let self else { store?.isBusy = false; return }
            let worker = self.transport ?? self.client; self.worker = worker
            var completed = false
            defer {
                worker.cleanDownload(); self.worker = nil; self.updating = false; self.operation = nil
                do { try repository.finishTeachingUpdate(connection.id, messages: self.messages, completed: completed) }
                catch { self.status = "更新记录未能保存；已成功导入的内容保留。" }
                store?.isBusy = false; store?.reload(); store?.status = self.status
            }
            do {
                self.status = "正在检查登录与课程目录…"
                try await worker.load(TeachingWebsite.courseURL(connection.remoteCourseID))
                let course = try await worker.read()
                try self.verify(course, connection)
                guard course.kind == "course" else { throw TeachingWebError.unreadable }
                let activities = course.activities.filter {
                    $0.kind == "assign" ? ($0.isExperiment ? connection.includeExperiments : connection.includeAssignments) : connection.includeMaterials
                }
                for (index, activity) in activities.enumerated() {
                    try Task.checkCancellation()
                    self.status = "\(index + 1)/\(activities.count) · \(activity.title)"
                    do {
                        if activity.kind == "assign", let link = repository.state.teachingConnections.first(where: { $0.id == connection.id })?.items.first(where: { $0.id == "plan:\(activity.id)" }),
                           link.ignored || !repository.state.tasks.contains(where: { $0.id == link.localID && $0.courseID == connection.courseID }) {
                            self.messages.append(TeachingSyncMessage("忽略 · \(activity.title)（已在本地移除或转移）")); continue
                        }
                        guard TeachingWebsite.identifier(activity.url) == activity.id else { throw TeachingWebError.blocked }
                        var page: TeachingPage
                        do {
                            try await worker.load(activity.url); page = try await worker.read(); try self.verify(page, connection)
                        } catch TeachingWebError.directFile(let url, let name) {
                            guard activity.kind == "resource" else { throw TeachingWebError.unreadable }
                            page = TeachingPage(kind: "resource", accountID: connection.accountID, courseID: connection.remoteCourseID,
                                files: [TeachingFile(key: url.lastPathComponent, name: name, url: url)])
                        }
                        if activity.kind == "assign" {
                            // Historical assignments are excluded as a unit, including their attachments.
                            let due = TeachingWebsite.deadline(page.deadlineText, timeZone: connection.timeZone).date
                            let known = repository.state.teachingConnections.first { $0.id == connection.id }?.items.contains { $0.id == "plan:\(activity.id)" } ?? false
                            if !known, !connection.includeHistory, page.submitted || (due.map { $0 < Date() } ?? false) {
                                self.messages.append(TeachingSyncMessage("跳过历史 · \(activity.title)")); continue
                            }
                        }
                        for file in page.files {
                            try Task.checkCancellation()
                            self.status = "下载 · \(file.name)"
                            do {
                                let url = try await worker.fetch(file)
                                let result = try await Task.detached(priority: .userInitiated) {
                                    try repository.syncTeachingFile(connectionID: connection.id, activity: activity, file: file, downloadedURL: url)
                                }.value
                                worker.cleanDownload(); self.messages.append(TeachingSyncMessage(result))
                            } catch is CancellationError { throw CancellationError() }
                            catch TeachingWebError.login { throw TeachingWebError.login }
                            catch { worker.cleanDownload(); self.messages.append(TeachingSyncMessage("\(file.name)：\(error.localizedDescription)", isIssue: true)) }
                        }
                        if activity.kind == "assign" {
                            let result = try repository.syncTeachingAssignment(connectionID: connection.id, activity: activity, page: page)
                            self.messages.append(TeachingSyncMessage(result, isIssue: result.contains("待核对") || result.contains("冲突")))
                        } else if page.files.isEmpty { self.messages.append(TeachingSyncMessage("\(activity.title)：未找到可下载文件，请打开来源检查。", isIssue: true)) }
                        store?.reload()
                    } catch is CancellationError { throw CancellationError() }
                    catch TeachingWebError.login { throw TeachingWebError.login }
                    catch { self.messages.append(TeachingSyncMessage("\(activity.title)：\(error.localizedDescription)", isIssue: true)) }
                }
                completed = true
                self.showWeb = false
                let added = self.messages.filter { $0.text.hasPrefix("新增") }.count
                let changed = self.messages.filter { $0.text.hasPrefix("更新") }.count
                let issues = self.messages.filter(\.isIssue).count
                self.status = "更新完成 · 新增 \(added) 项 · 更新 \(changed) 项" + (issues > 0 ? " · \(issues) 项需处理" : "")
            } catch is CancellationError { self.showWeb = false; self.status = "已取消更新，已成功的内容保留；可再次更新继续。" }
            catch {
                self.status = error.localizedDescription
                self.showWeb = false
                self.messages.append(TeachingSyncMessage(self.status, isIssue: true))
                if case TeachingWebError.login = error { self.openCourse(connection.remoteCourseID) }
            }
        }
    }
    private func verify(_ page: TeachingPage, _ connection: TeachingConnection) throws {
        guard page.accountID == connection.accountID else { throw TeachingWebError.login }
        guard page.courseID == connection.remoteCourseID else { throw TeachingWebError.unreadable }
    }
    func cancel() { operation?.cancel(); worker?.cancel(); client.cancel() }
    func suspend() { cancel() }
    func close() { cancel(); client.close() }
}
