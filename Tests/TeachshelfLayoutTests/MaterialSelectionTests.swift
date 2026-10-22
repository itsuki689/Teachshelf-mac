import AppKit
import SwiftUI
import Testing
import TeachshelfCore
@testable import Teachshelf

@Suite(.serialized)
@MainActor struct MaterialSelectionTests {
    @Test func canceledInspectorNavigationRestoresNativeSelectionAndAllowsMultipleSelection() throws {
        try withTable { store, _, _, table, items in
            table.selectRowIndexes([0], byExtendingSelection: false)
            #expect(store.selectedMaterialIDs == [items[0].id])
            store.beforeLeavingMaterial = { false }
            table.selectRowIndexes([1], byExtendingSelection: false)
            #expect(store.selectedMaterialIDs == [items[0].id])
            #expect(table.selectedRowIndexes == [0])
            store.beforeLeavingMaterial = nil
            table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
            #expect(store.selectedMaterialIDs == Set(items.prefix(2).map(\.id)))
            table.selectAll(nil)
            #expect(store.selectedMaterialIDs == Set(items.map(\.id)))
        }
    }

    @Test func sortingAndFilteringKeepSelectionAttachedToTheFileIdentity() throws {
        try withTable { store, host, _, table, items in
            table.selectRowIndexes([2], byExtendingSelection: false)
            let selectedID = items[2].id
            host.rootView = list(items: Array(items.reversed()), store: store)
            settle(host)
            let reordered = try #require(findTable(in: host))
            #expect(reordered.selectedRowIndexes == [0])
            #expect(store.selectedMaterialIDs == [selectedID])
            host.rootView = list(items: Array(items.prefix(2)), store: store)
            settle(host)
            #expect(try #require(findTable(in: host)).selectedRowIndexes.isEmpty)
            host.rootView = list(items: items, store: store)
            settle(host)
            #expect(try #require(findTable(in: host)).selectedRowIndexes == [2])
            #expect(store.selectedMaterialIDs == [selectedID])
        }
    }

