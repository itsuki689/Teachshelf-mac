import SwiftUI
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import TeachshelfCore

/// A native table keeps extended selection and file dragging while drawing the
/// quiet, rounded row surfaces used by the original material library.
struct MaterialListView: NSViewRepresentable {
    let items: [MaterialRecord]
    @Binding var selection: Set<UUID>
    let theme: AppTheme
    let courseName: (UUID?) -> String
    let courseColor: (UUID?) -> Color
    let resolveURL: (MaterialRecord) -> URL?
    let onOpen: (MaterialRecord) -> Void
    let onQuickLook: (MaterialRecord) -> Void
    let onReveal: (MaterialRecord) -> Void
    let onFavorite: (MaterialRecord) -> Void
    let onRemove: (Set<UUID>) -> Void
    var browserRows: [MaterialBrowserRow]?
    var onToggleFolder: ((MaterialFolder) -> Void)?
    var onOpenFolder: ((MaterialFolder) -> Void)?
    var onRenameFolder: ((MaterialFolder) -> Void)?
    var onDissolveFolder: ((MaterialFolder) -> Void)?
    var onMoveToFolder: ((Set<UUID>, UUID) -> Void)?
    private var rows: [MaterialBrowserRow] { browserRows ?? items.map { .file($0) } }
    var editing = false
    var dragData: (Set<UUID>) -> Data? = { _ in nil }
    var onReorder: ((Set<UUID>, UUID?) -> Void)?
    var onGroup: ((Set<UUID>) -> Void)?
    var onExport: ((Set<UUID>) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(items: [MaterialRecord], selection: Binding<Set<UUID>>, theme: AppTheme,
         courseName: @escaping (UUID?) -> String, courseColor: @escaping (UUID?) -> Color,
         resolveURL: @escaping (MaterialRecord) -> URL?, onOpen: @escaping (MaterialRecord) -> Void,
         onQuickLook: @escaping (MaterialRecord) -> Void, onReveal: @escaping (MaterialRecord) -> Void,
         onFavorite: @escaping (MaterialRecord) -> Void, onRemove: @escaping (Set<UUID>) -> Void,
         browserRows: [MaterialBrowserRow]? = nil,
         onToggleFolder: ((MaterialFolder) -> Void)? = nil, onOpenFolder: ((MaterialFolder) -> Void)? = nil,
         onRenameFolder: ((MaterialFolder) -> Void)? = nil, onDissolveFolder: ((MaterialFolder) -> Void)? = nil,
         onMoveToFolder: ((Set<UUID>, UUID) -> Void)? = nil,
         editing: Bool = false, dragData: @escaping (Set<UUID>) -> Data? = { _ in nil },
         onReorder: ((Set<UUID>, UUID?) -> Void)? = nil,
         onGroup: ((Set<UUID>) -> Void)? = nil, onExport: ((Set<UUID>) -> Void)? = nil) {
        self.items = items; _selection = selection; self.theme = theme
        self.courseName = courseName; self.courseColor = courseColor; self.resolveURL = resolveURL
        self.onOpen = onOpen; self.onQuickLook = onQuickLook; self.onReveal = onReveal
        self.onFavorite = onFavorite; self.onRemove = onRemove
        self.browserRows = browserRows; self.onToggleFolder = onToggleFolder; self.onOpenFolder = onOpenFolder
        self.onRenameFolder = onRenameFolder; self.onDissolveFolder = onDissolveFolder; self.onMoveToFolder = onMoveToFolder
        self.editing = editing; self.dragData = dragData; self.onReorder = onReorder
        self.onGroup = onGroup; self.onExport = onExport
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let table = MaterialNativeTable(frame: NSRect(x: 0, y: 0, width: 600, height: 0))
        table.autoresizingMask = [.width]
        table.style = .plain
        table.rowHeight = 62
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .textBackgroundColor
        table.gridStyleMask = []
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("资料列表")

        let columns: [(String, String, CGFloat)] = [
            ("selection", "选择", 36),
            ("name", "名称", 314), ("category", "类别", 80),
            ("size", "大小", 75), ("date", "添加日期", 95), ("favorite", "收藏", 36)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "name" ? 200 : width
            column.maxWidth = identifier == "name" ? 10_000 : width
            column.resizingMask = identifier == "name" ? [.autoresizingMask, .userResizingMask] : []
            column.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.folderClick = { [weak coordinator = context.coordinator] row, doubleClick in
            guard let coordinator, coordinator.parent.rows.indices.contains(row), let folder = coordinator.parent.rows[row].folder else { return false }
            if doubleClick { coordinator.parent.onOpenFolder?(folder) } else { coordinator.parent.onToggleFolder?(folder) }
            return true
        }
        table.doubleAction = #selector(Coordinator.openDoubleClickedRow(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.teachshelfMaterial.identifier)])
        table.keyboardAction = { [weak coordinator = context.coordinator] event in
            coordinator?.handleKey(event) ?? false
        }
        table.contextMenu = { [weak coordinator = context.coordinator] row in
            coordinator?.menu(for: row)
        }
        scroll.documentView = table
        context.coordinator.table = table
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previousRows = coordinator.parent.rows
        coordinator.parent = self
        scroll.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        guard let table = coordinator.table else { return }
        coordinator.synchronizing = true
        table.editingSelection = editing
        table.tableColumn(withIdentifier: .init("selection"))?.title = editing ? "选择" : ""
        table.setDraggingSourceOperationMask(onReorder != nil || onMoveToFolder != nil ? [.copy, .move] : .copy, forLocal: true)
        if !coordinator.hasLoaded || previousRows != rows {
            let oldIDs = previousRows.map(\.id), newIDs = rows.map(\.id)
            let oldSet = Set(oldIDs), newSet = Set(newIDs)
            if coordinator.hasLoaded, !reduceMotion, oldIDs != newIDs, oldSet == newSet {
                var order = oldIDs
                table.beginUpdates()
                for (index, id) in newIDs.enumerated() {
                    if let previous = order.firstIndex(of: id), previous != index {
                        table.moveRow(at: previous, to: index)
                        order.remove(at: previous); order.insert(id, at: index)
                    }
                }
                table.endUpdates()
            } else if coordinator.hasLoaded, !reduceMotion, oldIDs != newIDs, oldIDs.filter(newSet.contains) == newIDs.filter(oldSet.contains) {
                table.beginUpdates()
                table.removeRows(at: IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) }), withAnimation: .effectFade)
                table.insertRows(at: IndexSet(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) }), withAnimation: .effectFade)
                table.endUpdates()
            } else { table.reloadData() }
            coordinator.hasLoaded = true
        }
        coordinator.synchronizeSelection()
        coordinator.refreshVisibleRows()
        coordinator.synchronizing = false
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.table?.enumerateAvailableRowViews { row, _ in
            (row as? MaterialAnimatedRow)?.stopAnimations()
        }
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
        coordinator.table?.keyboardAction = nil
        coordinator.table?.folderClick = nil
        coordinator.table?.contextMenu = nil
        coordinator.table = nil
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: MaterialListView
        fileprivate weak var table: MaterialNativeTable?
        var synchronizing = false
        var hasLoaded = false
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("yyyyMMdd")
            return formatter
        }()

        init(_ parent: MaterialListView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("materialRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialAnimatedRow
                ?? MaterialAnimatedRow(frame: .zero)
            view.identifier = identifier
            view.configure(theme: parent.theme, reduceMotion: parent.reduceMotion)
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
            let view: NSView
            switch identifier.rawValue {
            case "selection":
                view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialSelectionCell ?? MaterialSelectionCell(frame: .zero)
            case "name":
                if parent.rows[row].folder != nil {
                    let folderID = NSUserInterfaceItemIdentifier("folderName")
                    let cell = tableView.makeView(withIdentifier: folderID, owner: self) as? MaterialFolderCell ?? MaterialFolderCell(frame: .zero)
                    cell.identifier = folderID
                    configure(cell, row: parent.rows[row], column: "name")
                    return cell
                }
                view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialNameCell ?? MaterialNameCell(frame: .zero)
            case "category":
                view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialCategoryCell
                    ?? MaterialCategoryCell(frame: .zero)
            case "favorite":
                if parent.rows[row].folder != nil { return nil }
                view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialFavoriteCell
                    ?? MaterialFavoriteCell(frame: .zero)
            default:
                view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialInfoCell
                    ?? MaterialInfoCell(frame: .zero)
            }
            view.identifier = identifier
            configure(view, row: parent.rows[row], column: identifier.rawValue)
            return view
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            parent.rows.indices.contains(row) ? parent.rows[row].title : nil
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing, let table else { return }
            let proposed = ids(for: table.selectedRowIndexes)
            parent.selection = proposed
            // The inspector can reject navigation while its unsaved-change prompt
            // is open. Restore the accepted binding instead of leaving a false highlight.
            if parent.selection != proposed {
                synchronizing = true
                synchronizeSelection()
                synchronizing = false
            }
            refreshVisibleRows()
        }

        func synchronizeSelection() {
            guard let table else { return }
            let indexes = IndexSet(parent.rows.indices.filter { parent.rows[$0].material.map { parent.selection.contains($0.id) } == true })
            if table.selectedRowIndexes != indexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
        }

        func refreshVisibleRows() {
            guard let table else { return }
            table.enumerateAvailableRowViews { rowView, row in
                guard self.parent.rows.indices.contains(row) else { return }
                (rowView as? MaterialAnimatedRow)?.configure(theme: self.parent.theme,
                                                            reduceMotion: self.parent.reduceMotion)
                for column in table.tableColumns.indices {
                    if let view = table.view(atColumn: column, row: row, makeIfNecessary: false) {
                        self.configure(view, row: self.parent.rows[row],
                                       column: table.tableColumns[column].identifier.rawValue)
                    }
                }
            }
        }

        private func configure(_ view: NSView, row: MaterialBrowserRow, column: String) {
            if let cell = view as? MaterialSelectionCell {
                let selected = row.materialIDs.intersection(parent.selection)
                cell.configure(title: row.title, state: selected.isEmpty ? .off : (selected == row.materialIDs ? .on : .mixed), editing: parent.editing, enabled: !row.materialIDs.isEmpty) { [weak self] in
                    guard let self else { return }
                    var ids = self.parent.selection
                    if row.materialIDs.isSubset(of: ids) { ids.subtract(row.materialIDs) } else { ids.formUnion(row.materialIDs) }
                    self.parent.selection = ids
                    self.synchronizing = true; self.synchronizeSelection(); self.refreshVisibleRows(); self.synchronizing = false
                }
            } else if let material = row.material {
                if let cell = view as? MaterialNameCell {
                    cell.configure(material: material, course: parent.courseName(material.courseID), color: parent.courseColor(material.courseID), theme: parent.theme, depth: row.depth)
                } else if let cell = view as? MaterialCategoryCell { cell.configure(material.category, theme: parent.theme) }
                else if let cell = view as? MaterialInfoCell {
                    cell.label.stringValue = column == "size" ? material.sizeLabel : dateFormatter.string(from: material.addedAt)
                    cell.setAccessibilityLabel(cell.label.stringValue)
                } else if let cell = view as? MaterialFavoriteCell {
                    cell.configure(material: material) { [weak self] in self?.parent.onFavorite(material) }
                }
            } else if let folder = row.folder {
                if let cell = view as? MaterialFolderCell {
                    cell.configure(folder: folder, depth: row.depth, expanded: row.isExpanded, count: row.materialIDs.count, theme: parent.theme) { [weak self] in self?.parent.onToggleFolder?(folder) }
                } else if let cell = view as? MaterialCategoryCell { cell.configure("文件夹", theme: parent.theme) }
                else if let cell = view as? MaterialInfoCell {
                    cell.label.stringValue = column == "size" ? "\(row.materialIDs.count) 份资料" : dateFormatter.string(from: folder.createdAt)
                    cell.setAccessibilityLabel(cell.label.stringValue)
                }
            }
        }

        private func ids(for indexes: IndexSet) -> Set<UUID> {
            Set(indexes.flatMap { parent.rows.indices.contains($0) ? Array(parent.rows[$0].materialIDs) : [] })
        }

        private var firstSelectedMaterial: MaterialRecord? {
            guard let row = table?.selectedRowIndexes.first, parent.rows.indices.contains(row) else { return nil }
            return parent.rows[row].material
        }

        @objc func openDoubleClickedRow(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard parent.rows.indices.contains(row) else { return }
            if let folder = parent.rows[row].folder { parent.onOpenFolder?(folder); return }
            guard !parent.editing, let material = parent.rows[row].material else { return }
            guard parent.selection.contains(material.id) else { return }
            parent.onOpen(material)
        }

        func handleKey(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            switch event.keyCode {
            case 49:
                guard let material = firstSelectedMaterial else { return false }
                parent.onQuickLook(material)
            case 36, 76:
                guard let material = firstSelectedMaterial else { return false }
                parent.onOpen(material)
            case 51, 117:
                guard let table, !table.selectedRowIndexes.isEmpty else { return false }
                parent.onRemove(ids(for: table.selectedRowIndexes))
            default: return false
            }
            return true
        }

        func menu(for row: Int) -> NSMenu? {
            guard parent.rows.indices.contains(row), let table else { return nil }
            if let folder = parent.rows[row].folder { return folderMenu(folder, row: parent.rows[row]) }
            guard let material = parent.rows[row].material else { return nil }
            let selected = table.selectedRowIndexes.contains(row) ? ids(for: table.selectedRowIndexes) : [material.id]
            let menu = NSMenu()
            let actions: [(String, Int)] = [("打开资料", 0), ("快速查看", 1), ("在 Finder 中显示", 2),
                                          (material.isFavorite ? "取消收藏" : "收藏", 3)]
            for (title, tag) in actions {
                let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = tag
                item.representedObject = MaterialMenuCommand(id: material.id, ids: selected)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for (title, tag, enabled) in [("移入文件夹…", 5, parent.onGroup != nil), ("导出为 ZIP…", 6, parent.onExport != nil)] where enabled {
                let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = tag; item.representedObject = MaterialMenuCommand(id: material.id, ids: selected)
                menu.addItem(item)
            }
            let remove = NSMenuItem(title: "删除 \(selected.count) 份资料…", action: #selector(runMenuAction(_:)), keyEquivalent: "")
            remove.target = self; remove.tag = 4
            remove.representedObject = MaterialMenuCommand(id: material.id, ids: selected)
            menu.addItem(remove)
            return menu
        }

        private func folderMenu(_ folder: MaterialFolder, row: MaterialBrowserRow) -> NSMenu {
            let menu = NSMenu()
            for (title, tag) in [("进入文件夹", 10), (row.isExpanded ? "收起文件夹" : "展开文件夹", 11), ("重命名…", 12), ("解散文件夹…", 13)] {
                let item = NSMenuItem(title: title, action: #selector(runFolderAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = tag; item.representedObject = folder.id; menu.addItem(item)
            }
            return menu
        }
        @objc private func runFolderAction(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID, let folder = parent.rows.first(where: { $0.id == id })?.folder else { return }
            switch sender.tag {
            case 10: parent.onOpenFolder?(folder)
            case 11: parent.onToggleFolder?(folder)
            case 12: parent.onRenameFolder?(folder)
            case 13: parent.onDissolveFolder?(folder)
            default: break
            }
        }

        @objc private func runMenuAction(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? MaterialMenuCommand,
                  let material = parent.items.first(where: { $0.id == command.id }) else { return }
            switch sender.tag {
            case 0: parent.onOpen(material)
            case 1: parent.onQuickLook(material)
            case 2: parent.onReveal(material)
            case 3: parent.onFavorite(material)
            case 4: parent.onRemove(command.ids)
            case 5: parent.onGroup?(command.ids)
            case 6: parent.onExport?(command.ids)
            default: break
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.rows.indices.contains(row), let material = parent.rows[row].material else { return nil }
            let item = NSPasteboardItem()
            if let url = parent.resolveURL(material) { item.setString(url.absoluteString, forType: .fileURL) }
            if let data = parent.dragData([material.id]) { item.setData(data, forType: NSPasteboard.PasteboardType(UTType.teachshelfMaterial.identifier)) }
            return item
        }

        private func draggedIDs(_ info: NSDraggingInfo) -> Set<UUID> {
            let type = NSPasteboard.PasteboardType(UTType.teachshelfMaterial.identifier)
            return Set((info.draggingPasteboard.pasteboardItems ?? []).flatMap { item -> [UUID] in
                guard let data = item.data(forType: type), let payload = try? JSONDecoder().decode(MaterialDragPayload.self, from: data) else { return [] }
                return payload.ids
            })
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let source = info.draggingSource as? NSTableView, source === tableView else { return [] }
            if parent.rows.indices.contains(row), parent.rows[row].folder != nil, parent.onMoveToFolder != nil {
                tableView.setDropRow(row, dropOperation: .on); return .move
            }
            guard parent.onReorder != nil else { return [] }
            let ids = draggedIDs(info)
            let moving = parent.items.filter { ids.contains($0.id) }
            guard let first = moving.first, moving.allSatisfy({ $0.folderID == first.folderID }),
                  !parent.rows.indices.contains(row) || parent.rows[row].material?.folderID == first.folderID else { return [] }
            tableView.setDropRow(row, dropOperation: .above); return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let source = info.draggingSource as? NSTableView, source === tableView else { return false }
            let ids = draggedIDs(info)
            guard !ids.isEmpty else { return false }
            if parent.rows.indices.contains(row), let folder = parent.rows[row].folder, let move = parent.onMoveToFolder {
                move(ids, folder.id); return true
            }
            guard let reorder = parent.onReorder else { return false }
            reorder(ids, parent.rows.indices.contains(row) ? parent.rows[row].material?.id : nil); return true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            (tableView as? MaterialNativeTable)?.dragStarted = true
        }
    }
}

private final class MaterialMenuCommand: NSObject {
    let id: UUID
    let ids: Set<UUID>
    init(id: UUID, ids: Set<UUID>) { self.id = id; self.ids = ids }
}

private final class MaterialNativeTable: NSTableView {
    var folderClick: ((Int, Bool) -> Bool)?
    var editingSelection = false
    var dragStarted = false
    var keyboardAction: ((NSEvent) -> Bool)?
    var contextMenu: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if keyboardAction?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), index = row(at: convert(event.locationInWindow, from: nil))
        var hit = hitTest(point)
        var hitsButton = false
        while let view = hit, view !== self { if view is NSButton { hitsButton = true; break }; hit = view.superview }
        if !hitsButton, index >= 0, folderClick?(index, event.clickCount == 2) == true { return }
        if editingSelection, index >= 0, event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty {
            var hit = hitTest(point)
            while let view = hit, view !== self {
                if view is NSButton { super.mouseDown(with: event); return }
                hit = view.superview
            }
            let previous = selectedRowIndexes
            dragStarted = false
            super.mouseDown(with: event)
            guard !dragStarted else { return }
            var next = previous
            if next.contains(index) { next.remove(index) } else { next.insert(index) }
            selectRowIndexes(next, byExtendingSelection: false)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

private final class MaterialAnimatedRow: NSTableRowView {
    private let surface = CALayer()
    private var tracking: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []
    private var theme = AppTheme(hex: ColorPalette.defaultAccent)
    private var reduceMotion = false
    private var hovered = false

    override var isSelected: Bool {
        didSet { if oldValue != isSelected { updateSurface(animated: true) } }
    }
    override var isEmphasized: Bool {
        didSet { if oldValue != isEmphasized { updateSurface(animated: true) } }
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        surface.cornerRadius = 10
        surface.borderWidth = 1
        layer?.insertSublayer(surface, at: 0)
        updateSurface(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(theme: AppTheme, reduceMotion: Bool) {
        let changed = self.theme.inkRGB != theme.inkRGB || self.theme.isDark != theme.isDark
            || self.reduceMotion != reduceMotion
        self.theme = theme; self.reduceMotion = reduceMotion
        if reduceMotion { stopAnimations() }
        if changed { updateSurface(animated: false) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.frame = bounds.insetBy(dx: 6, dy: 4)
        CATransaction.commit()
        // Expansion moves existing rows beneath the pointer without a mouse-exit
        // event. Recalculate hover so reused rows do not retain stale highlights.
        let inside = window.map { $0.isKeyWindow && visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        if hovered != inside { hovered = inside; updateSurface(animated: false) }
    }

    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateSurface(animated: true) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateSurface(animated: true) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        hovered = false
        stopAnimations()
        guard let window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.hovered = false; self.stopAnimations(); self.updateSurface(animated: false)
            })
        }
        updateSurface(animated: false)
    }

    func stopAnimations() { surface.removeAllAnimations() }

    private func updateSurface(animated: Bool) {
        let active = window?.isKeyWindow == true
        let ink = NSColor(theme.ink)
        let fill: NSColor
        let border: NSColor
        if isSelected {
            fill = ink.withAlphaComponent(active ? (theme.isDark ? 0.22 : 0.12) : 0.08)
            border = ink.withAlphaComponent(active ? 0.55 : 0.25)
        } else if hovered && active {
            fill = ink.withAlphaComponent(theme.isDark ? 0.12 : 0.055)
            border = ink.withAlphaComponent(0.23)
        } else {
            fill = .clear
            border = NSColor.separatorColor.withAlphaComponent(theme.isDark ? 0.25 : 0.20)
        }
        let shouldAnimate = animated && active && !reduceMotion
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let oldFill = surface.presentation()?.backgroundColor ?? surface.backgroundColor
        let oldBorder = surface.presentation()?.borderColor ?? surface.borderColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.backgroundColor = fill.cgColor
        surface.borderColor = border.cgColor
        CATransaction.commit()
        if shouldAnimate {
            animate("backgroundColor", from: oldFill, to: fill.cgColor)
            animate("borderColor", from: oldBorder, to: border.cgColor)
        } else {
            stopAnimations()
        }
    }

    private func animate(_ key: String, from: CGColor?, to: CGColor) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from; animation.toValue = to
        animation.duration = isSelected ? 0.20 : 0.16
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        surface.add(animation, forKey: key)
    }

    deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }
}

private final class MaterialNameCell: NSTableCellView {
    private let badge = NSView()
    private var indentConstraint: NSLayoutConstraint!
    private let extensionLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let courseLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        badge.wantsLayer = true; badge.layer?.cornerRadius = 8
        extensionLabel.font = .systemFont(ofSize: 8, weight: .bold)
        extensionLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        courseLabel.font = .systemFont(ofSize: 10)
        courseLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, courseLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [badge, titleLabel, courseLabel] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        extensionLabel.translatesAutoresizingMaskIntoConstraints = false; badge.addSubview(extensionLabel)
        indentConstraint = badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        NSLayoutConstraint.activate([
            indentConstraint,
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 34), badge.heightAnchor.constraint(equalToConstant: 40),
            extensionLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            extensionLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            courseLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            courseLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            courseLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 11)
        ])
        textField = titleLabel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(material: MaterialRecord, course: String, color: Color, theme: AppTheme, depth: Int = 0) {
        indentConstraint.constant = 16 + CGFloat(depth) * 22
        titleLabel.stringValue = material.title
        titleLabel.textColor = .labelColor
        courseLabel.stringValue = course
        extensionLabel.stringValue = material.fileExtension.isEmpty ? "FILE" : String(material.fileExtension.prefix(4)).uppercased()
        extensionLabel.textColor = NSColor(AppTheme(hex: color.hexString, dark: theme.isDark).ink)
        badge.layer?.backgroundColor = NSColor(color).withAlphaComponent(theme.isDark ? 0.18 : 0.10).cgColor
        toolTip = material.title
        setAccessibilityLabel("\(material.title)，\(course)，\(material.fileType)")
    }
}

