import AppKit
import WebKit
import TeachshelfCore

enum TeachingWebError: LocalizedError {
    case login, accountMismatch, timeout, unreadable, blocked, download, directFile(URL, String)
    var errorDescription: String? {
        switch self {
        case .login: return "登录已失效或账号无法识别，请在官方网页完成登录后重试。"
        case .accountMismatch: return "当前网站账号与课程绑定账号不同，请在官方网页切换到原账号，或断开连接后重新绑定。"
        case .timeout: return "网站响应超时，请检查网络后重试。"
        case .unreadable: return "页面尚未加载完整或结构无法识别，本次未更新该项目。"
        case .blocked: return "该链接不属于支持的教学网站页面。"
        case .download: return "文件下载未完成，请重新登录或稍后重试。"
        case .directFile: return "该资源为直接下载的文件。"
        }
    }
}

@MainActor protocol TeachingWebsiteTransport: AnyObject {
    func open(_ url: URL)
    func load(_ url: URL) async throws
    func read() async throws -> TeachingPage
    func fetch(_ file: TeachingFile) async throws -> URL
    func cleanDownload()
    func cancel()
}

/// Uses WebKit's session and download transport; optional session restoration uses the local keychain.
@MainActor final class TeachingWebClient: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, TeachingWebsiteTransport {
    let webView: WKWebView
    let loginSession: TeachingLoginSession
    @Published private(set) var loading = false
    @Published private(set) var address = ""
    @Published private(set) var notice = "在官方页面手动完成登录，然后读取课程。"
    @Published private(set) var loginState: TeachingLoginState = .unknown
    private var continuation: CheckedContinuation<Void, Error>?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var loadTimeout: Task<Void, Never>?
    private var downloadTimeout: Task<Void, Never>?
    private var downloadTask: WKDownload?
    private var downloadFolder: URL?
    private var destination: URL?
    private var downloadGeneration: UUID?
    private var loadGeneration: UUID?
    private var closed = false
    private var currentNavigation: WKNavigation?
    private var loginRecovery = TeachingLoginRecovery()
    private var openTask: Task<Void, Never>?
    private var pageGeneration = UUID()

    init(dataStore: WKWebsiteDataStore, root: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        loginSession = TeachingLoginSession(root: root, cookieStore: dataStore.httpCookieStore)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setAccessibilityLabel("南京大学教学网站官方登录与课程页面")
    }

    func open(_ url: URL) {
        guard !closed, TeachingWebsite.allowsNavigation(url), continuation == nil else { return }
        openTask?.cancel(); loginState = .checking
        openTask = Task { [weak self] in
            guard let self else { return }
            await self.loginSession.prepare()
            guard !Task.isCancelled, !self.closed, self.continuation == nil else { return }
            self.loginRecovery.begin(url)
            self.currentNavigation = self.webView.load(URLRequest(url: url))
        }
    }