    @Test func editModeCheckboxesAccumulateSelectionAndFollowFileIdentityAfterSorting() throws {
        try withTable { store, host, _, _, items in
            let original = try #require(findTable(in: host))
            let nameColumn = original.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            let originalNameRect = original.rect(ofColumn: nameColumn)
            let originalFrame = original.frame
            host.rootView = list(items: items, store: store, editing: true)
            settle(host)
            let table = try #require(findTable(in: host))
            let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("selection"))
            #expect(column >= 0 && !table.tableColumns[column].isHidden)
            #expect(table.rect(ofColumn: nameColumn) == originalNameRect)
            #expect(table.frame == originalFrame)
            func checkbox(_ row: Int) throws -> NSButton {
                let cell = try #require(table.view(atColumn: column, row: row, makeIfNecessary: true))
                return try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
            }
            try checkbox(0).performClick(nil)
            try checkbox(1).performClick(nil)
            #expect(store.selectedMaterialIDs == Set(items.prefix(2).map(\.id)))
            host.rootView = list(items: Array(items.reversed()), store: store, editing: true)
            settle(host)
            #expect(table.selectedRowIndexes == IndexSet([1, 2]))
            #expect(try checkbox(0).state == .off)
            #expect(try checkbox(1).state == .on)
            host.rootView = list(items: Array(items.reversed()), store: store)
            settle(host)
            #expect(!table.tableColumns[column].isHidden)
            #expect(try checkbox(0).isHidden)
            #expect(table.rect(ofColumn: nameColumn) == originalNameRect)
            #expect(table.frame == originalFrame)
        }
    }

    @Test func folderNavigationScopesSelectionAndSortDoesNotLoseTheSelectedRecord() throws {
        try withTable { store, _, _, _, items in
            let course = Course(name: "资料课程")
            try store.repository.saveCourse(course)
            for var record in items { record.courseID = course.id; try store.repository.updateMaterial(record) }
            let folder = try store.repository.createMaterialFolder(name: "分组", courseID: course.id, materialIDs: [items[0].id])
            store.reload(); store.navigate(to: .course(course.id))
            #expect(!store.visibleMaterials.contains { $0.id == items[0].id })
            store.selectMaterials([items[1].id])
            try store.repository.setMaterialSort(.name, courseID: course.id); store.reload()
            #expect(store.selectedMaterialIDs == [items[1].id])
            store.openMaterialFolder(folder.id)
            #expect(store.selectedMaterialIDs.isEmpty)
            #expect(store.visibleMaterials.map(\.id) == [items[0].id])
            store.materialEditing = true
            store.navigate(to: .all)
            #expect(store.materialFolderID == nil && !store.materialEditing)
        }
    }

    @Test func folderRowsExpandInPlaceWithNestedIndentationAndKeepEmptyFoldersVisible() throws {
        try withTable { store, host, _, _, items in
            let course = Course(name: "树形资料")
            try store.repository.saveCourse(course)
            for var record in items { record.courseID = course.id; try store.repository.updateMaterial(record) }
            let outer = try store.repository.createMaterialFolder(name: "01 复习", courseID: course.id, materialIDs: [items[0].id])
            let inner = try store.repository.createMaterialFolder(name: "练习", courseID: course.id, parentID: outer.id, materialIDs: [items[1].id])
            let empty = try store.repository.createMaterialFolder(name: "02 空文件夹", courseID: course.id)
            store.reload(); store.navigate(to: .course(course.id))
            #expect(store.materialBrowserRows.map(\.id) == [outer.id, empty.id, items[2].id])
            #expect(store.materialBrowserSelectableIDs == Set(items.map(\.id)))
            host.rootView = list(items: store.materialBrowserRows.compactMap(\.material), store: store, editing: true)
            settle(host)
            let table = try #require(findTable(in: host))
            let nameColumn = table.column(withIdentifier: .init("name"))
            let folderCell = try #require(table.view(atColumn: nameColumn, row: 0, makeIfNecessary: true) as? NSTableCellView)
            #expect(folderCell.textField?.stringValue == outer.name)
            let disclosure = try #require(folderCell.subviews.compactMap { $0 as? NSButton }.first)
            disclosure.performClick(nil)
            #expect(store.expandedMaterialFolderIDs.contains(outer.id))
            store.toggleMaterialFolder(inner.id)
            let expanded = store.materialBrowserRows
            #expect(expanded.map(\.id) == [outer.id, inner.id, items[1].id, items[0].id, empty.id, items[2].id])
            #expect(expanded.map(\.depth) == [0, 1, 2, 1, 0, 0])
            host.rootView = list(items: expanded.compactMap(\.material), store: store, editing: true)
            settle(host)
            #expect(table.numberOfRows == 6)
            func titleX(_ row: Int) throws -> CGFloat {
                let cell = try #require(table.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? NSTableCellView)
                return try #require(cell.textField).frame.minX
            }
            #expect(try titleX(2) - titleX(5) == 44)
            #expect(try titleX(3) - titleX(5) == 22)
            let rootRow = try #require(table.rowView(atRow: 5, makeIfNecessary: true) as? MaterialAnimatedRow)
            let childRow = try #require(table.rowView(atRow: 3, makeIfNecessary: true) as? MaterialAnimatedRow)
            let grandchildRow = try #require(table.rowView(atRow: 2, makeIfNecessary: true) as? MaterialAnimatedRow)
            #expect(childRow.highlightFrame.minX - rootRow.highlightFrame.minX == 28)
            #expect(grandchildRow.highlightFrame.minX - rootRow.highlightFrame.minX == 50)
            #expect(childRow.highlightFrame.maxX == rootRow.highlightFrame.maxX)
            #expect(grandchildRow.highlightFrame.maxX == rootRow.highlightFrame.maxX)
            #expect(childRow.layer?.sublayers?.first?.frame == childRow.highlightFrame)
            #expect(grandchildRow.layer?.sublayers?.first?.frame == grandchildRow.highlightFrame)
            let guides = MaterialFolderGuide.project(expanded) { $0.id == outer.id ? "#8058A1" : "#AC633C" }
            #expect(guides.count == 2)
            #expect(guides[0].firstChild == 1 && guides[0].lastChild == 3)
            #expect(guides[1].firstChild == 2 && guides[1].lastChild == 2)
            let native = try #require(table as? MaterialNativeTable)
            native.folderGuideController.update(in: table, guides: guides, reduceMotion: true)
            let outerMarker = try #require(native.folderGuideController.frames[outer.id])
            let innerMarker = try #require(native.folderGuideController.frames[inner.id])
            #expect(outerMarker.maxX < childRow.highlightFrame.minX)
            #expect(innerMarker.maxX < grandchildRow.highlightFrame.minX)
            #expect(outerMarker.minY == table.rect(ofRow: 1).minY + 4)
            #expect(outerMarker.maxY == table.rect(ofRow: 3).maxY - 4)
            #expect(innerMarker.height == table.rowHeight - 8)
            #expect(native.folderGuideController.layer(for: outer.id)?.animationKeys()?.isEmpty != false)
            let selectionColumn = table.column(withIdentifier: .init("selection"))
            let selectionCell = try #require(table.view(atColumn: selectionColumn, row: 0, makeIfNecessary: true))
            try #require(selectionCell.subviews.compactMap { $0 as? NSButton }.first).performClick(nil)
            #expect(store.selectedMaterialIDs == Set(items.prefix(2).map(\.id)))
            store.toggleMaterialFolder(outer.id)
            host.rootView = list(items: store.materialBrowserRows.compactMap(\.material), store: store, editing: true)
            settle(host)
            #expect(table.numberOfRows == 3)
            #expect(native.folderGuideController.frames.isEmpty)
            #expect(store.selectedVisibleMaterialIDs == Set(items.prefix(2).map(\.id)))
            store.openMaterialFolder(outer.id)
            #expect(store.expandedMaterialFolderIDs.isEmpty)
            #expect(store.materialBrowserRows.map(\.id) == [inner.id, items[0].id])
            #expect(store.materialBrowserRows.allSatisfy { $0.depth == 0 })
        }
    }

    @Test func searchingIncludesNestedFilesWithoutMutatingSavedExpansionOrCrossingCourses() throws {
        try withTable { store, _, _, _, items in
            let course = Course(name: "当前"), other = Course(name: "其他")
            try store.repository.saveCourse(course); try store.repository.saveCourse(other)
            for var record in items { record.courseID = course.id; try store.repository.updateMaterial(record) }
            let outer = try store.repository.createMaterialFolder(name: "复习", courseID: course.id)
            let inner = try store.repository.createMaterialFolder(name: "练习", courseID: course.id, parentID: outer.id, materialIDs: [items[1].id])
            _ = try store.repository.createMaterialFolder(name: "其他课程文件夹", courseID: other.id)
            store.reload(); store.navigate(to: .course(course.id)); store.search = items[1].title
            #expect(store.materialBrowserRows.map(\.id) == [outer.id, inner.id, items[1].id])
            #expect(store.materialBrowserRows.map(\.depth) == [0, 1, 2])
            #expect(store.expandedMaterialFolderIDs.isEmpty)
            store.search = ""
            #expect(store.materialBrowserRows.map(\.id) == [outer.id, items[0].id, items[2].id])
            store.navigate(to: .course(other.id))
            #expect(store.materialBrowserRows.count == 1)
            #expect(store.materialBrowserSelectableIDs.isEmpty)
        }
    }

    @Test func hoverHasOnlyOneOwnerAndClearsWithoutMouseExitWhileSelectionSurvives() throws {
        try withTable { store, host, window, rawTable, items in
            let table = try #require(rawTable as? MaterialNativeTable)
            func rows() throws -> [MaterialAnimatedRow] {
                try (0..<3).map { try #require(table.rowView(atRow: $0, makeIfNecessary: true) as? MaterialAnimatedRow) }
            }
            func center(_ index: Int) -> NSPoint {
                let rect = table.rect(ofRow: index)
                return NSPoint(x: 200, y: rect.midY)
            }
            table.updateHoveredRow(at: center(0), animated: false)
            #expect(try rows().map(\.isHovered) == [true, false, false])
            // Jump to another row without delivering mouseExited to the old row.
            table.updateHoveredRow(at: center(2), animated: false)
            #expect(try rows().map(\.isHovered) == [false, false, true])
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.updateHoveredRow(at: nil, animated: false)
            #expect(try rows().allSatisfy { !$0.isHovered })
            #expect(store.selectedMaterialIDs == [items[0].id])
            #expect(try rows()[0].isSelected)
            table.updateHoveredRow(at: center(1), animated: false)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            #expect(try rows().allSatisfy { !$0.isHovered })
            table.updateHoveredRow(at: center(2), animated: false)
            host.rootView = list(items: Array(items.reversed()), store: store)
            settle(host)
            #expect(try rows().allSatisfy { !$0.isHovered })
            #expect(store.selectedMaterialIDs == [items[0].id])
            table.updateHoveredRow(at: center(0), animated: false)
            window.contentView = NSView()
            #expect(try rows().allSatisfy { !$0.isHovered })
        }
    }

    @Test func inspectorOrOtherOverlayCannotLeaveTheCoveredRowHovered() throws {
        try withTable { _, host, _, rawTable, _ in
            let table = try #require(rawTable as? MaterialNativeTable)
            let row = try #require(table.rowView(atRow: 0, makeIfNecessary: true) as? MaterialAnimatedRow)
            let point = NSPoint(x: 220, y: table.rect(ofRow: 0).midY)
            let windowPoint = table.convert(point, to: nil)
            table.updateHoverInWindow(at: windowPoint)
            #expect(row.isHovered)
            let overlay = NSView(frame: table.convert(table.rect(ofRow: 0), to: host))
            host.addSubview(overlay, positioned: .above, relativeTo: nil)
            table.updateHoverInWindow(at: windowPoint)
            #expect(!row.isHovered)
            overlay.removeFromSuperview()
            table.updateHoverInWindow(at: windowPoint)
            #expect(row.isHovered)
            table.updateHoverInWindow(at: NSPoint(x: -10, y: -10))
            #expect(!row.isHovered)
        }
    }

    private func withTable(_ action: (AppStore, NSHostingView<MaterialListView>, NSWindow, NSTableView, [MaterialRecord]) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-material-selection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        var urls: [URL] = []
        for name in ["A.txt", "B.txt", "C.txt"] {
            let url = root.appendingPathComponent(name)
            try name.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        _ = try repository.importFiles(urls: urls, courseID: nil, category: "笔记", copy: true)
        let store = AppStore(repository: repository, remembersLocation: false)
        let items = store.state.materials.sorted { $0.title < $1.title }
        let host = NSHostingView(rootView: list(items: items, store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        settle(host)
        try action(store, host, window, #require(findTable(in: host)), items)
    }

    private func list(items: [MaterialRecord], store: AppStore, editing: Bool = false) -> MaterialListView {
        MaterialListView(items: items,
                         selection: Binding(get: { store.selectedMaterialIDs }, set: { store.selectMaterials($0) }),
                         theme: AppTheme(hex: store.state.accentColor),
                         courseName: { store.courseName($0) }, courseColor: { store.courseColor($0) },
                         resolveURL: { try? store.repository.resolveURL($0) },
                         onOpen: { _ in }, onQuickLook: { _ in }, onReveal: { _ in },
                         onFavorite: { _ in }, onRemove: { _ in },
                         browserRows: store.currentCourseID == nil ? nil : store.materialBrowserRows,
                         onToggleFolder: { store.toggleMaterialFolder($0.id) }, onOpenFolder: { store.openMaterialFolder($0.id) }, editing: editing)
    }

    private func settle(_ host: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable(in: $0) }.first
    }
}
