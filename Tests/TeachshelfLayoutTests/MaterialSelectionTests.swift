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
            host.rootView = list(items: items, store: store, editing: true)
            settle(host)
            let table = try #require(findTable(in: host))
            let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("selection"))
            #expect(column >= 0 && !table.tableColumns[column].isHidden)
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
            #expect(table.tableColumns[column].isHidden)
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
                         onFavorite: { _ in }, onRemove: { _ in }, editing: editing)
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
