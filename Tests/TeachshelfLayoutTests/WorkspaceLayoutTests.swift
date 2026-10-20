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
        _ = try repository.importUndergraduateTimetable(UndergraduateSchedule(name: "2026 秋季", courses: [
            UndergraduateCourse(name: "线性代数与矩阵计算", classroom: "教学楼 201", teacher: "", weeks: Array(1...18), weekday: 1, startSection: 3, timeCount: 1)
        ]))
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
            for page in [SidebarSelection.all, .schedule, .tasks, .homework, .settings, .course(course.id), .all] {
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
                if page == .schedule {
                    for hasStartDate in [false, true] {
                        var term = try #require(store.state.timetableTerms.first)
                        let calendar = TimetableTerm.academicCalendar
                        let today = calendar.startOfDay(for: Date())
                        let offset = (calendar.component(.weekday, from: today) + 5) % 7
                        term.weekOneMonday = hasStartDate ? calendar.date(byAdding: .day, value: -offset, to: today) : nil
                        term.cancellations = []
                        try repository.saveTimetableTerm(term)
                        if let monday = term.weekOneMonday, let meeting = term.meetings.first {
                            try repository.cancelTimetableClass(termID: term.id, meetingID: meeting.id, on: monday)
                            store.scheduleSelection.setDate(monday)
                        }
                        store.reload()
                        for mode in ScheduleMode.allCases {
                            store.scheduleSelection.setMode(mode, in: store.state)
                            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                            host.layoutSubtreeIfNeeded()
                            #expect(window.frame == originalFrame, "Switching to \(mode) at \(size) must not resize the window")
                            #expect(abs(host.fittingSize.width - 1020) < 1, "\(mode) at \(size)")
                            #expect(abs(host.fittingSize.height - 680) < 1, "\(mode) at \(size)")
                            for split in splitViews(in: host) {
                                for pane in [split as NSView] + split.subviews {
                                    let rect = pane.convert(pane.bounds, to: host)
                                    #expect(rect.maxX <= host.bounds.maxX + 1, "\(mode) at \(size): pane overflows the window: \(rect)")
                                }
                            }
                        }
                    }
                }
                if page.isLibrary, let materialID = store.visibleMaterials.first?.id {
                    store.selectMaterials([materialID])
                    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                    host.layoutSubtreeIfNeeded()
                    #expect(window.frame == originalFrame, "Opening material details must not resize \(page) at \(size)")
                    #expect(abs(host.fittingSize.width - 1020) < 1)
                    #expect(abs(host.fittingSize.height - 680) < 1)
                    store.selectMaterials([])
                    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                    host.layoutSubtreeIfNeeded()
                    #expect(window.frame == originalFrame, "Closing material details must not resize \(page) at \(size)")
                }
            }
        }
    }

    @Test func materialEditingKeepsTheViewportColumnsAndScrollPositionAtBothWindowWidths() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-edit-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root)
        let course = Course(name: "编辑过渡")
        try repo.saveCourse(course)
        let file = root.appendingPathComponent("资料.txt")
        try "资料".write(to: file, atomically: true, encoding: .utf8)
        _ = try repo.importFiles(urls: [file], courseID: course.id, category: "课件", copy: true)
        for i in 0..<20 {
            let next = root.appendingPathComponent("资料-\(i).txt")
            try "资料".write(to: next, atomically: true, encoding: .utf8)
            _ = try repo.importFiles(urls: [next], courseID: course.id, category: "课件", copy: false)
        }
        let store = AppStore(repository: repo, remembersLocation: false)
        store.navigate(to: .course(course.id))
        let prefs = try #require(UserDefaults(suiteName: "Teachshelf-edit-layout-\(UUID().uuidString)"))
        prefs.set("list", forKey: "libraryPresentation")
        let host = NSHostingView(rootView: LibraryWorkspace().appTheme().environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1017, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.24)); host.layoutSubtreeIfNeeded() }
        for size in [NSSize(width: 1017, height: 700), NSSize(width: 777, height: 580)] {
            window.setContentSize(size); settle()
            let table = try #require(findMaterialTable(in: host))
            let scroll = try #require(table.enclosingScrollView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 124)); scroll.reflectScrolledClipView(scroll.contentView)
            let viewport = scroll.convert(scroll.bounds, to: host)
            let columns = table.tableColumns.indices.map { table.rect(ofColumn: $0) }
            let position = scroll.contentView.bounds.origin
            for editing in [true, false, true, false] {
                store.materialEditing = editing; settle()
                #expect(try #require(findMaterialTable(in: host)) === table)
                #expect(scroll.convert(scroll.bounds, to: host) == viewport)
                #expect(table.tableColumns.indices.map { table.rect(ofColumn: $0) } == columns)
                #expect(scroll.contentView.bounds.origin == position)
                #expect(window.contentView?.bounds.size == size)
            }
        }
    }

    private func findMaterialTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findMaterialTable(in: $0) }.first
    }

    private func splitViews(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splitViews(in: $0) }
    }
}
