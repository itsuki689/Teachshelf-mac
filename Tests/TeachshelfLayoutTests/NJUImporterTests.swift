import AppKit
import Foundation
import Testing
import WebKit
import JavaScriptCore
import TeachshelfCore
@testable import Teachshelf

@Suite(.serialized)
@MainActor struct NJUImporterTests {
    @Test func repeatedParserInvocationsKeepTheTableChoiceLocalAndSafelyQuoted() throws {
        let context = try #require(JSContext())
        let script = "/* bundled parser */\n(() => teachshelfSelectedTableID)();\n"
        let choice = "table-\"quoted\"\n'; throw new Error('unexpected'); //"
        let selected = context.evaluateScript(NJUWebImporter.parserInvocation(script, tableID: choice))
        #expect(context.exception == nil)
        #expect(selected?.toString() == choice)
        let automatic = context.evaluateScript(NJUWebImporter.parserInvocation(script))
        #expect(context.exception == nil)
        #expect(automatic?.isNull == true)
        #expect(context.evaluateScript("typeof teachshelfSelectedTableID")?.toString() == "undefined")
    }

    @Test func parserAccessIsLimitedToTheOfficialUndergraduateOrigin() {
        #expect(NJUWebImporter.isOfficialTimetable(URL(string: "https://ehallapp.nju.edu.cn/jwapp/sys/wdkb/*default/index.do#/xskcb")))
        #expect(NJUWebImporter.isOfficialTimetable(URL(string: "https://ehallapp.nju.edu.cn:443/jwapp/sys/wdkb/index.do")))
        for address in ["http://ehallapp.nju.edu.cn/jwapp/sys/wdkb/", "https://ehallapp.nju.edu.cn.evil.invalid/jwapp/sys/wdkb/", "https://ehallapp.nju.edu.cn:8443/jwapp/sys/wdkb/", "https://ehallapp.nju.edu.cn/gsapp/sys/wdkbapp/", "https://authserver.nju.edu.cn/authserver/login", "file:///jwapp/sys/wdkb/"] {
            #expect(!NJUWebImporter.isOfficialTimetable(URL(string: address)), "\(address)")
        }
        #expect(!NJUWebImporter.isOfficialTimetable(nil))
    }

    @Test func offlinePreviewNeedsNoLoginAndClosingDiscardsIt() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-NJU-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sample.json")
        let schedule = UndergraduateSchedule(name: "本科示例", courses: [UndergraduateCourse(name: "数学", weeks: [1, 3], weekday: 1, startSection: 1, timeCount: 1)])
        try JSONEncoder().encode(schedule).write(to: source)
        let importer = NJUWebImporter()
        #expect(importer.webView.url == nil)
        #expect(!importer.hasOpenedLogin)
        #expect(!importer.webView.configuration.websiteDataStore.isPersistent)
        importer.readJSON(at: source)
        #expect(importer.schedule == schedule)
        #expect(importer.webView.url == nil)
        importer.close()
        #expect(importer.schedule == nil)
        importer.readJSON(at: source)
        #expect(importer.schedule == nil)
        #expect(importer.webView.url == nil)
    }
}
