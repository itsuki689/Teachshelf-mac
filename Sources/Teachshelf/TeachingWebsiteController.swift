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
    @Published private(set) var checking = false
    @Published private(set) var proposals: [TeachingUpdateProposal] = []
    @Published private(set) var hasReview = false
    @Published private(set) var reviewIsGlobal = false
    @Published private(set) var reviewSources: [TeachingConnection] = []
    @Published private(set) var skippedFiles = 0
    @Published private(set) var downloadedFiles = 0
    @Published var selectedProposalIDs: Set<String> = []
    @Published var adoptWebsiteDeadlineIDs: Set<String> = []
    private var checkedAt: Date?
    private var notes: [UUID: [TeachingSyncMessage]] = [:]
    private var discoveryNotes: [UUID: [TeachingSyncMessage]] = [:]
    private(set) var operation: Task<Void, Never>?
    private var worker: TeachingWebsiteTransport?
    private let transport: TeachingWebsiteTransport?

    init(root: URL, dataStore: WKWebsiteDataStore? = nil, transport: TeachingWebsiteTransport? = nil) {
        // Isolate sessions per library. WebKit and the optional local keychain are outside library backups.
        let hex = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let uuid = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.suffix(12))"
        self.dataStore = dataStore ?? WKWebsiteDataStore(forIdentifier: UUID(uuidString: uuid)!)
        client = TeachingWebClient(dataStore: self.dataStore, root: root)
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
    private func verify(_ page: TeachingPage, _ connection: TeachingConnection) throws {
        guard page.accountID == connection.accountID else { throw TeachingWebError.accountMismatch }
        guard page.courseID == connection.remoteCourseID else { throw TeachingWebError.unreadable }
    }
    func cancel() { operation?.cancel(); worker?.cancel(); client.cancel() }
    func suspend() { cancel() }
    func close() { cancel(); client.close() }
}


extension TeachingWebsiteController {
    func discardReview() {
        guard !updating else { return }
        proposals = []; selectedProposalIDs = []; adoptWebsiteDeadlineIDs = []; hasReview = false; checkedAt = nil
    }
    func selectAllProposals(_ selected: Bool) { selectedProposalIDs = selected ? Set(proposals.map(\.id)) : [] }