private final class MaterialFolderCell: NSTableCellView {
    private let disclosure = NSButton()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint!
    private var action: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosure.isBordered = false; disclosure.imagePosition = .imageOnly
        disclosure.target = self; disclosure.action = #selector(toggle)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        for label in [titleLabel, detail] { label.lineBreakMode = .byTruncatingTail; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        for view in [disclosure, icon, titleLabel, detail] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        indent = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            indent, disclosure.widthAnchor.constraint(equalToConstant: 16), disclosure.heightAnchor.constraint(equalToConstant: 24), disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor), icon.widthAnchor.constraint(equalToConstant: 34), icon.heightAnchor.constraint(equalToConstant: 34), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12), titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), detail.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor), detail.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 11)
        ])
        textField = titleLabel
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(folder: MaterialFolder, depth: Int, expanded: Bool, count: Int, theme: AppTheme, action: @escaping () -> Void) {
        indent.constant = CGFloat(depth) * 22
        self.action = action
        titleLabel.stringValue = folder.name; detail.stringValue = "\(count) 份资料"
        icon.image = NSImage(systemSymbolName: expanded ? "folder.fill" : "folder", accessibilityDescription: "文件夹")
        icon.contentTintColor = NSColor(theme.ink)
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.setAccessibilityLabel("\(expanded ? "收起" : "展开")文件夹：\(folder.name)")
        setAccessibilityLabel("\(folder.name)，文件夹，\(expanded ? "已展开" : "已收起")，\(count) 份资料")
        toolTip = "单击展开或收起，双击进入文件夹"
    }
    @objc private func toggle() { action?() }
}

