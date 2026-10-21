import AppKit
import Foundation
import Testing
import WebKit
import TeachshelfCore
@testable import Teachshelf

@MainActor @Suite(.serialized) struct TeachingPageParserTests {
    private final class FixturePage: NSObject, WKNavigationDelegate {
        let view: WKWebView
        var loaded: CheckedContinuation<Void, Error>?
        override init() {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
            super.init(); view.navigationDelegate = self
        }
        func load(_ html: String) async throws {
            let timeout = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(15))
                    let value = self?.loaded; self?.loaded = nil; value?.resume(throwing: TeachingWebError.timeout)
                } catch {}
            }
            defer { timeout.cancel(); view.stopLoading() }
            try await withCheckedThrowingContinuation { loaded = $0; view.loadHTMLString(html, baseURL: URL(string: "https://selearning.nju.edu.cn/")) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { let value = loaded; loaded = nil; value?.resume() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { let value = loaded; loaded = nil; value?.resume(throwing: error) }
    }
    private func parse(_ content: String, path: String) async throws -> TeachingPage {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("Resources/TeachingWebsite/parser.js"), encoding: .utf8)
        let fixture = FixturePage()
        let html = """
        <html><body><h1>数据库系统概论</h1>
        <div id="nav-drawer"><a href="https://selearning.nju.edu.cn/course/view.php?id=999">其他课程</a></div>
        <nav><ol class="breadcrumb"><li><a href="https://selearning.nju.edu.cn/course/view.php?id=411">数据库</a></li></ol></nav>
        <main id="region-main">\(content)</main>
        <footer id="page-footer"><a href="https://selearning.nju.edu.cn/user/profile.php?id=123">Account</a></footer>
        <input type="password" value="DO-NOT-READ-LOGIN-FIELD"></body></html>
        """
        try await fixture.load(html)
        let address = String(data: try JSONEncoder().encode("https://selearning.nju.edu.cn" + path), encoding: .utf8)!
        let result = try await fixture.view.evaluateJavaScript("(\(script))(document, \(address))")
        let text = try #require(result as? String)
        #expect(!text.contains("DO-NOT-READ"))
        return try JSONDecoder().decode(TeachingPage.self, from: Data(text.utf8))
    }

    @Test func courseUsesTheCourseTitleAndIgnoresForumsAndOffsiteLinks() async throws {
        let page = try await parse("""
        <h2>主题目录</h2><div class="course-content"><ul>
        <li class="section" id="section-1"><h3 class="sectionname">课件</h3>
        <a href="https://selearning.nju.edu.cn/mod/folder/view.php?id=5282"><span class="instancename">第一章 <span class="accesshide">文件夹</span></span></a>
        <a href="https://selearning.nju.edu.cn/mod/forum/view.php?id=5278">作业已更新</a>
        <a href="https://evil.invalid/mod/folder/view.php?id=9">外站</a></li>
        <li class="section" id="section-2"><h3 class="sectionname">作业</h3>
        <a href="https://selearning.nju.edu.cn/mod/assign/view.php?id=5302"><span class="instancename">作业09</span></a></li>
        <li class="section" id="section-3"><h3 class="sectionname">实验</h3>
        <a href="https://selearning.nju.edu.cn/mod/assign/view.php?id=5721">lab2</a></li>
        </ul></div>
        """, path: "/course/view.php?id=411")
        #expect(page.title == "数据库系统概论")
        #expect(page.accountID == "123" && page.courseID == "411")
        #expect(page.activities.count == 3)
        #expect(page.activities.first?.title == "第一章")
        #expect(page.activities.last?.isExperiment == true)
    }

    @Test func folderPreservesNestedPathsWithoutLeakingQueryParameters() async throws {
        let page = try await parse("""
        <h2>第一章</h2>
        <a href="https://selearning.nju.edu.cn/pluginfile.php/50944/mod_folder/content/0/notes/ch00.pptx?forcedownload=1&amp;sesskey=DO-NOT-PERSIST">ch00</a>
        <a href="https://selearning.nju.edu.cn/pluginfile.php/50944/mod_folder/content/0/notes/ch00.pptx">same</a>
        <a href="https://evil.invalid/pluginfile.php/1/mod_folder/content/0/evil.txt">bad</a>
        """, path: "/mod/folder/view.php?id=5282")
        #expect(page.courseID == "411")
        #expect(page.files.count == 1)
        #expect(page.files.first?.subfolders == ["notes"])
        #expect(page.files.first?.url.query == "forcedownload=1")
        #expect(page.files.first?.name == "ch00.pptx")
    }

    @Test func assignmentReadsDueDateAndIntroAttachmentsWithoutStudentSubmissions() async throws {
        let page = try await parse("""
        <h2>实验 lab2</h2><div id="intro"><p>实验说明</p></div>
        <div class="introattachments"><a href="https://selearning.nju.edu.cn/pluginfile.php/56619/mod_assign/introattachment/0/manual.pdf?forcedownload=1">手册</a></div>
        <table class="generaltable submissionstatustable"><tr><th>作业状态</th><td>已提交请评分</td></tr>
        <tr><th>到期日期</th><td>2026年10月26日 Monday 18:00</td></tr>
        <tr><th>最后修改</th><td>2026年10月20日 Tuesday 17:22</td></tr>
        <tr><th>文件提交</th><td><a href="https://selearning.nju.edu.cn/pluginfile.php/77/assignsubmission_file/submission_files/0/private.zip">个人提交</a></td></tr></table>
        """, path: "/mod/assign/view.php?id=5721")
        #expect(page.deadlineText == "2026年10月26日 Monday 18:00")
        #expect(page.intro == "实验说明" && page.submitted)
        #expect(page.files.count == 1 && page.files.first?.name == "manual.pdf")
    }

    @Test func incompletePagesAndOtherOriginsFailInsteadOfReturningEmptyUpdates() async throws {
        await #expect(throws: (any Error).self) { try await parse("<div>正在加载</div>", path: "/course/view.php?id=411") }
        await #expect(throws: (any Error).self) { try await parse("<h2>作业</h2>", path: "/mod/assign/view.php?id=5302") }
        await #expect(throws: (any Error).self) { try await parse("", path: "/login/index.php") }
    }
}
