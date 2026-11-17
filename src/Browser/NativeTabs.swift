import AppKit
import SwiftUI
import QuartzCore

struct MiddlePress {
    private var target: UUID?
    mutating func begin(_ id: UUID?) { target = id }
    mutating func cancel() { target = nil }
    mutating func end(over id: UUID?) -> UUID? {
        defer { target = nil }
        return target != nil && target == id ? target : nil
    }
}

final class TabTable: NSTableView {
    var ids: [UUID] = []
    var theme: ThemeColor = .green
    var middle = MiddlePress()
    var closeTab: ((UUID) -> Void)?
    var tabMenu: ((Int) -> NSMenu?)?
    var animatingRows = false
    var animationRevision = 0
    var dragSource: Int?
    var dragInsertion: Int?
    private(set) var dragID: UUID?
    private var dragOriginalIDs: [UUID] = []
    var applyPreviewOrder: (([UUID]) -> Void)?
    var updateDragPosition: ((NSPoint) -> NSDragOperation)?
    var prepareSelection: (() -> Void)?
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        hoverTracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(hoverTracking!)
    }
    override func mouseExited(with event: NSEvent) { clearHover(); super.mouseExited(with: event) }
    func clearHover(except retained: TabCell? = nil) {
        let visible = rows(in: visibleRect)
        guard visible.location != NSNotFound else { return }
        for index in visible.location..<min(NSMaxRange(visible), numberOfRows) {
            let cell = view(atColumn: 0, row: index, makeIfNecessary: false) as? TabCell
            if let retained, cell === retained { continue }
            if let cell, cell.hovered { cell.setHovered(false, animated: false) }
            (rowView(atRow: index, makeIfNecessary: false) as? TabSelectionRow)?.setPointerHovered(false)
        }
    }
    override func mouseDown(with event: NSEvent) {
        if row(at: convert(event.locationInWindow, from: nil)) >= 0 { prepareSelection?() }
        super.mouseDown(with: event)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        guard sender.draggingSource as? NSTableView === self, dragID != nil else { return operation }
        // AppKit can skip validateDrop at the original row because it considers that a no-op.
        return updateDragPosition?(convert(sender.draggingLocation, from: nil)) ?? operation
    }
    func beginDrag(at row: Int) {
        guard ids.indices.contains(row) else { return }
        middle.cancel()
        dragSource = row; dragInsertion = row
        dragID = ids[row]; dragOriginalIDs = ids
    }
    func previewDrag(to destination: Int?) {
        guard let dragID, let source = ids.firstIndex(of: dragID) else { return }
        var order = dragOriginalIDs
        if let destination {
            guard ids.indices.contains(destination) else { return }
            order = ids
            let id = order.remove(at: source)
            order.insert(id, at: destination)
        }
        if order != ids { applyPreviewOrder?(order) }
        refreshDragPlaceholder()
    }
    func refreshDragPlaceholder() {
        for row in ids.indices {
            let placeholder = ids[row] == dragID
            (view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCell)?.content.isHidden = placeholder
            if let view = rowView(atRow: row, makeIfNecessary: false) as? TabSelectionRow {
                view.dragPlaceholder = placeholder
                view.needsDisplay = true
            }
        }
    }
    func clearDrag() {
        dragSource = nil; dragInsertion = nil; dragID = nil; dragOriginalIDs = []
        refreshDragPlaceholder()
    }
    func endDragPreview() {
        previewDrag(to: nil)
        clearDrag()
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        previewDrag(to: nil); dragInsertion = nil
        super.draggingExited(sender)
    }
    func tab(at event: NSEvent) -> UUID? {
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return nil }
        let index = row(at: point)
        return ids.indices.contains(index) ? ids[index] : nil
    }
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        guard !animatingRows else { middle.cancel(); return }
        middle.begin(tab(at: event))
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        guard !animatingRows else { middle.cancel(); return }
        if let id = middle.end(over: tab(at: event)) { closeTab?(id) }
    }
    override func scrollWheel(with event: NSEvent) { middle.cancel(); clearHover(); super.scrollWheel(with: event) }
    override func reloadData() { middle.cancel(); clearHover(); super.reloadData() }
    override func menu(for event: NSEvent) -> NSMenu? {
        middle.cancel()
        return tabMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

class TabSelectionRow: NSTableRowView {
    static let horizontalInset: CGFloat = 0
    static let verticalInset: CGFloat = 2
    static let rowHeight: CGFloat = 36
    static func highlightHeight(width: CGFloat, rowHeight: CGFloat, compact: Bool) -> CGFloat {
        max(0, rowHeight - 2 * verticalInset)
    }
    var dragPlaceholder = false
    var theme: ThemeColor = .green
    var horizontalInset = TabSelectionRow.horizontalInset
    var verticalInset = TabSelectionRow.verticalInset
    var extraLeadingInset: CGFloat = 0
    private var highlightBounds: NSRect {
        var rect = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        rect.origin.x += extraLeadingInset
        rect.size.width = max(0, rect.width - extraLeadingInset)
        return rect
    }
    private(set) var pointerHovered = false
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    func setPointerHovered(_ value: Bool) {
        pointerHovered = value
        needsDisplay = true
    }
    override func drawBackground(in dirtyRect: NSRect) {
        guard pointerHovered, !isSelected, !dragPlaceholder else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: highlightBounds,
                     xRadius: 8, yRadius: 8).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard !dragPlaceholder, selectionHighlightStyle != .none else { return }
        (theme.mint.blended(withFraction: 0.1, of: theme.accent) ?? theme.mint).setFill()
        NSBezierPath(roundedRect: highlightBounds, xRadius: 8, yRadius: 8).fill()
    }
}