    func load(_ url: URL) async throws {
        guard !closed, TeachingWebsite.isPage(url), continuation == nil else { throw TeachingWebError.blocked }
        openTask?.cancel()
        await loginSession.prepare()
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        loginRecovery.begin(url); loginState = .checking
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, Error>) in
                continuation = value
                let generation = UUID(); loadGeneration = generation
                loadTimeout = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(35))
                        guard let self, self.loadGeneration == generation else { return }
                        self.completeLoad(.failure(TeachingWebError.timeout)); self.webView.stopLoading()
                    } catch {}
                }
                currentNavigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    static func parserScript() throws -> String {
        guard let path = Bundle.main.url(forResource: "parser", withExtension: "js", subdirectory: "TeachingWebsite") else { throw TeachingWebError.unreadable }
        return try String(contentsOf: path, encoding: .utf8)
    }

    func read() async throws -> TeachingPage {
        guard !closed, !loading else { throw TeachingWebError.unreadable }
        guard TeachingWebsite.isPage(webView.url) else { loginState = .needsLogin; throw TeachingWebError.login }
        let original = webView.url
        let generation = pageGeneration
        let script = try Self.parserScript()
        let result: Any?
        do { result = try await webView.evaluateJavaScript("(\(script))(document, window.location.href)") }
        catch {
            guard !closed, !loading, generation == pageGeneration, original == webView.url else { throw TeachingWebError.unreadable }
            let exception = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
            if exception.contains("登录") { loginState = .needsLogin; loginSession.needsLogin(); throw TeachingWebError.login }
            let known = ["页面结构无法识别，请等待加载完成后重试。", "无法确定该内容所属课程。", "课程内容未加载，未进行更新。", "课程条目缺少名称。", "文件名编码无法读取。", "作业状态未加载，未更新该作业。"]
            if let message = known.first(where: { exception == $0 || exception == "Error: " + $0 }) { throw LibraryError.invalidInput(message) }
            throw TeachingWebError.unreadable
        }
        guard !closed, !loading, generation == pageGeneration, original == webView.url, TeachingWebsite.isPage(webView.url), let text = result as? String,
              text.utf8.count <= 4_000_000, let data = text.data(using: .utf8) else { throw TeachingWebError.unreadable }
        let page = try JSONDecoder().decode(TeachingPage.self, from: data)
        guard !page.accountID.isEmpty, page.activities.count <= 3000, page.files.count <= 3000 else { throw TeachingWebError.unreadable }
        loginState = .signedIn
        loginSession.didAuthenticate()
        return page
    }

    func fetch(_ file: TeachingFile) async throws -> URL {
        guard !closed, TeachingWebsite.isDownload(file.url), downloadContinuation == nil,
              file.name == URL(fileURLWithPath: file.name).lastPathComponent, !file.name.contains("\\"), !file.name.contains("\0") else { throw TeachingWebError.blocked }
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-website-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        downloadFolder = folder; destination = folder.appendingPathComponent(file.name)
        let generation = UUID(); downloadGeneration = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { value in
                downloadContinuation = value
                downloadTimeout = Task { [weak self] in
                    do {
                        for _ in 0..<480 {
                            try await Task.sleep(for: .milliseconds(250))
                            guard let self, self.downloadContinuation != nil, self.downloadGeneration == generation else { return }
                            if (self.downloadTask?.progress.completedUnitCount ?? 0) > 512 * 1_048_576 { self.failDownload(TeachingWebError.download); return }
                        }
                        self?.failDownload(TeachingWebError.timeout)
                    } catch {}
                }
                webView.startDownload(using: URLRequest(url: file.url, cachePolicy: .reloadIgnoringLocalCacheData)) { [weak self] download in
                    guard let self, self.downloadContinuation != nil, self.downloadGeneration == generation, !self.closed else { download.cancel { _ in }; return }
                    self.downloadTask = download; download.delegate = self
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func cleanDownload() {
        if let downloadFolder { try? FileManager.default.removeItem(at: downloadFolder) }
        downloadFolder = nil; destination = nil
    }
    func cancel() {
        openTask?.cancel(); pageGeneration = UUID()
        completeLoad(.failure(CancellationError())); webView.stopLoading()
        loading = false; currentNavigation = nil
        loginRecovery.cancel()
        failDownload(CancellationError())
    }
    func close() { closed = true; cancel(); loginSession.close(); webView.navigationDelegate = nil; webView.uiDelegate = nil }
    private func completeLoad(_ result: Result<Void, Error>) {
        loadGeneration = nil
        loadTimeout?.cancel(); loadTimeout = nil
        let value = continuation; continuation = nil; value?.resume(with: result)
    }
    private func failDownload(_ error: Error) {
        downloadGeneration = nil
        let download = downloadTask; downloadTask = nil
        downloadTimeout?.cancel(); downloadTimeout = nil
        let value = downloadContinuation; downloadContinuation = nil
        download?.cancel { _ in }; cleanDownload(); value?.resume(throwing: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, TeachingWebsite.allowsNavigation(navigationAction.request.url) else {
            notice = "仅打开教学网站与学校统一身份认证的 HTTPS 页面。"
            completeLoad(.failure(TeachingWebError.blocked)); decisionHandler(.cancel); return
        }
        if navigationAction.targetFrame?.isMainFrame == true, navigationAction.request.url?.host == TeachingWebsite.host,
           navigationAction.request.url?.path == "/login/logout.php" { loginRecovery.cancel(); loginSession.needsLogin() }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if continuation != nil, navigationResponse.isForMainFrame, TeachingWebsite.isDownload(navigationResponse.response.url), let url = navigationResponse.response.url {
            completeLoad(.failure(TeachingWebError.directFile(url, navigationResponse.response.suggestedFilename ?? url.lastPathComponent)))
            decisionHandler(.cancel); return
        }
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            completeLoad(.failure(TeachingWebError.unreadable))
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, TeachingWebsite.allowsNavigation(url) { currentNavigation = webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { currentNavigation = navigation; loading = true; pageGeneration = UUID() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === currentNavigation else { return }
        if let next = loginRecovery.next(after: webView.url) {
            loginState = .renewing; notice = "正在尝试学校统一身份认证；需要验证时请在网页完成。"
            currentNavigation = webView.load(URLRequest(url: next)); return
        }
        loading = false; address = webView.url.map { "\($0.host ?? "")\($0.path)" } ?? ""
        if TeachingWebsite.isPage(webView.url) {
            notice = "页面已加载，可读取当前课程。"
            Task { [weak self] in _ = try? await self?.read() }
        }
        else if webView.url?.host == "authserver.nju.edu.cn" || webView.url?.path == "/login/index.php" {
            loginState = .needsLogin; loginSession.needsLogin()
            notice = "学校统一认证需要手动登录或验证。完成后可直接继续更新。"
        } else { loginState = .unknown; notice = "请返回课程首页后读取或更新。" }
        completeLoad(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { guard navigation === currentNavigation else { return }; loading = false; completeLoad(.failure(TeachingWebError.unreadable)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { guard navigation === currentNavigation else { return }; loading = false; notice = "网页未能加载，请检查网络后重试。"; completeLoad(.failure(TeachingWebError.unreadable)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loading = false; cancel(); notice = "网页进程已退出，请重新打开官方页面。" }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard download === downloadTask else { completionHandler(nil); return }
        guard downloadContinuation != nil, TeachingWebsite.isDownload(response.url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              response.expectedContentLength <= 512 * 1_048_576,
              response.mimeType?.lowercased() != "text/html", let destination else {
            completionHandler(nil); failDownload(TeachingWebError.download); return
        }
        completionHandler(destination)
    }
    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        guard download === downloadTask else { decisionHandler(.cancel); return }
        if TeachingWebsite.isDownload(request.url) { decisionHandler(.allow) }
        else { decisionHandler(.cancel); failDownload(TeachingWebError.login) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard download === downloadTask else { return }
        downloadGeneration = nil
        downloadTimeout?.cancel(); downloadTimeout = nil; downloadTask = nil
        let value = downloadContinuation; downloadContinuation = nil
        if let destination { value?.resume(returning: destination) } else { value?.resume(throwing: TeachingWebError.download) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { if download === downloadTask { failDownload(TeachingWebError.download) } }
}
