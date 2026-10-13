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

    private func list(items: [MaterialRecord], store: AppStore) -> MaterialListView {
        MaterialListView(items: items,
                         selection: Binding(get: { store.selectedMaterialIDs }, set: { store.selectMaterials($0) }),
                         theme: AppTheme(hex: store.state.accentColor),
                         courseName: { store.courseName($0) }, courseColor: { store.courseColor($0) },
                         resolveURL: { try? store.repository.resolveURL($0) },
                         onOpen: { _ in }, onQuickLook: { _ in }, onReveal: { _ in },
                         onFavorite: { _ in }, onRemove: { _ in })
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
