import AppKit
import Foundation
import SwiftUI
import WebKit
import TeachshelfCore

struct NJUImportTableChoice: Decodable, Identifiable, Hashable {
    let id: String
    let rowCount: Int
    let preview: [String]
}

/// A disposable undergraduate login session. Only the bundled DOM parser runs
/// on the exact official timetable origin; no login fields or cookies are read.
@MainActor final class NJUWebImporter: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var status = "选择学校网页登录，或读取已导出的本科课表 JSON。"
    @Published private(set) var schedule: UndergraduateSchedule?
    @Published private(set) var isReading = false
    @Published private(set) var isLoading = false
    @Published private(set) var hasOpenedLogin = false
    @Published private(set) var sourceDescription = ""
    @Published private(set) var isTimetablePage = false
    @Published private(set) var tableChoices: [NJUImportTableChoice] = []

    let webView: WKWebView
    private var generation = UUID()
    private var closed = false
    private var webActive = false

    static let loginURL = URL(string: "https://authserver.nju.edu.cn/authserver/login?service=https%3A%2F%2Fehallapp.nju.edu.cn%2Fjwapp%2Fsys%2Fwdkb%2F*default%2Findex.do%23%2Fxskcb")!

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setAccessibilityLabel("南京大学官方本科教务登录与课表页面")
    }

    func openLogin() {
        guard !closed, !isReading else { return }
        invalidatePreview()
        webActive = true
        hasOpenedLogin = true
        status = "请在学校官方网页完成登录，选择学期并切换到课表列表。"
        webView.stopLoading()
        webView.load(URLRequest(url: Self.loginURL))
    }

    func readCurrentTimetable(tableID: String? = nil) {
        guard !closed, webActive, !isReading else { return }
        guard Self.isOfficialTimetable(webView.url), !isLoading else {
            status = "请先登录本科教务，打开所需学期的课表列表并等待加载完成。"
            return
        }
        guard let url = Bundle.main.url(forResource: "njubksjw2", withExtension: "js", subdirectory: "Timetable"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            status = "应用缺少本科课表解析资源，请使用完整的 Teachshelf.app。"
            return
        }
        invalidatePreview()
        let token = generation
        isReading = true
        status = "正在读取当前学期课表…"
        // The parser rechecks location inside JavaScript immediately before DOM
        // access, covering navigation between this guard and script execution.
        webView.evaluateJavaScript(Self.parserInvocation(script, tableID: tableID)) { [weak self] result, error in
            guard let self, !self.closed, self.generation == token else { return }
            self.isReading = false
            guard Self.isOfficialTimetable(self.webView.url) else {
                self.status = "网页已离开本科课表，请返回后重新读取。"
                return
            }
            if error != nil {
                // A WebKit error can contain page text or URLs. Show only the
                // parser's user-facing exception, never log request metadata.
                let message = (error as NSError?)?.userInfo["WKJavaScriptExceptionMessage"] as? String
                self.status = message.map { "读取未完成：\($0)" } ?? "无法读取课表，请确认已切换到课表列表后重试。"
                return
            }
            guard let encoded = result as? String,
                  let decoded = encoded.removingPercentEncoding,
                  let data = decoded.data(using: .utf8) else {
                self.status = "课表解析结果格式不正确，请重试。"
                return
            }
            if let choices = try? JSONDecoder().decode(TableDiscovery.self, from: data),
               let tables = choices.tables, !tables.isEmpty {
                self.tableChoices = tables
                self.status = "找到多张不同的课程表，请根据课程名称选择要读取的一张。"
                return
            }
            self.accept(data: data, source: "南京大学本科教务")
        }
    }

    func readJSON(at url: URL) {
        guard !closed else { return }
        invalidatePreview()
        webActive = false
        webView.stopLoading()
        isLoading = false
        isTimetablePage = false
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 5 * 1024 * 1024 else { throw ImportError.invalid("JSON 文件超过 5 MB，请选择本科课表文件。") }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 5 * 1024 * 1024 else { throw ImportError.invalid("JSON 文件超过 5 MB。") }
            accept(data: data, source: "JSON 文件 · \(url.lastPathComponent)")
        } catch {
            status = (error as? ImportError)?.localizedDescription ?? "无法打开 JSON 文件，请检查文件权限与内容。"
        }
    }

    func returnToSource() {
        guard !closed else { return }
        invalidatePreview()
        status = hasOpenedLogin ? "选择学期后重新读取课表，或选择其他 JSON 文件。" : "选择学校网页登录，或读取已导出的本科课表 JSON。"
    }

    func close() {
        closed = true
        invalidatePreview()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func accept(data: Data, source: String) {
        do {
            let value = try JSONDecoder().decode(UndergraduateSchedule.self, from: data)
            guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportError.invalid("缺少学期名称，请重新选择课表。")
            }
            guard !value.courses.isEmpty, value.courses.count <= 5_000 else {
                throw ImportError.invalid("课表为空或课程时段过多，请检查文件。")
            }
            schedule = value
            sourceDescription = source
            status = "已读取 \(value.courses.count) 条课程时段，请核对学期和周次后确认导入。"
        } catch {
            schedule = nil
            status = (error as? ImportError)?.localizedDescription ?? "JSON 不是有效的本科课表格式，需要 name、courses、weeks 与节次字段。"
        }
    }

    private func invalidatePreview() {
        generation = UUID()
        isReading = false
        schedule = nil
        tableChoices = []
    }

    /// Keep the choice local to one invocation; do not add globals to the school page.
    static func parserInvocation(_ script: String, tableID: String? = nil) -> String {
        let literal = tableID.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        var expression = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if expression.hasSuffix(";") { expression.removeLast() }
        return "(() => { const teachshelfSelectedTableID = \(literal); return (\n\(expression)\n); })()"
    }

    private struct TableDiscovery: Decodable { let tables: [NJUImportTableChoice]? }

    static func isOfficialTimetable(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "ehallapp.nju.edu.cn" &&
            (url.port == nil || url.port == 443) && url.path.hasPrefix("/jwapp/sys/wdkb/")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, webActive, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let host = url.host?.lowercased() ?? ""
        let official = url.scheme?.lowercased() == "https" && (host == "nju.edu.cn" || host.hasSuffix(".nju.edu.cn"))
        guard official else {
            status = "登录窗口仅打开南京大学官方 HTTPS 页面。"
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !closed, webActive, navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else { return nil }
        let host = url.host?.lowercased() ?? ""
        if url.scheme?.lowercased() == "https", host == "nju.edu.cn" || host.hasSuffix(".nju.edu.cn") {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !closed, webActive else { return }
        invalidatePreview()
        isLoading = true
        isTimetablePage = false
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !closed, webActive else { return }
        isTimetablePage = Self.isOfficialTimetable(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, webActive else { return }
        isLoading = false
        isTimetablePage = Self.isOfficialTimetable(webView.url)
        status = isTimetablePage ? "已进入本科教务。请选择所需学期，切换到课表列表后点击「读取当前课表」。" : "请在学校官方页面完成登录。"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        guard !closed, webActive else { return }
        isLoading = false
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        status = "学校页面未能加载，请检查网络或校园 VPN 后重新打开登录页。也可以选择本地 JSON 文件。"
    }

    private enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
}