private final class MaterialCategoryCell: NSTableCellView {
    private let pill = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pill.wantsLayer = true; pill.layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pill.translatesAutoresizingMaskIntoConstraints = false; addSubview(pill)
        label.translatesAutoresizingMaskIntoConstraints = false; pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4)
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ category: String, theme: AppTheme) {
        label.stringValue = category
        pill.layer?.backgroundColor = NSColor(theme.ink).withAlphaComponent(theme.isDark ? 0.09 : 0.045).cgColor
        toolTip = category; setAccessibilityLabel(category)
    }
}

private final class MaterialInfoCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MaterialSelectionCell: NSTableCellView {
    private let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var action: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.target = self; button.action = #selector(toggle)
        button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
        NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: centerXAnchor), button.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(title: String, state: NSControl.StateValue, editing: Bool, enabled: Bool, action: @escaping () -> Void) {
        button.state = state; button.isHidden = !editing; button.isEnabled = enabled
        button.setAccessibilityLabel("选择：\(title)"); self.action = action
    }
    @objc private func toggle() { action?() }
}

private final class MaterialFavoriteCell: NSTableCellView {
    private let button = NSButton()
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.target = self; button.action = #selector(toggleFavorite(_:))
        button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(material: MaterialRecord, action: @escaping () -> Void) {
        self.action = action
        let title = material.isFavorite ? "取消收藏" : "收藏"
        button.image = NSImage(systemSymbolName: material.isFavorite ? "star.fill" : "star", accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        button.contentTintColor = material.isFavorite ? .systemOrange : .tertiaryLabelColor
        button.toolTip = title; button.setAccessibilityLabel("\(title)：\(material.title)")
    }

    @objc private func toggleFavorite(_ sender: Any?) { action?() }
}