final class TabTitleClipView: NSView {
    private let fade = CAGradientLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        fade.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = fade
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        let start = max(0, 1 - 14 / max(1, bounds.width))
        fade.locations = [0, NSNumber(value: start), 1]
        CATransaction.commit()
    }
}

final class TabCloseButton: NSButton {
    private var tracking: NSTrackingArea?
    private(set) var pointerHovered = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        isBordered = false
        title = ""
        image = nil
        focusRingType = .none
        setAccessibilityLabel("关闭标签页")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { setPointerHovered(true) }
    override func mouseExited(with event: NSEvent) { setPointerHovered(false) }
    func setPointerHovered(_ value: Bool) {
        pointerHovered = value
        layer?.backgroundColor = value ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
    }
    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 3
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: center.x - radius, y: center.y - radius))
        mark.line(to: NSPoint(x: center.x + radius, y: center.y + radius))
        mark.move(to: NSPoint(x: center.x - radius, y: center.y + radius))
        mark.line(to: NSPoint(x: center.x + radius, y: center.y - radius))
        mark.lineWidth = 1.6
        mark.lineCapStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        mark.stroke()
    }
}

final class TabScrollView: NSScrollView {
    var fadesScrollerIn = false
    private var lastScrollTime = Date.distantPast
    private func fadeScrollerIn() {
        guard fadesScrollerIn, let scroller = verticalScroller else { return }
        let now = Date()
        defer { lastScrollTime = now }
        guard now.timeIntervalSince(lastScrollTime) > 0.8,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        scroller.wantsLayer = true
        guard let layer = scroller.layer else { return }
        let mask = layer.mask ?? CALayer()
        mask.frame = layer.bounds
        mask.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        mask.backgroundColor = NSColor.white.cgColor
        layer.mask = mask
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mask.add(fade, forKey: "scrollFadeIn")
    }
    override func scrollWheel(with event: NSEvent) {
        fadeScrollerIn()
        super.scrollWheel(with: event)
    }
    override func flashScrollers() {
        fadeScrollerIn()
        super.flashScrollers()
    }
    override func tile() { super.tile(); fitColumn() }
    override func layout() { super.layout(); fitColumn() }
    private func fitColumn() {
        guard let table = documentView as? NSTableView, let column = table.tableColumns.first,
              contentSize.width > 0 else { return }
        let width = contentSize.width
        if abs(table.frame.width - width) > 0.5 { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
        if abs(column.width - width) > 0.5 { column.width = width }
    }
}

final class TabCell: NSTableCellView {
    let content = NSView()
    let icon = NSImageView()
    let titleClip = TabTitleClipView()
    let label = NSTextField(labelWithString: "")
    let pin = NSImageView()
    let closeButton = TabCloseButton()
    private var normalConstraints: [NSLayoutConstraint] = []
    private var iconLeading: NSLayoutConstraint!
    private var pinWidth: NSLayoutConstraint!
    private var titleTrailingNormal: NSLayoutConstraint!
    private var titleTrailingHovered: NSLayoutConstraint!
    private var compact: Bool?
    private var layoutRevision = 0
    private var hoverRevision = 0
    private(set) var hovered = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("tabCell")
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        icon.wantsLayer = true; icon.layer?.cornerRadius = 4; icon.layer?.masksToBounds = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, titleClip, pin, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        titleClip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: titleClip.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: titleClip.centerYAnchor)
        ])
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            pin.heightAnchor.constraint(equalToConstant: 11),
            closeButton.widthAnchor.constraint(equalToConstant: 20), closeButton.heightAnchor.constraint(equalToConstant: 20)
        ])
        pinWidth = pin.widthAnchor.constraint(equalToConstant: 0)
        titleTrailingNormal = titleClip.trailingAnchor.constraint(equalTo: pin.leadingAnchor, constant: -3)
        titleTrailingHovered = titleClip.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -5)
        titleTrailingNormal.priority = .defaultHigh
        titleTrailingHovered.priority = .defaultHigh
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9)
        normalConstraints = [
            iconLeading,
            titleClip.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            titleClip.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            titleTrailingNormal,
            titleClip.heightAnchor.constraint(equalTo: heightAnchor),
            pinWidth,
            pin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9)
        ]
        closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9).isActive = true
        NSLayoutConstraint.activate(normalConstraints)
        textField = label; imageView = icon
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ value: Bool, animated: Bool = true) {
        if value, let table = enclosingScrollView?.documentView as? TabTable {
            table.clearHover(except: self)
        }
        hovered = value
        (superview as? TabSelectionRow)?.setPointerHovered(value)
        hoverRevision += 1
        let revision = hoverRevision
        let showClose = value && compact == false
        layoutSubtreeIfNeeded()
        if compact == false {
            titleTrailingNormal.isActive = !showClose
            titleTrailingHovered.isActive = showClose
        } else {
            titleTrailingHovered.isActive = false
            titleTrailingNormal.isActive = true
        }
        if showClose { closeButton.isHidden = false }
        closeButton.isEnabled = showClose
        if !showClose { closeButton.setPointerHovered(false) }
        let changes = {
            self.closeButton.alphaValue = showClose ? 1 : 0
            if self.compact != true { self.pin.alphaValue = showClose ? 0 : 1 }
            self.layoutSubtreeIfNeeded()
        }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.allowsImplicitAnimation = true
                changes()
            } completionHandler: { [weak self] in
                guard let self, self.hoverRevision == revision else { return }
                self.closeButton.isHidden = !showClose
            }
        } else {
            changes()
            closeButton.isHidden = !showClose
        }
    }

    func configure(_ tab: Tab, image: NSImage?, compact: Bool, dragPlaceholder: Bool = false) {
        content.isHidden = dragPlaceholder
        if self.compact != compact {
            let animate = self.compact != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            layoutSubtreeIfNeeded()
            layoutRevision += 1
            let revision = layoutRevision
            self.compact = compact
            titleClip.setAccessibilityHidden(compact)
            let details = [pin, closeButton]
            if animate {
                details.forEach { $0.isHidden = false }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.allowsImplicitAnimation = true
                    details.forEach { $0.animator().alphaValue = compact ? 0 : 1 }
                    layoutSubtreeIfNeeded()
                } completionHandler: { [weak self] in
                    guard let self, self.layoutRevision == revision else { return }
                    details.forEach { $0.isHidden = compact }
                }
            } else {
                details.forEach { $0.isHidden = compact; $0.alphaValue = compact ? 0 : 1 }
            }
        }
        label.stringValue = tab.title
        icon.image = tab.chatOwner != nil
            ? NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "Chat")
            : image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "网站")
        icon.setAccessibilityLabel(tab.title)
        pin.image = tab.pinned ? NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "已固定") : nil
        pinWidth.constant = tab.pinned ? 9 : 0
        closeButton.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
        closeButton.toolTip = "关闭 \(tab.title)"
        setHovered(hovered, animated: false)
        toolTip = tab.title + "\n" + tab.address
    }
    func dragImage() -> NSImage {
        layoutSubtreeIfNeeded()
        let size = NSSize(width: max(1, bounds.width - 2), height: bounds.height)
        let snapshot = bitmapImageRepForCachingDisplay(in: bounds)
        if let snapshot { cacheDisplay(in: bounds, to: snapshot) }
        let content = NSImage(size: bounds.size)
        if let snapshot { content.addRepresentation(snapshot) }
        return NSImage(size: size, flipped: true) { bounds in
            let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            NSGraphicsContext.saveGraphicsState()
            card.addClip()
            NSColor(Style.sidebar).withAlphaComponent(0.88).setFill(); card.fill()
            content.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.88,
                         respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(Style.accent).withAlphaComponent(0.38).setStroke()
            card.lineWidth = 1; card.stroke()
            return true
        }
    }
}