    /// Discovery reads pages and local mappings, without fetching attachments or changing the library.
    func check(_ connections: [TeachingConnection], store: AppStore, global: Bool = false) {
        guard !updating, !reading, !store.isBusy else { return }
        let requested = Set(connections.map(\.id))
        let eligible = store.repository.state.teachingConnections.filter { connection in requested.contains(connection.id) && store.state.courses.contains { $0.id == connection.courseID && !$0.isArchived } }
        guard !eligible.isEmpty else { status = "没有可检查的已连接课程。"; return }
        discardReview(); reviewSources = eligible; reviewIsGlobal = global; skippedFiles = 0; downloadedFiles = 0; notes = [:]; discoveryNotes = [:]; messages = []
        updating = true; checking = true; store.isBusy = true; showWeb = true
        let repository = store.repository
        operation = Task { [weak self, weak store] in
            guard let self else { store?.isBusy = false; return }
            let worker = self.transport ?? self.client; self.worker = worker
            var interrupted = false, loginRequired = false
            defer {
                self.discoveryNotes = self.notes
                self.checkedAt = Date(); self.hasReview = true
                self.selectedProposalIDs = Set(self.proposals.filter { !$0.repair }.map(\.id))
                self.worker = nil; self.updating = false; self.checking = false; self.operation = nil
                if !loginRequired { self.showWeb = false }
                self.status = (interrupted ? "检查已暂停" : "检查完成") + " · \(self.proposals.count) 项待确认 · 跳过 \(self.skippedFiles) 份已有资料"
                let issues = self.messages.filter(\.isIssue).count
                if issues > 0 { self.status += " · \(issues) 项需处理" }
                store?.isBusy = false; store?.status = self.status
            }
            courseLoop: for (courseIndex, connection) in eligible.enumerated() {
                do {
                    try Task.checkCancellation()
                    self.status = "检查课程 \(courseIndex + 1)/\(eligible.count) · \(connection.remoteTitle)"
                    try await worker.load(TeachingWebsite.courseURL(connection.remoteCourseID))
                    let course = try await worker.read(); try self.verify(course, connection)
                    guard course.kind == "course" else { throw TeachingWebError.unreadable }
                    let activities = course.activities.filter {
                        $0.kind == "assign" ? ($0.isExperiment ? connection.includeExperiments : connection.includeAssignments) : connection.includeMaterials
                    }
                    for (index, activity) in activities.enumerated() {
                        try Task.checkCancellation()
                        self.status = "\(courseIndex + 1)/\(eligible.count) 门课程 · \(index + 1)/\(activities.count) · \(activity.title)"
                        do {
                            let current = repository.state.teachingConnections.first { $0.id == connection.id }
                            let link = current?.items.first { $0.id == "plan:\(activity.id)" }
                            let localPlan = repository.state.tasks.first { $0.id == link?.localID && $0.courseID == connection.courseID }
                            if activity.kind == "assign", let link, link.ignored || localPlan == nil { continue }
                            guard TeachingWebsite.identifier(activity.url) == activity.id else { throw TeachingWebError.blocked }
                            var page: TeachingPage
                            do {
                                try await worker.load(activity.url); page = try await worker.read(); try self.verify(page, connection)
                            } catch TeachingWebError.directFile(let url, let name) {
                                guard activity.kind == "resource" else { throw TeachingWebError.unreadable }
                                page = TeachingPage(kind: "resource", accountID: connection.accountID, courseID: connection.remoteCourseID,
                                                    files: [TeachingFile(key: url.lastPathComponent, name: name, url: url)])
                            }
                            if activity.kind == "assign", link == nil, !connection.includeHistory {
                                let due = TeachingWebsite.deadline(page.deadlineText, timeZone: connection.timeZone).date
                                if page.submitted || (due.map { $0 < Date() } ?? false) { continue }
                            }
                            var newAttachments = false
                            for file in page.files {
                                let state = try repository.teachingFileState(connectionID: connection.id, activity: activity, file: file)
                                switch state {
                                case .existing: self.skippedFiles += 1
                                case .ignored: break
                                case .new, .missing:
                                    self.proposals.append(TeachingUpdateProposal(connection: connection, activity: activity, file: file, page: nil, before: nil, change: nil, repair: state == .missing))
                                    newAttachments = newAttachments || state == .new
                                }
                            }
                            if activity.kind == "assign" {
                                let change = try repository.previewTeachingAssignment(connectionID: connection.id, activity: activity, page: page)
                                if change == nil, !page.deadlineText.isEmpty, TeachingWebsite.deadline(page.deadlineText, timeZone: connection.timeZone).date == nil {
                                    self.record("\(activity.title)：截止时间待核对 · \(page.deadlineText)", connection, issue: true)
                                }
                                let mapped = (current?.items.filter { $0.id.hasPrefix("file:\(activity.key):") && !$0.ignored }.compactMap(\.localID) ?? []).filter { id in repository.state.materials.contains { $0.id == id && $0.courseID == connection.courseID } }
                                let unlinked = localPlan.map { !Set(mapped).isSubset(of: Set($0.materialIDs)) } ?? false
                                if change != nil || (localPlan?.isArchived == false && (newAttachments || unlinked)) {
                                    self.proposals.append(TeachingUpdateProposal(connection: connection, activity: activity, file: nil, page: page, before: localPlan, change: change))
                                }
                            } else if page.files.isEmpty { self.record("\(activity.title)：未找到可下载文件，请打开来源检查。", connection, issue: true) }
                        } catch is CancellationError { throw CancellationError() }
                        catch TeachingWebError.login { throw TeachingWebError.login }
                        catch TeachingWebError.accountMismatch { throw TeachingWebError.accountMismatch }
                        catch { self.record("\(activity.title)：\(error.localizedDescription)", connection, issue: true) }
                    }
                } catch is CancellationError { interrupted = true; break courseLoop }
                catch {
                    self.record(error.localizedDescription, connection, issue: true)
                    if case TeachingWebError.login = error {
                        self.presentLogin(connection); loginRequired = true; interrupted = true; break courseLoop
                    }
                    if case TeachingWebError.accountMismatch = error { interrupted = true }
                }
            }
        }
    }

