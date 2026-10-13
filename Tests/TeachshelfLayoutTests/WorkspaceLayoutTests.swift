import AppKit
import SwiftUI
import Testing
import TeachshelfCore
@testable import Teachshelf

@Suite(.serialized)
@MainActor struct WorkspaceLayoutTests {
    @Test func navigationKeepsTheSameMinimumSizeAtNarrowAndWideWidths() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        let course = Course(name: "线性代数与矩阵计算", semester: "2026 秋季")
        try repository.saveCourse(course)
        let source = root.appendingPathComponent("layout-fixture.txt")
        try "Layout regression fixture".write(to: source, atomically: true, encoding: .utf8)
        _ = try repository.importFiles(urls: [source], courseID: course.id, category: "课件", copy: true)
        try repository.saveTask(StudyTask(title: "复习线性变换", courseID: course.id, deadline: Date().addingTimeInterval(86400)))
        let store = AppStore(repository: repository, remembersLocation: false)
        let host = NSHostingView(rootView: ContentView().appTheme().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        // Let AppKit install the SwiftUI title bar before measuring navigation changes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()

        for size in [NSSize(width: 1260, height: 800), NSSize(width: 1020, height: 680)] {
            window.setContentSize(size)
            let originalFrame = window.frame
            for page in [SidebarSelection.all, .calendar, .tasks, .homework, .settings, .all] {
                store.navigate(to: page)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
                #expect(abs(host.fittingSize.width - 1020) < 1, "\(page) at \(size)")
                #expect(abs(host.fittingSize.height - 680) < 1, "\(page) at \(size)")
                #expect(window.frame == originalFrame, "\(page) at \(size)")
                #expect(abs(host.bounds.width - size.width) < 1, "\(page) at \(size)")
                #expect(abs(host.bounds.height - size.height) < 1, "\(page) at \(size)")
                for split in splitViews(in: host) {
                    for pane in [split as NSView] + split.subviews {
                        let rect = pane.convert(pane.bounds, to: host)
                        #expect(rect.maxX <= host.bounds.maxX + 1, "\(page) at \(size): pane overflows the window: \(rect)")
                    }
                }
            }
        }
    }

    private func splitViews(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splitViews(in: $0) }
    }
}