struct NativeTabList: NSViewRepresentable {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    var compact = false
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = TabTable()
        table.wantsLayer = true
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = TabSelectionRow.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.draggingDestinationFeedbackStyle = .none
        table.allowsEmptySelection = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.closeTab = { [weak store] id in store?.close(id) }
        table.prepareSelection = { [weak store] in store?.prepareTabSelection?() }
        table.tabMenu = { [weak coordinator = context.coordinator] index in coordinator?.menu(index) }
        table.applyPreviewOrder = { [weak table, weak coordinator = context.coordinator] order in
            guard let table else { return }
            coordinator?.applyPreviewOrder(order, to: table)
        }
        table.updateDragPosition = { [weak table, weak coordinator = context.coordinator] point in
            guard let table else { return [] }
            return coordinator?.updateDragPosition(point, in: table) ?? []
        }
        let scroll = TabScrollView()
        scroll.documentView = table
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.hasVerticalScroller = false
        scroll.useTransientScrollers()
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? TabTable else { return }
        scroll.hasVerticalScroller = false
        context.coordinator.store = store
        context.coordinator.update(table, compact: compact, theme: theme.selection)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var store: Store
        var tabs: [Tab] = []
        var compact = false
        var updating = false
        private var storeIDs: [UUID] = []
        init(store: Store) { self.store = store }
        func update(_ table: TabTable, compact: Bool, theme: ThemeColor) {
            updating = true
            defer { updating = false }
            if table.theme != theme {
                table.theme = theme
                table.enumerateAvailableRowViews { row, _ in
                    if let row = row as? TabSelectionRow { row.theme = theme }
                    row.needsDisplay = true
                }
            }
            let oldIDs = tabs.map(\.id), incomingIDs = store.tabs.map(\.id)
            if table.dragID != nil && incomingIDs != storeIDs { table.clearDrag() }
            let newIDs = table.dragID == nil ? incomingIDs : oldIDs
            let current = Dictionary(uniqueKeysWithValues: store.tabs.map { ($0.id, $0) })
            tabs = newIDs.compactMap { current[$0] }
            storeIDs = incomingIDs
            table.ids = newIDs
            if self.compact != compact {
                table.middle.cancel()
                table.clearHover()
            }
            self.compact = compact
            if oldIDs != newIDs {
                table.middle.cancel()
                let changes = newIDs.difference(from: oldIDs)
                var removed = IndexSet(), inserted = IndexSet()
                for change in changes {
                    switch change {
                    case .remove(let index, _, _): removed.insert(index)
                    case .insert(let index, _, _): inserted.insert(index)
                    }
                }
                table.animationRevision += 1
                let revision = table.animationRevision
                table.animatingRows = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                    table.beginUpdates()
                    table.removeRows(at: removed, withAnimation: [.effectFade, .slideUp])
                    table.insertRows(at: inserted, withAnimation: [.effectFade, .slideDown])
                    table.endUpdates()
                } completionHandler: { [weak table] in
                    guard let table, table.animationRevision == revision else { return }
                    table.animatingRows = false
                }
            }
            if let selected = newIDs.firstIndex(where: { $0 == store.selected }) {
                table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for row in visible.location..<min(NSMaxRange(visible), tabs.count) {
                    (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCell)?
                        .configure(tabs[row], image: store.icons[tabs[row].id], compact: compact,
                                   dragPlaceholder: tabs[row].id == table.dragID)
                }
            }
            table.refreshDragPlaceholder()
        }
        func applyPreviewOrder(_ order: [UUID], to table: TabTable) {
            guard Set(order) == Set(tabs.map(\.id)) else { return }
            updating = true
            defer { updating = false }
            let current = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
            var previous = tabs.map(\.id)
            tabs = order.compactMap { current[$0] }; table.ids = order
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                for (destination, id) in order.enumerated() {
                    let source = previous.firstIndex(of: id)!
                    if source != destination {
                        previous.insert(previous.remove(at: source), at: destination)
                        table.moveRow(at: source, to: destination)
                    }
                }
            }
            if let selected = order.firstIndex(where: { $0 == store.selected }) {
                table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            }
            table.refreshDragPlaceholder()
        }
        func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = TabSelectionRow()
            view.horizontalInset = 2
            view.theme = (tableView as? TabTable)?.theme ?? .green
            view.dragPlaceholder = tabs.indices.contains(row) && tabs[row].id == (tableView as? TabTable)?.dragID
            view.wantsLayer = true
            view.layerContentsRedrawPolicy = .duringViewResize
            view.layer?.needsDisplayOnBoundsChange = true
            return view
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView, tabs.indices.contains(table.selectedRow) else { return }
            store.activate(tabs[table.selectedRow].id)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard tabs.indices.contains(row) else { return nil }
            let cell = (tableView.makeView(withIdentifier: .init("tabCell"), owner: self) as? TabCell) ?? TabCell()
            cell.configure(tabs[row], image: store.icons[tabs[row].id], compact: compact,
                           dragPlaceholder: tabs[row].id == (tableView as? TabTable)?.dragID)
            cell.closeButton.target = self
            cell.closeButton.action = #selector(close(_:))
            return cell
        }
        @objc private func close(_ sender: NSButton) {
            if let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) { store.close(id) }
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard tabs.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(tabs[row].id.uuidString, forType: .string)
            return item
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            guard let table = tableView as? TabTable, let row = rowIndexes.first,
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabCell else { return }
            table.beginDrag(at: row)
            let image = cell.dragImage()
            session.enumerateDraggingItems(options: [], for: table, classes: [NSPasteboardItem.self], searchOptions: [:]) {
                item, _, _ in
                let frame = table.rect(ofRow: row).insetBy(dx: 1, dy: 0)
                item.setDraggingFrame(frame, contents: image)
            }
            session.animatesToStartingPositionsOnCancelOrFail = true
            table.previewDrag(to: row)
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            (tableView as? TabTable)?.endDragPreview()
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let table = tableView as? TabTable, info.draggingSource as? NSTableView === table,
                  table.dragID != nil else { return [] }
            let point = table.convert(info.draggingLocation, from: nil)
            return updateDragPosition(point, in: table)
        }
        func updateDragPosition(_ point: NSPoint, in table: TabTable) -> NSDragOperation {
            guard let dragID = table.dragID,
                  let source = store.tabs.firstIndex(where: { $0.id == dragID }) else { return [] }
            let proposed = Int(floor(point.y / (table.rowHeight + table.intercellSpacing.height)))
            let group = store.tabs.indices.filter { store.tabs[$0].pinned == store.tabs[source].pinned }
            guard let first = group.first, let last = group.last else { return [] }
            let destination = min(max(first, proposed), last)
            let insertion = destination > source ? destination + 1 : destination
            guard store.canMove(dragID, to: insertion) else { return [] }
            table.dragInsertion = insertion
            table.previewDrag(to: destination)
            table.setDropRow(destination, dropOperation: .above)
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let table = tableView as? TabTable, let insertion = table.dragInsertion,
                  let raw = info.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: raw),
                  store.canMove(id, to: insertion) else { return false }
            table.clearDrag()
            store.move(id, to: insertion)
            return true
        }
        func menu(_ row: Int) -> NSMenu? {
            guard tabs.indices.contains(row) else { return nil }
            let tab = tabs[row]
            let menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ title: String, _ action: String, enabled: Bool = true) {
                let item = menu.addItem(withTitle: title, action: #selector(performMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [tab.id.uuidString, action]
                item.isEnabled = enabled
            }
            add("在下方新建标签页", "new")
            menu.addItem(.separator())
            add("重新加载", "reload", enabled: !tab.address.isEmpty)
            add("复制标签页", "duplicate")
            add(tab.pinned ? "取消固定标签页" : "固定标签页", "pin")
            menu.addItem(.separator())
            add("将此标签页加入书签", "bookmark", enabled: !tab.address.isEmpty)
            add("复制网址", "copy", enabled: !tab.address.isEmpty)
            menu.addItem(.separator())
            add("关闭标签页", "close")
            add("关闭其他标签页", "others")
            add("关闭下方标签页", "below")
            menu.addItem(.separator())
            add("重新打开关闭的标签页", "reopen", enabled: !store.recentlyClosed.isEmpty)
            return menu
        }
        @objc private func performMenu(_ sender: NSMenuItem) {
            guard let args = sender.representedObject as? [String], args.count == 2,
                  let id = UUID(uuidString: args[0]), let tab = store.tabs.first(where: { $0.id == id }) else { return }
            switch args[1] {
            case "new": store.newTab(after: id)
            case "reload": store.reload(id)
            case "duplicate": store.newTab(address: tab.address, title: tab.title, after: id)
            case "pin": store.pin(id)
            case "bookmark": _ = store.add(title: tab.title, address: tab.address)
            case "copy": copyAddress(tab.address)
            case "close": store.close(id)
            case "others": store.closeOthers(id)
            case "below": store.closeOthers(id, below: true)
            case "reopen": store.reopen()
            default: break
            }
        }
    }
}