    /// Confirmation rechecks local state, then fetches only approved new or explicitly missing files.
    func applySelected(store: AppStore) {
        guard !updating, !reading, !store.isBusy, hasReview else { return }
        guard let checkedAt, Date().timeIntervalSince(checkedAt) < 15 * 60 else { status = "清单已超过 15 分钟，请重新检查后确认。"; return }
        let chosen = proposals.filter { selectedProposalIDs.contains($0.id) }
        guard !chosen.isEmpty else { status = "请先勾选要更新的项目。"; return }
        downloadedFiles = 0; notes = discoveryNotes
        messages = reviewSources.flatMap { source in (notes[source.id] ?? []).map { message in
            var named = message; named.text = source.remoteTitle + " · " + message.text; return named
        } }
        updating = true; store.isBusy = true; showWeb = true
        let repository = store.repository, deadlineChoices = adoptWebsiteDeadlineIDs
        operation = Task { [weak self, weak store] in
            guard let self else { store?.isBusy = false; return }
            let worker = self.transport ?? self.client; self.worker = worker
            var done: Set<String> = [], added = 0, changed = 0, interrupted = false, loginRequired = false
            defer {
                worker.cleanDownload(); self.worker = nil; self.updating = false; self.operation = nil
                self.proposals.removeAll { done.contains($0.id) }; self.selectedProposalIDs.subtract(done); self.adoptWebsiteDeadlineIDs.subtract(done)
                self.hasReview = !self.proposals.isEmpty
                if !loginRequired { self.showWeb = false }
                self.status = (interrupted ? "更新已暂停" : "更新完成") + " · 新增 \(added) 项 · 更新 \(changed) 项 · 下载 \(self.downloadedFiles) 份" + (self.hasReview ? " · \(self.proposals.count) 项留在清单" : "")
                let issues = self.messages.filter(\.isIssue).count
                if issues > 0 { self.status += " · \(issues) 项需处理" }
                store?.isBusy = false; store?.reload(); store?.status = self.status
            }
            courseLoop: for connection in self.reviewSources where chosen.contains(where: { $0.connection.id == connection.id }) {
                var completed = false
                do {
                    try Task.checkCancellation()
                    guard let current = repository.state.teachingConnections.first(where: { $0.id == connection.id }),
                          self.sameConfiguration(current, connection), repository.state.courses.contains(where: { $0.id == connection.courseID && !$0.isArchived }) else {
                        throw LibraryError.invalidInput("课程或连接设置已改变，请重新检查。")
                    }
                    try await worker.load(TeachingWebsite.courseURL(connection.remoteCourseID))
                    try self.verify(try await worker.read(), connection)
                    let rows = chosen.filter { $0.connection.id == connection.id }.sorted { ($0.file == nil ? 1 : 0) < ($1.file == nil ? 1 : 0) }
                    for row in rows {
                        try Task.checkCancellation(); self.status = "更新 · \(connection.remoteTitle) · \(row.title)"
                        do {
                            var result: String
                            if let file = row.file {
                                let state = try repository.teachingFileState(connectionID: connection.id, activity: row.activity, file: file)
                                if state == .existing || state == .ignored { done.insert(row.id); continue }
                                guard state == .new || row.repair else { throw LibraryError.invalidInput("资料记录已变化，请重新检查。") }
                                let url = try await worker.fetch(file)
                                self.downloadedFiles += 1
                                result = try await Task.detached(priority: .userInitiated) {
                                    try repository.syncTeachingFile(connectionID: connection.id, activity: row.activity, file: file, downloadedURL: url)
                                }.value
                                worker.cleanDownload()
                            } else if let page = row.page {
                                let link = repository.state.teachingConnections.first { $0.id == connection.id }?.items.first { $0.id == "plan:\(row.activity.id)" }
                                let local = repository.state.tasks.first { $0.id == link?.localID }
                                var before = row.before
                                if let local { before?.materialIDs = local.materialIDs }
                                guard before == local else { throw LibraryError.invalidInput("本地计划已改变，请重新检查后确认。") }
                                result = try repository.syncTeachingAssignment(connectionID: connection.id, activity: row.activity, page: page)
                                if row.change?.pendingDeadline != nil {
                                    try repository.resolveTeachingDeadline(connectionID: connection.id, key: "plan:\(row.activity.id)", useWebsite: deadlineChoices.contains(row.id))
                                    result = "更新计划 · \(row.title)（已按确认处理截止时间）"
                                }
                            } else { continue }
                            if result.hasPrefix("新增") { added += 1 }; if result.hasPrefix("更新") { changed += 1 }
                            self.record(result, connection, issue: result.contains("待核对")); done.insert(row.id); store?.reload()
                        } catch is CancellationError { throw CancellationError() }
                        catch TeachingWebError.login { throw TeachingWebError.login }
                        catch TeachingWebError.accountMismatch { throw TeachingWebError.accountMismatch }
                        catch { worker.cleanDownload(); self.record("\(row.title)：\(error.localizedDescription)", connection, issue: true) }
                    }
                    try Task.checkCancellation(); completed = true
                } catch is CancellationError { interrupted = true }
                catch {
                    self.record(error.localizedDescription, connection, issue: true)
                    if case TeachingWebError.login = error { self.presentLogin(connection); loginRequired = true; interrupted = true }
                }
                do { try repository.finishTeachingUpdate(connection.id, messages: self.notes[connection.id] ?? [], completed: completed) }
                catch { self.record("更新记录保存失败：\(error.localizedDescription)", connection, issue: true) }
                if interrupted { break courseLoop }
            }
        }
    }
    private func record(_ text: String, _ connection: TeachingConnection, issue: Bool = false) {
        notes[connection.id, default: []].append(TeachingSyncMessage(text, isIssue: issue))
        messages.append(TeachingSyncMessage("\(connection.remoteTitle) · \(text)", isIssue: issue))
    }
    private func sameConfiguration(_ a: TeachingConnection, _ b: TeachingConnection) -> Bool {
        a.courseID == b.courseID && a.remoteCourseID == b.remoteCourseID && a.accountID == b.accountID && a.timeZone == b.timeZone &&
        a.includeMaterials == b.includeMaterials && a.includeAssignments == b.includeAssignments && a.includeExperiments == b.includeExperiments && a.includeHistory == b.includeHistory
    }
    private func presentLogin(_ connection: TeachingConnection) {
        if transport == nil, client.loginState == .needsLogin { showWeb = true }
        else { openCourse(connection.remoteCourseID) }
    }
}
