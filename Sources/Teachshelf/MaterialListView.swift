import SwiftUI
import AppKit
import QuartzCore
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(items: [MaterialRecord], selection: Binding<Set<UUID>>, theme: AppTheme,
         courseName: @escaping (UUID?) -> String, courseColor: @escaping (UUID?) -> Color,
         resolveURL: @escaping (MaterialRecord) -> URL?, onOpen: @escaping (MaterialRecord) -> Void,
         onQuickLook: @escaping (MaterialRecord) -> Void, onReveal: @escaping (MaterialRecord) -> Void,
         onFavorite: @escaping (MaterialRecord) -> Void, onRemove: @escaping (Set<UUID>) -> Void) {
        self.items = items; _selection = selection; self.theme = theme
        self.courseName = courseName; self.courseColor = courseColor; self.resolveURL = resolveURL
        self.onOpen = onOpen; self.onQuickLook = onQuickLook; self.onReveal = onReveal
        self.onFavorite = onFavorite; self.onRemove = onRemove
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
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("资料列表")

        let columns: [(String, String, CGFloat)] = [
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
        table.doubleAction = #selector(Coordinator.openDoubleClickedRow(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
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
        let previousItems = coordinator.parent.items
        coordinator.parent = self
        scroll.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        guard let table = coordinator.table else { return }
        coordinator.synchronizing = true
        if !coordinator.hasLoaded || previousItems != items {
            table.reloadData()
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

        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("materialRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialAnimatedRow
                ?? MaterialAnimatedRow(frame: .zero)
            view.identifier = identifier
            view.configure(theme: parent.theme, reduceMotion: parent.reduceMotion)
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.items.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
            let view: NSView
            switch identifier.rawValue {
            case "name":
                view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialNameCell
                    ?? MaterialNameCell(frame: .zero)
            case "category":
                view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialCategoryCell
                    ?? MaterialCategoryCell(frame: .zero)
            case "favorite":
                view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialFavoriteCell
                    ?? MaterialFavoriteCell(frame: .zero)
            default:
                view = tableView.makeView(withIdentifier: identifier, owner: self) as? MaterialInfoCell
                    ?? MaterialInfoCell(frame: .zero)
            }
            view.identifier = identifier
            configure(view, material: parent.items[row], column: identifier.rawValue)
            return view
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            parent.items.indices.contains(row) ? parent.items[row].title : nil
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
        }

        func synchronizeSelection() {
            guard let table else { return }
            let indexes = IndexSet(parent.items.indices.filter { parent.selection.contains(parent.items[$0].id) })
            if table.selectedRowIndexes != indexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
        }

        func refreshVisibleRows() {
            guard let table else { return }
            table.enumerateAvailableRowViews { rowView, row in
                guard self.parent.items.indices.contains(row) else { return }
                (rowView as? MaterialAnimatedRow)?.configure(theme: self.parent.theme,
                                                            reduceMotion: self.parent.reduceMotion)
                for column in table.tableColumns.indices {
                    if let view = table.view(atColumn: column, row: row, makeIfNecessary: false) {
                        self.configure(view, material: self.parent.items[row],
                                       column: table.tableColumns[column].identifier.rawValue)
                    }
                }
            }
        }

        private func configure(_ view: NSView, material: MaterialRecord, column: String) {
            if let cell = view as? MaterialNameCell {
                cell.configure(material: material, course: parent.courseName(material.courseID),
                               color: parent.courseColor(material.courseID), theme: parent.theme)
            } else if let cell = view as? MaterialCategoryCell {
                cell.configure(material.category, theme: parent.theme)
            } else if let cell = view as? MaterialInfoCell {
                cell.label.stringValue = column == "size" ? material.sizeLabel : dateFormatter.string(from: material.addedAt)
                cell.setAccessibilityLabel(cell.label.stringValue)
            } else if let cell = view as? MaterialFavoriteCell {
                cell.configure(material: material) { [weak self] in
                    guard let self, let current = self.parent.items.first(where: { $0.id == material.id }) else { return }
                    self.parent.onFavorite(current)
                }
            }
        }

        private func ids(for indexes: IndexSet) -> Set<UUID> {
            Set(indexes.compactMap { parent.items.indices.contains($0) ? parent.items[$0].id : nil })
        }

        private var firstSelectedMaterial: MaterialRecord? {
            guard let row = table?.selectedRowIndexes.first, parent.items.indices.contains(row) else { return nil }
            return parent.items[row]
        }

        @objc func openDoubleClickedRow(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard parent.items.indices.contains(row) else { return }
            let material = parent.items[row]
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
            guard parent.items.indices.contains(row), let table else { return nil }
            let material = parent.items[row]
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
            let remove = NSMenuItem(title: "移除 \(selected.count) 份记录…", action: #selector(runMenuAction(_:)), keyEquivalent: "")
            remove.target = self; remove.tag = 4
            remove.representedObject = MaterialMenuCommand(id: material.id, ids: selected)
            menu.addItem(remove)
            return menu
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
            default: break
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.items.indices.contains(row), let url = parent.resolveURL(parent.items[row]) else { return nil }
            return url as NSURL
        }
    }
}

private final class MaterialMenuCommand: NSObject {
    let id: UUID
    let ids: Set<UUID>
    init(id: UUID, ids: Set<UUID>) { self.id = id; self.ids = ids }
}

private final class MaterialNativeTable: NSTableView {
    var keyboardAction: ((NSEvent) -> Bool)?
    var contextMenu: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if keyboardAction?(event) != true { super.keyDown(with: event) }
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
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
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

    func configure(material: MaterialRecord, course: String, color: Color, theme: AppTheme) {
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
