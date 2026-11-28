import AppKit
import SwiftUI
import QuartzCore

struct MiddlePress {
    private(set) var target: UUID?
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
    private var middleDownPoint = NSPoint.zero
    var closeTab: ((UUID) -> Void)?
    var isTabOpen: ((UUID) -> Bool)?
    var tabMenu: ((Int) -> NSMenu?)?
    var animatingRows = false
    var animatingGroups = false
    var animationRevision = 0
    var dragSource: Int?
    var dragInsertion: Int?
    private(set) var dragID: UUID?
    private var dragOriginalIDs: [UUID] = []
    var applyPreviewOrder: (([UUID]) -> Void)?
    var updateDragPosition: ((NSPoint) -> NSDragOperation)?
    var resetGroupPreview: (() -> Void)?
    var groupIDs = Set<UUID>()
    var prepareSelection: (() -> Void)?
    private(set) var pressedID: UUID?
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
    func refreshHover() {
        guard !animatingRows, !animatingGroups, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        clearHover()
        guard visibleRect.contains(point) else { return }
        let index = row(at: point)
        guard index >= 0 else { return }
        (view(atColumn: 0, row: index, makeIfNecessary: false) as? TabCell)?.setHovered(true, animated: false)
    }
    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        pressedID = ids.indices.contains(index) ? ids[index] : nil
        defer { pressedID = nil }
        if pressedID != nil { prepareSelection?() }
        super.mouseDown(with: event)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        guard sender.draggingSource as? NSTableView === self, dragID != nil else { return operation }
        // AppKit can skip validateDrop at the original row because it considers that a no-op.
        return updateDragPosition?(convert(sender.draggingLocation, from: nil)) ?? operation
    }
    func beginDrag(at row: Int) {
        guard !animatingGroups, ids.indices.contains(row) else { return }
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
            (view(atColumn: 0, row: row, makeIfNecessary: false) as? TabGroupCell)?.alphaValue = placeholder ? 0 : 1
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
        resetGroupPreview?()
        previewDrag(to: nil)
        clearDrag()
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        resetGroupPreview?()
        previewDrag(to: nil); dragInsertion = nil
        super.draggingExited(sender)
    }
    func tab(at event: NSEvent) -> UUID? {
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return nil }
        var index = row(at: point)
        // Closing rows retain their artwork, but subsequent presses belong to the next live tab.
        while ids.indices.contains(index) {
            guard !groupIDs.contains(ids[index]) else { return nil }
            if isTabOpen?(ids[index]) != false { return ids[index] }
            index += 1
        }
        return nil
    }
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        guard !animatingGroups, dragID == nil else { middle.cancel(); return }
        middleDownPoint = event.locationInWindow
        middle.begin(tab(at: event))
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        guard !animatingGroups, dragID == nil else { middle.cancel(); return }
        let point = event.locationInWindow
        let stationary = point == middleDownPoint
        let target = stationary && visibleRect.contains(convert(point, from: nil)) ? middle.target : tab(at: event)
        if let id = middle.end(over: target), isTabOpen?(id) != false { closeTab?(id) }
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
    var groupColor: NSColor?
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

final class TabWipeAnimation: NSAnimation {
    private let from: CGFloat
    private let to: CGFloat
    private let changed: @MainActor (CGFloat, Bool) -> Void
    @MainActor init(from: CGFloat, to: CGFloat, duration: TimeInterval? = nil,
                    changed: @escaping @MainActor (CGFloat, Bool) -> Void) {
        self.from = from; self.to = to; self.changed = changed
        super.init(duration: duration ?? TabListContainer.groupAnimationDuration, animationCurve: .easeInOut)
        animationBlockingMode = .nonblocking
        frameRate = Float(NSScreen.main?.maximumFramesPerSecond ?? 60)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var runLoopModesForAnimating: [RunLoop.Mode]? { [.common] }
    override var currentProgress: NSAnimation.Progress {
        get { super.currentProgress }
        set {
            super.currentProgress = newValue
            let value = from + (to - from) * CGFloat(currentValue)
            MainActor.assumeIsolated { changed(value, newValue == 1) }
        }
    }
}

final class TabGroupRailView: NSView {
    var progress: CGFloat = 0 { didSet {
        needsDisplay = true
        if progress != oldValue { changed?() }
    } }
    var changed: (() -> Void)?
    var rowOrigin: CGFloat = 0 { didSet { needsDisplay = true } }
    var expanded = false
    var visibleMemberHeight: CGFloat = 0 { didSet { needsDisplay = true } }
    var retainedMemberHeight: CGFloat = 0
    var expansion: CGFloat = 1 { didSet { needsDisplay = true } }
    var color = NSColor.clear { didSet { needsDisplay = true } }
    private var wipeAnimation: TabWipeAnimation?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { wipeAnimation?.stop() }
    func animate(to target: CGFloat, animated: Bool) {
        wipeAnimation?.stop()
        if !animated { wipeAnimation = nil; progress = target; return }
        wipeAnimation = TabWipeAnimation(from: progress, to: target) { [weak self] value, finished in
            self?.progress = value
            if finished { self?.wipeAnimation = nil }
        }
        wipeAnimation?.start()
    }
    var lineRect: NSRect {
        let inset = 5 + expansion * (TabSelectionRow.rowHeight - 5)
        return NSRect(x: TabListContainer.railGutter - 2 + 5 * expansion, y: rowOrigin + inset, width: 2,
            height: max(0, visibleMemberHeight - retainedMemberHeight * (1 - progress) +
                (TabSelectionRow.rowHeight - inset) * progress - 4))
    }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: lineRect, xRadius: 1, yRadius: 1).fill()
    }
}

final class TabRowWipe: NSView {
    let tab: Tab
    let position: Int
    let following: UUID?
    var closing: Bool
    var transition = 0
    var finished = false
    var progress: CGFloat { didSet { if progress != oldValue { changed?() } } }
    var changed: (() -> Void)?
    private var wipeAnimation: TabWipeAnimation?
    init(tab: Tab, position: Int, following: UUID? = nil, closing: Bool, height: CGFloat) {
        self.tab = tab; self.position = position; self.following = following; self.closing = closing
        progress = closing ? height / TabSelectionRow.rowHeight : 0
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { wipeAnimation?.stop() }
    func animate(to target: CGFloat, completion: @escaping @MainActor () -> Void) {
        wipeAnimation?.stop()
        transition += 1
        finished = false
        let revision = transition
        wipeAnimation = TabWipeAnimation(from: progress, to: target) { [weak self] value, finished in
            guard let self, self.transition == revision else { return }
            self.progress = value
            if finished { self.wipeAnimation = nil; completion() }
        }
        wipeAnimation?.start()
    }
}

final class TabListContainer: NSView {
    static let railGutter: CGFloat = 3
    static let groupAnimationDuration = 0.28
    static let bottomFadeHeight: CGFloat = 18
    let scroll = TabScrollView()
    var expansion: CGFloat = 1 { didSet { railViews.values.forEach { $0.expansion = expansion } } }
    private(set) var rails: [(id: UUID, rows: ClosedRange<Int>, color: NSColor, expanded: Bool, retained: Bool)] = []
    private(set) var railViews: [UUID: TabGroupRailView] = [:]
    private var boundsObserver: NSObjectProtocol?
    private let bottomFade = CAGradientLayer()
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        bottomFade.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        bottomFade.startPoint = CGPoint(x: 0.5, y: 0)
        bottomFade.endPoint = CGPoint(x: 0.5, y: 1)
        addSubview(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in self?.layoutRails() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    override func layout() {
        super.layout()
        // Keep the viewport origin fixed while SwiftUI animates the sidebar width.
        let gutter = Self.railGutter
        scroll.frame = NSRect(x: gutter, y: 0, width: max(0, bounds.width - gutter), height: bounds.height)
        layoutRails()
    }
    private func layoutRails() {
        guard let table = scroll.documentView as? TabTable else { return }
        // Mask the viewport and group rails together without adding a hit-testing overlay.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomFade.frame = bounds
        bottomFade.locations = [0, NSNumber(value: max(CGFloat.zero, CGFloat(1) - Self.bottomFadeHeight / max(CGFloat(1), bounds.height))), 1]
        layer?.mask = table.bounds.maxY > scroll.contentView.bounds.maxY + 1 ? bottomFade : nil
        CATransaction.commit()
        for rail in rails {
            guard let view = railViews[rail.id] else { continue }
            view.frame = bounds
            view.rowOrigin = table.rect(ofRow: rail.rows.lowerBound).minY
            view.visibleMemberHeight = rail.rows.dropFirst().reduce(0) { height, row in
                height + (row < table.numberOfRows ? table.rect(ofRow: row).height : 0)
            }
            // Scrolling changes the viewport offset, not the group's disclosure progress.
            view.bounds.origin.y = table.enclosingScrollView!.contentView.bounds.minY
        }
    }
    func updateRails(_ rails: [(id: UUID, rows: ClosedRange<Int>, color: NSColor, expanded: Bool, retained: Bool)], animated: Bool) {
        let ids = Set(rails.map(\.id))
        for id in Array(railViews.keys) where !ids.contains(id) { railViews.removeValue(forKey: id)?.removeFromSuperview() }
        self.rails = rails
        let animate = animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for rail in rails {
            let view: TabGroupRailView
            if let existing = railViews[rail.id] { view = existing }
            else {
                view = TabGroupRailView()
                view.rowOrigin = CGFloat(rail.rows.lowerBound) * TabSelectionRow.rowHeight
                railViews[rail.id] = view
                addSubview(view, positioned: .above, relativeTo: scroll)
            }
            view.retainedMemberHeight = rail.retained ? TabSelectionRow.rowHeight : 0
            view.color = rail.color
            view.expansion = expansion
            if view.expanded != rail.expanded {
                view.expanded = rail.expanded
                view.animate(to: rail.expanded ? 1 : 0, animated: animate)
            }
        }
        layoutRails()
    }
    func updateRailOrigins() { layoutRails() }
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
        wantsLayer = true
        layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.heightAnchor.constraint(equalToConstant: TabSelectionRow.rowHeight)
        ])
        icon.wantsLayer = true; icon.layer?.cornerRadius = 4; icon.layer?.masksToBounds = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, titleClip, pin, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            view.centerYAnchor.constraint(equalTo: content.centerYAnchor).isActive = true
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
            titleClip.heightAnchor.constraint(equalTo: content.heightAnchor),
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
    override func mouseEntered(with event: NSEvent) {
        guard let table = enclosingScrollView?.documentView as? TabTable,
              !table.animatingRows, !table.animatingGroups else { return }
        setHovered(true)
    }
    override func mouseExited(with event: NSEvent) {
        guard let table = enclosingScrollView?.documentView as? TabTable,
              !table.animatingRows, !table.animatingGroups else { return }
        setHovered(false)
    }
    func setHovered(_ value: Bool, animated: Bool = true, force: Bool = false) {
        (superview as? TabSelectionRow)?.setPointerHovered(value)
        guard hovered != value || force else { return }
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

    func configure(_ tab: Tab, image: NSImage?, compact: Bool, expansion: CGFloat? = nil, dragPlaceholder: Bool = false) {
        let compactChanged = self.compact != compact
        let identityChanged = closeButton.identifier?.rawValue != tab.id.uuidString
        content.isHidden = dragPlaceholder
        setGroupExpansion(tab.groupID == nil ? 0 : (expansion ?? (compact ? 0 : 1)))
        if self.compact != compact {
            let animate = self.compact != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            layoutSubtreeIfNeeded()
            layoutRevision += 1
            let revision = layoutRevision
            self.compact = compact
            titleClip.setAccessibilityHidden(compact)
            // The close button's visibility is owned by setHovered, including during sidebar transitions.
            let details = [pin]
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
        let title = tab.displayTitle
        label.stringValue = title
        let downloadsPage = DownloadsPage.matches(URL(string: tab.address))
        let historyPage = HistoryPage.matches(URL(string: tab.address))
        let symbol: String? = tab.isChat ? "bubble.left.and.bubble.right.fill" :
            historyPage ? "clock.arrow.circlepath" : downloadsPage ? "arrow.down.to.line" :
            SettingsRoute(URL(string: tab.address)) != nil ? "gearshape" :
            tab.address.isEmpty ? "house" : nil
        label.font = .systemFont(ofSize: 12, weight: symbol != nil ? .semibold : .regular)
        icon.imageScaling = .scaleProportionallyUpOrDown
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .medium)
                    .applying(.init(paletteColors: [.labelColor])))
        } else {
            icon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "网站")
        }
        icon.setAccessibilityLabel(title)
        pin.image = tab.pinned ? NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "已固定") : nil
        pinWidth.constant = tab.pinned ? 9 : 0
        closeButton.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
        closeButton.toolTip = "关闭 \(title)"
        setHovered(identityChanged ? false : hovered, animated: false, force: compactChanged)
        toolTip = title + "\n" + tab.address
    }
    func setGroupExpansion(_ expansion: CGFloat) {
        let inset = 9 + 10 * expansion
        guard abs(iconLeading.constant - inset) > 0.0001 else { return }
        iconLeading.constant = inset
        layoutSubtreeIfNeeded()
    }
    func dragImage() -> NSImage {
        let size = NSSize(width: max(1, bounds.width - 2), height: bounds.height)
        return dragPreview(size: size, radius: 9, background: NSColor(Style.sidebar)) ?? NSImage(size: size)
    }
}

final class TabGroupCell: NSTableCellView {
    var group = TabGroup()
    var expansion: CGFloat = 1 { didSet { if expansion != oldValue { needsDisplay = true } } }
    var dropTarget = false { didSet { needsDisplay = true } }
    var toggle: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("tabGroupCell")
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.needsDisplayOnBoundsChange = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityPerformPress() -> Bool { toggle?(); return true }
    func configure(_ group: TabGroup, compact: Bool, expansion: CGFloat, count: Int) {
        self.group = group; self.expansion = expansion
        toolTip = "\(group.name.isEmpty ? "未命名分组" : group.name) · \(count) 个标签页"
        setAccessibilityLabel(toolTip)
        setAccessibilityValue(group.collapsed ? "已折叠" : "已展开")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: 2, dy: 3)
        group.color.color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
        if dropTarget {
            group.color.foreground.setStroke()
            let outline = NSBezierPath(roundedRect: pill.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            outline.lineWidth = 2; outline.stroke()
        }
        if expansion > 0 {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let title = NSAttributedString(string: group.name.isEmpty ? "未命名分组" : group.name,
                attributes: [.font: font,
                             .foregroundColor: group.color.foreground.withAlphaComponent(expansion), .paragraphStyle: paragraph])
            let height = ceil(font.ascender - font.descender + font.leading)
            title.draw(in: NSRect(x: 11, y: bounds.midY - height / 2,
                                 width: max(0, bounds.width - 39), height: height))
        }
        let center = NSPoint(x: 18 + expansion * (bounds.maxX - 33), y: bounds.midY)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: center.x - 3, y: center.y + (group.collapsed ? 2 : -2)))
        arrow.line(to: NSPoint(x: center.x, y: center.y + (group.collapsed ? -1 : 1)))
        arrow.line(to: NSPoint(x: center.x + 3, y: center.y + (group.collapsed ? 2 : -2)))
        arrow.lineWidth = 1.5; arrow.lineCapStyle = .round
        group.color.foreground.setStroke(); arrow.stroke()
    }
}

private struct TabGroupEditor: View {
    @ObservedObject var store: Store
    @FocusState private var editingName: Bool
    let id: UUID
    let dismiss: () -> Void
    var body: some View {
        if let group = store.tabGroups.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("为分组命名", text: Binding(get: {
                    store.tabGroups.first(where: { $0.id == id })?.name ?? ""
                }, set: { store.editTabGroup(id, name: $0) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("分组名称")
                    .focused($editingName).onAppear { editingName = true }
                HStack(spacing: 4) {
                    ForEach(TabGroupColor.allCases, id: \.self) { color in
                        Button { store.editTabGroup(id, color: color) } label: {
                            Circle().fill(Color(color.color)).frame(width: 16, height: 16)
                                .padding(3).overlay(Circle().stroke(group.color == color ? Color.primary : .clear, lineWidth: 1.5))
                        }.buttonStyle(TabGroupMenuButtonStyle()).help(color.name).accessibilityLabel(color.name)
                            .accessibilityValue(group.color == color ? "已选中" : "")
                    }
                }
                Divider()
                action("在组内新建标签页", symbol: "plus") { store.newTab(inGroup: id) }
                action("隐藏分组", symbol: "eye.slash") { store.hideTabGroup(id) }
                action("解散分组", symbol: "rectangle.3.group") { store.ungroup(id) }
                Divider()
                action("删除分组", symbol: "trash") { store.deleteTabGroup(id) }
            }.padding(10).frame(width: 250)
        }
    }
    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button { dismiss(); perform() } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
        }.buttonStyle(TabGroupMenuButtonStyle())
    }
}

private struct TabGroupMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }
    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovered ? 0.09 : 0))
                }
                .background(NativeHoverRegion(changed: { hovered = $0 }))
                .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.1),
                           value: hovered)
        }
    }
}

struct NativeHoverRegion: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> TabGroupMenuHoverView {
        let view = TabGroupMenuHoverView()
        view.changed = changed
        view.updateTrackingAreas()
        return view
    }
    func updateNSView(_ view: TabGroupMenuHoverView, context: Context) { view.changed = changed }
}

final class TabGroupMenuHoverView: NSView {
    var changed: ((Bool) -> Void)?
    private(set) var hovered = false
    private var tracking: NSTrackingArea?
    private var monitor: Any?
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        // Popover-hosted SwiftUI onHover misses events; share native tracking and window event coordinates.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateHover(with: event)
            return event
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Unclipped SwiftUI hosting ancestors can report visibleRect beyond the button's bounds.
        tracking = NSTrackingArea(rect: bounds.intersection(visibleRect), options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    private func updateHover(with event: NSEvent) {
        setHovered(window != nil && event.window === window && !isHiddenOrHasHiddenAncestor &&
                   bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)))
    }
    private func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        changed?(value)
    }
}

struct NativeTabList: NSViewRepresentable {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    var compact = false
    var expansion: CGFloat = 1
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> TabListContainer {
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
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked(_:))
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.closeTab = { [weak store] id in store?.close(id) }
        table.isTabOpen = { [weak store] id in store?.tabs.contains(where: { $0.id == id }) == true }
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
        table.resetGroupPreview = { [weak table, weak coordinator = context.coordinator] in
            guard let table else { return }
            coordinator?.resetGroupPreview(table)
        }
        let container = TabListContainer()
        store.hasWindowedTabList = { [weak container] in container?.window != nil }
        container.expansion = expansion
        let scroll = container.scroll
        scroll.documentView = table
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.hasVerticalScroller = false
        scroll.useTransientScrollers()
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return container
    }
    func updateNSView(_ container: TabListContainer, context: Context) {
        container.expansion = expansion
        let scroll = container.scroll
        guard let table = scroll.documentView as? TabTable else { return }
        scroll.hasVerticalScroller = false
        context.coordinator.store = store
        context.coordinator.expansion = expansion
        context.coordinator.update(table, compact: compact, theme: theme.selection)
        container.needsLayout = true
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var store: Store
        var tabs: [Tab] = [] { didSet { tabByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) }) } }
        private var tabByID: [UUID: Tab] = [:]
        var rows: [TabListRow] = []
        var compact = false
        var expansion: CGFloat = 1
        var updating = false
        private var storeIDs: [UUID] = []
        private var storeRows: [TabListRow] = []
        private var storeMembership: [UUID?] = []
        private var previewTabs: [Tab]?
        private var draggingGroup: UUID?
        private var dropGroup: UUID?
        private var groupDropValid = false
        private weak var table: TabTable?
        private var wipeRows: [Int: (view: TabGroupRailView, offset: Int, count: Int)] = [:]
        private var rowWipes: [UUID: TabRowWipe] = [:]
        private var rowIndexes: [UUID: Int] = [:]
        private var rowHeights: [CGFloat] = []
        private var wipeUpdatePending = false
        private var lastTabs: [Tab]?
        private var lastGroups: [TabGroup] = []
        private var lastIcons: [UUID: NSImage] = [:]
        private var lastSelection: UUID?
        private var lastExpansion: CGFloat = -1
        private(set) var editor: NSPopover?
        init(store: Store) { self.store = store }
        func update(_ table: TabTable, compact: Bool, theme: ThemeColor) {
            updating = true
            defer { updating = false }
            self.table = table
            // SwiftUI also calls this for each viewport-height frame; only changed data needs a new projection.
            if table.dragID == nil, previewTabs == nil, draggingGroup == nil,
               lastTabs == store.tabs, lastGroups == store.tabGroups, lastIcons == store.icons,
               lastSelection == store.selected, self.compact == compact, table.theme == theme {
                if lastExpansion != expansion {
                    lastExpansion = expansion
                    updateWipeHeights(table, refreshDecoration: true)
                }
                return
            }
            if table.theme != theme {
                table.theme = theme
                table.enumerateAvailableRowViews { row, _ in
                    if let row = row as? TabSelectionRow { row.theme = theme }
                    row.needsDisplay = true
                }
            }
            let incomingIDs = store.tabs.map(\.id)
            var startingWipes: [TabRowWipe] = []
            if !storeIDs.isEmpty, table.window != nil, table.dragID == nil,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               let container = table.enclosingScrollView?.superview {
                let incoming = Set(incomingIDs), previous = Set(storeIDs)
                for tab in tabs where !incoming.contains(tab.id) {
                    guard let position = rows.firstIndex(of: .tab(tab.id)) else { continue }
                    let height = table.rect(ofRow: position).height
                    rowWipes.removeValue(forKey: tab.id)?.removeFromSuperview()
                    let following = rows.indices.contains(position + 1) ? rows[position + 1].id : nil
                    let wipe = TabRowWipe(tab: tab, position: position, following: following, closing: true, height: height)
                    rowWipes[tab.id] = wipe; container.addSubview(wipe); startingWipes.append(wipe)
                }
                for tab in store.tabs where !previous.contains(tab.id) {
                    let wipe = rowWipes[tab.id] ?? TabRowWipe(tab: tab, position: 0, closing: false, height: 0)
                    wipe.closing = false
                    rowWipes[tab.id] = wipe; container.addSubview(wipe); startingWipes.append(wipe)
                }
            }
            if table.dragID != nil && (incomingIDs != storeIDs || store.tabRows != storeRows ||
                                      store.tabs.map(\.groupID) != storeMembership) {
                table.clearDrag(); previewTabs = nil; draggingGroup = nil; groupDropValid = false
            }
            if let previewTabs {
                let current = Dictionary(uniqueKeysWithValues: store.tabs.map { ($0.id, $0) })
                tabs = previewTabs.compactMap { preview in
                    guard var tab = current[preview.id] else { return nil }
                    tab.groupID = preview.groupID
                    return tab
                }
            } else if table.dragID == nil { tabs = store.tabs }
            else {
                let current = Dictionary(uniqueKeysWithValues: store.tabs.map { ($0.id, $0) })
                tabs = tabs.compactMap { current[$0.id] }
            }
            storeIDs = incomingIDs
            storeRows = store.tabRows
            storeMembership = store.tabs.map(\.groupID)
            if self.compact != compact {
                table.middle.cancel()
                table.clearHover()
            }
            self.compact = compact
            lastTabs = store.tabs; lastGroups = store.tabGroups; lastIcons = store.icons
            lastSelection = store.selected; lastExpansion = expansion
            render(table)
            if !startingWipes.isEmpty { table.clearHover(); table.animatingRows = true }
            for wipe in startingWipes {
                wipe.changed = { [weak self, weak table, weak wipe] in
                    guard let self, let table, let wipe, self.rowWipes[wipe.tab.id] === wipe else { return }
                    self.scheduleWipeUpdate(table)
                }
            }
            for wipe in startingWipes {
                wipe.animate(to: wipe.closing ? 0 : 1) { [weak self, weak table, weak wipe] in
                    guard let self, let table, let wipe, self.rowWipes[wipe.tab.id] === wipe else { return }
                    wipe.finished = true
                    self.scheduleWipeUpdate(table)
                }
            }
            finishPageInsertions()
        }

        private func finishPageInsertions() {
            let ready = store.pendingInternalPageLoads.filter { storeIDs.contains($0) && rowWipes[$0] == nil }
            guard !ready.isEmpty else { return }
            // Give the native layout transaction its own turn before creating any WebKit views.
            DispatchQueue.main.async { [weak store] in
                for id in ready { store?.tabInsertionDidFinish(id) }
            }
        }

        private func displayedRows(_ table: TabTable) -> [TabListRow] {
            var result = TabListRow.rows(tabs: tabs, groups: store.openTabGroups, selected: store.selected, draggingGroup: draggingGroup)
            // Retain outgoing members until their wipe reaches zero; keep the active temporary row visible.
            if let container = table.enclosingScrollView?.superview as? TabListContainer,
               container.window != nil, table.dragID == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for group in store.openTabGroups where group.collapsed &&
                    (container.railViews[group.id]?.progress ?? 0) > 0 {
                    guard let header = result.firstIndex(of: .group(group.id)) else { continue }
                    let members = tabs.filter { $0.groupID == group.id }
                    if members.contains(where: { $0.id == store.selected }) { result.remove(at: header + 1) }
                    result.insert(contentsOf: members.map { .tab($0.id) }, at: header + 1)
                }
            }
            for wipe in rowWipes.values.filter(\.closing).sorted(by: { $0.position > $1.position }) {
                let index = wipe.following.flatMap { next in result.firstIndex { $0.id == next } }
                result.insert(.tab(wipe.tab.id), at: index ?? min(wipe.position, result.count))
            }
            return result
        }
        private func render(_ table: TabTable) {
            let oldIDs = rows.map(\.id)
            rows = displayedRows(table)
            rowIndexes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            let container = table.enclosingScrollView?.superview as? TabListContainer
            let newIDs = rows.map(\.id)
            table.ids = newIDs
            table.groupIDs = Set(store.openTabGroups.map(\.id))
            if let container {
                container.railViews.values.forEach { $0.changed = nil }
                let railTabs = tabs + rowWipes.values.filter(\.closing).map(\.tab)
                let counts = railTabs.reduce(into: [UUID: Int]()) { counts, tab in
                    if let id = tab.groupID { counts[id, default: 0] += 1 }
                }
                container.updateRails(rows.indices.compactMap { start in
                    guard case .group(let id) = rows[start],
                          let group = store.tabGroups.first(where: { $0.id == id }) else { return nil }
                    let count = counts[id, default: 0]
                    var end = start
                    while end + 1 < rows.count, case .tab(let tabID) = rows[end + 1],
                          displayedTab(tabID)?.groupID == id { end += 1 }
                    return count > 0 ? (id: id, rows: start...end, color: group.color.color,
                                        expanded: !group.collapsed && draggingGroup != id,
                                        retained: tabs.contains { $0.id == store.selected && $0.groupID == id }) : nil
                }, animated: !oldIDs.isEmpty && table.dragID == nil)
                wipeRows = [:]
                var offsets: [UUID: Int] = [:]
                let membership = Dictionary(uniqueKeysWithValues: railTabs.map { ($0.id, $0.groupID) })
                let selectedGroup = tabs.first { $0.id == store.selected }?.groupID
                for (row, entry) in rows.enumerated() {
                    guard case .tab(let id) = entry, let groupID = membership[id] ?? nil,
                          let view = container.railViews[groupID],
                          id != store.selected else { continue }
                    let sticky = selectedGroup == groupID
                    wipeRows[row] = (view, offsets[groupID, default: 0], counts[groupID, default: 0] - (sticky ? 1 : 0))
                    offsets[groupID, default: 0] += 1
                }
            }
            if oldIDs != newIDs {
                let oldSet = Set(oldIDs), newSet = Set(newIDs)
                // Finishing a neighboring close must not cancel a stationary press on a live tab.
                if oldIDs.filter(newSet.contains) != newIDs.filter(oldSet.contains) { table.middle.cancel() }
                let removed = IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) })
                let inserted = IndexSet(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) })
                var previous = oldIDs.filter { newSet.contains($0) }
                for index in inserted {
                    previous.insert(newIDs[index], at: index)
                }
                table.animationRevision += 1
                let revision = table.animationRevision
                table.animatingRows = true
                NSAnimationContext.runAnimationGroup { context in
                    // Disclosure already animates row heights; a second row-frame animation would rebound on reversal.
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ||
                        !rowWipes.isEmpty || (!table.groupIDs.isEmpty && table.dragID == nil) ? 0 : 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    table.beginUpdates()
                    table.removeRows(at: removed, withAnimation: [])
                    table.insertRows(at: inserted, withAnimation: [])
                    table.endUpdates()
                    for (destination, id) in newIDs.enumerated() {
                        let source = previous.firstIndex(of: id)!
                        if source != destination {
                            previous.insert(previous.remove(at: source), at: destination)
                            table.moveRow(at: source, to: destination)
                        }
                    }
                } completionHandler: { [weak self, weak table] in
                    MainActor.assumeIsolated {
                        guard let self, let table, table.animationRevision == revision else { return }
                        table.animatingRows = !self.rowWipes.isEmpty
                        table.refreshHover()
                    }
                }
            }
            if let selected = newIDs.firstIndex(where: { $0 == store.selected }) {
                table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for row in visible.location..<min(NSMaxRange(visible), rows.count) {
                    configure(table.view(atColumn: 0, row: row, makeIfNecessary: false), row: row, table: table)
                    if let view = table.rowView(atRow: row, makeIfNecessary: false) as? TabSelectionRow {
                        decorate(view, row: row)
                    }
                }
            }
            rowHeights = rows.indices.map { table.rect(ofRow: $0).height }
            updateWipeHeights(table, allRows: true)
            container?.railViews.values.forEach { view in
                view.changed = { [weak self, weak table, weak view] in
                    guard let self, let table, let view else { return }
                    // The rail draws its progress directly, so its row geometry must update in the same callback.
                    if view.progress == 0 && !view.expanded {
                        let wasUpdating = self.updating
                        self.updating = true
                        self.render(table)
                        self.updating = wasUpdating
                    } else { self.updateWipeHeights(table, refreshDecoration: true) }
                }
            }
            table.refreshDragPlaceholder()
            // A zero-duration update can finish while progress callbacks are being reconfigured.
            if rows != displayedRows(table) { render(table) }
        }
        private func scheduleWipeUpdate(_ table: TabTable) {
            guard !wipeUpdatePending else { return }
            wipeUpdatePending = true
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self, let table else { return }
                self.wipeUpdatePending = false
                let finished = self.rowWipes.values.filter(\.finished)
                for wipe in finished {
                    wipe.changed = nil
                    self.rowWipes[wipe.tab.id] = nil
                    wipe.removeFromSuperview()
                }
                let wasUpdating = self.updating
                self.updating = true
                if !finished.isEmpty { self.render(table) }
                else { self.updateWipeHeights(table) }
                self.updating = wasUpdating
                table.animatingRows = !self.rowWipes.isEmpty
                table.refreshHover()
                if !finished.isEmpty { self.finishPageInsertions() }
            }
        }
        private func updateWipeHeights(_ table: TabTable, allRows: Bool = false, refreshDecoration: Bool = false) {
            let wasUpdating = updating
            updating = true
            defer { updating = wasUpdating }
            let container = table.enclosingScrollView?.superview as? TabListContainer
            let groupsWereAnimating = table.animatingGroups
            table.animatingGroups = container?.railViews.values.contains { $0.progress != ($0.expanded ? 1 : 0) } == true
            if !groupsWereAnimating && table.animatingGroups { table.clearHover() }
            var candidates = allRows ? IndexSet(rows.indices) : IndexSet(wipeRows.keys)
            for id in rowWipes.keys { if let row = rowIndexes[id] { candidates.insert(row) } }
            var changed = IndexSet()
            for row in candidates where row < rowHeights.count && row < table.numberOfRows {
                let height = tableView(table, heightOfRow: row)
                if abs(rowHeights[row] - height) > 0.0001 {
                    rowHeights[row] = height
                    changed.insert(row)
                }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
                table.layoutSubtreeIfNeeded()
                // A row wipe changes geometry only; group disclosure and sidebar width change decoration.
                guard allRows || refreshDecoration else { return }
                table.enumerateAvailableRowViews { view, row in
                    guard self.rows.indices.contains(row) else { return }
                    switch self.rows[row] {
                    case .tab(let id):
                        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCell)?
                            .setGroupExpansion(self.groupExpansion(id))
                        if let view = view as? TabSelectionRow { self.decorate(view, row: row) }
                    case .group:
                        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabGroupCell)?
                            .expansion = self.expansion
                    }
                }
            }
            container?.updateRailOrigins()
            if groupsWereAnimating && !table.animatingGroups { table.refreshHover() }
        }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if rows.indices.contains(row), let wipe = rowWipes[rows[row].id] {
                return max(0.001, TabSelectionRow.rowHeight * wipe.progress)
            }
            guard let wipe = wipeRows[row] else { return TabSelectionRow.rowHeight }
            return max(0.001, min(TabSelectionRow.rowHeight,
                (CGFloat(wipe.count) * wipe.view.progress - CGFloat(wipe.offset)) * TabSelectionRow.rowHeight))
        }
        func applyPreviewOrder(_ order: [UUID], to table: TabTable) {
            guard Set(order) == Set(tabs.map(\.id)) else { return }
            updating = true
            defer { updating = false }
            let current = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
            var previous = tabs.map(\.id)
            tabs = order.compactMap { current[$0] }; table.ids = order
            rows = order.map { .tab($0) }
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
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        private func decorate(_ view: TabSelectionRow, row: Int) {
            var color: NSColor?
            var inset: CGFloat = 0
            if rows.indices.contains(row), case .tab(let id) = rows[row],
               let groupID = displayedTab(id)?.groupID,
               let group = store.tabGroups.first(where: { $0.id == groupID }) {
                color = compact || groupExpansion(id) == 0 ? nil : group.color.color
                inset = 7 * groupExpansion(id)
            }
            guard view.groupColor != color || view.extraLeadingInset != inset else { return }
            view.groupColor = color; view.extraLeadingInset = inset
            view.needsDisplay = true
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = TabSelectionRow()
            view.horizontalInset = 2
            view.theme = (tableView as? TabTable)?.theme ?? .green
            view.dragPlaceholder = rows.indices.contains(row) && rows[row].id == (tableView as? TabTable)?.dragID
            decorate(view, row: row)
            view.wantsLayer = true
            view.layerContentsRedrawPolicy = .duringViewResize
            view.layer?.needsDisplayOnBoundsChange = true
            return view
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? TabTable else { return }
            let id: UUID
            if let pressed = table.pressedID {
                guard !table.groupIDs.contains(pressed), tabs.contains(where: { $0.id == pressed }) else { return }
                id = pressed
            } else {
                guard rows.indices.contains(table.selectedRow), case .tab(let selected) = rows[table.selectedRow] else { return }
                id = selected
            }
            store.activate(id)
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard rows.indices.contains(row) else { return false }
            if case .group = rows[row] { return false }
            return true
        }
        @objc func clicked(_ sender: TabTable) {
            guard !updating, sender.dragID == nil else { return }
            let id = sender.pressedID ?? (rows.indices.contains(sender.clickedRow) ? rows[sender.clickedRow].id : nil)
            guard let id, sender.groupIDs.contains(id) else { return }
            store.toggleTabGroup(id)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let table = tableView as? TabTable else { return nil }
            if case .group = rows[row] {
                let cell = (table.makeView(withIdentifier: .init("tabGroupCell"), owner: self) as? TabGroupCell) ?? TabGroupCell()
                configure(cell, row: row, table: table)
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: .init("tabCell"), owner: self) as? TabCell) ?? TabCell()
            configure(cell, row: row, table: table)
            cell.closeButton.target = self
            cell.closeButton.action = #selector(close(_:))
            return cell
        }
        private func configure(_ view: NSView?, row: Int, table: TabTable) {
            switch rows[row] {
            case .tab(let id):
                guard let tab = displayedTab(id) else { return }
                (view as? TabCell)?.configure(tab, image: store.icons[id], compact: compact, expansion: groupExpansion(id),
                                             dragPlaceholder: id == table.dragID)
            case .group(let id):
                guard var group = store.tabGroups.first(where: { $0.id == id }) else { return }
                if draggingGroup == id { group.collapsed = true }
                (view as? TabGroupCell)?.configure(group, compact: compact, expansion: expansion,
                                                 count: tabs.filter { $0.groupID == id }.count)
                (view as? TabGroupCell)?.dropTarget = groupDropValid && dropGroup == id
                (view as? TabGroupCell)?.toggle = { [weak store] in store?.toggleTabGroup(id) }
                view?.alphaValue = id == table.dragID ? 0 : 1
            }
        }
        private func displayedTab(_ id: UUID) -> Tab? {
            tabByID[id] ?? rowWipes[id]?.tab
        }
        private func groupExpansion(_ id: UUID) -> CGFloat {
            guard let groupID = displayedTab(id)?.groupID,
                  let container = table?.enclosingScrollView?.superview as? TabListContainer,
                  let rail = container.railViews[groupID] else { return 0 }
            return expansion * rail.progress
        }
        @objc private func close(_ sender: NSButton) {
            if let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) { store.close(id) }
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard rows.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(rows[row].id.uuidString, forType: .string)
            return item
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            guard let table = tableView as? TabTable, let row = rowIndexes.first,
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return }
            table.beginDrag(at: row)
            let image: NSImage
            if let cell = cell as? TabCell { image = cell.dragImage() }
            else { image = cell.dragPreview(radius: 9) ?? NSImage(size: cell.bounds.size) }
            session.enumerateDraggingItems(options: [], for: table, classes: [NSPasteboardItem.self], searchOptions: [:]) {
                item, _, _ in
                let frame = table.rect(ofRow: row).insetBy(dx: 1, dy: 0)
                item.setDraggingFrame(frame, contents: image)
            }
            session.animatesToStartingPositionsOnCancelOrFail = true
            if case .group(let id) = rows[row] {
                draggingGroup = id
                updating = true; render(table); updating = false
            } else { table.refreshDragPlaceholder() }
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard let table = tableView as? TabTable else { return }
            table.endDragPreview()
            update(table, compact: compact, theme: table.theme)
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let table = tableView as? TabTable, info.draggingSource as? NSTableView === table,
                  table.dragID != nil else { return [] }
            let point = table.convert(info.draggingLocation, from: nil)
            return updateDragPosition(point, in: table)
        }
        func updateDragPosition(_ point: NSPoint, in table: TabTable) -> NSDragOperation {
            if !store.openTabGroups.isEmpty { return updateGroupedDrag(point, in: table) }
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
        func resetGroupPreview(_ table: TabTable) {
            guard previewTabs != nil || draggingGroup != nil else { return }
            previewTabs = nil; draggingGroup = nil; groupDropValid = false
            tabs = store.tabs
            updating = true; render(table); updating = false
        }

        // Header/row bodies join a group; the leading gutter and outer edges leave it.
        // Resolve against the displayed rows, but calculate every preview from committed tabs.
        func updateGroupedDrag(_ point: NSPoint, in table: TabTable) -> NSDragOperation {
            guard let id = table.dragID, !rows.isEmpty else { return [] }
            let movingGroup = store.tabGroups.contains { $0.id == id }
            if movingGroup { draggingGroup = id }
            let row = min(max(0, Int(floor(point.y / table.rowHeight))), rows.count - 1)
            let target = rows[row]
            let localY = point.y - CGFloat(row) * table.rowHeight
            if target.id == id && (movingGroup || (point.x >= 8 && localY < table.rowHeight - 7)) { return .move }
            var insertion = store.tabs.count
            var groupID: UUID?
            if point.y < 0 { insertion = store.tabs.filter(\.pinned).count }
            else if point.y >= CGFloat(rows.count) * table.rowHeight { insertion = store.tabs.count }
            else {
                switch target {
                case .group(let targetID):
                    let members = store.tabs.indices.filter { store.tabs[$0].groupID == targetID }
                    guard let first = members.first, let last = members.last else { return [] }
                    if movingGroup { insertion = localY < table.rowHeight / 2 ? first : last + 1 }
                    else if localY < 7 || point.x < 8 { insertion = first }
                    else { insertion = first; groupID = targetID }
                case .tab(let targetID):
                    guard let index = store.tabs.firstIndex(where: { $0.id == targetID }) else { return [] }
                    let tab = displayedTab(targetID) ?? store.tabs[index]
                    groupID = movingGroup ? nil : tab.groupID
                    insertion = index + (localY >= table.rowHeight / 2 ? 1 : 0)
                    if let actualGroup = store.tabs[index].groupID,
                       store.tabGroups.contains(where: { $0.id == actualGroup && $0.collapsed }),
                       let last = store.tabs.lastIndex(where: { $0.groupID == actualGroup }) {
                        insertion = last + 1
                    }
                    if let currentGroup = tab.groupID {
                        let members = store.tabs.indices.filter { store.tabs[$0].groupID == currentGroup }
                        guard let first = members.first, let last = members.last else { return [] }
                        let isEnd = row + 1 == rows.count || {
                            if case .tab(let next) = rows[row + 1] { return tabs.first { $0.id == next }?.groupID != currentGroup }
                            return true
                        }()
                        if movingGroup || point.x < 8 || (isEnd && localY >= table.rowHeight - 7) {
                            groupID = nil
                            insertion = movingGroup || (isEnd && localY >= table.rowHeight - 7) ? last + 1 :
                                (localY < table.rowHeight / 2 ? first : last + 1)
                        }
                    }
                }
            }
            let result = movingGroup ? store.previewMovingGroup(id, to: insertion) :
                store.previewMovingTab(id, to: insertion, groupID: groupID)
            guard let result else { groupDropValid = false; return [] }
            table.dragInsertion = insertion; dropGroup = groupID; groupDropValid = true
            previewTabs = result; tabs = result
            updating = true; render(table); updating = false
            table.setDropRow(-1, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let table = tableView as? TabTable, let insertion = table.dragInsertion,
                  let raw = info.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: raw),
                  info.draggingSource as? NSTableView === table, id == table.dragID else { return false }
            if !store.openTabGroups.isEmpty {
                guard groupDropValid else { return false }
                let isGroup = store.tabGroups.contains { $0.id == id }
                let destinationGroup = dropGroup
                previewTabs = nil; draggingGroup = nil; groupDropValid = false
                table.clearDrag()
                if isGroup { store.moveTabGroup(id, to: insertion) }
                else { store.moveTab(id, to: insertion, groupID: destinationGroup) }
                update(table, compact: compact, theme: table.theme)
                return true
            }
            guard store.canMove(id, to: insertion) else { return false }
            table.clearDrag()
            store.move(id, to: insertion)
            return true
        }
        func editGroup(_ id: UUID) {
            guard let table, let row = rows.firstIndex(of: .group(id)) else { return }
            editor?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: TabGroupEditor(store: store, id: id,
                dismiss: { [weak popover] in popover?.close() }))
            editor = popover
            popover.show(relativeTo: table.rect(ofRow: row), of: table, preferredEdge: .maxX)
        }
        func menu(_ row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
            if case .group(let id) = rows[row] { editGroup(id); return nil }
            guard let tab = tabs.first(where: { $0.id == rows[row].id }) else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ title: String, _ action: String, enabled: Bool = true) {
                let item = menu.addItem(withTitle: title, action: #selector(performMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [tab.id.uuidString, action]
                item.isEnabled = enabled
            }
            add("在下方新增标签页", "new")
            if !tab.pinned {
                let groups = NSMenu()
                func groupItem(_ title: String, action: String) {
                    let item = groups.addItem(withTitle: title, action: #selector(performMenu(_:)), keyEquivalent: "")
                    item.target = self; item.representedObject = [tab.id.uuidString, action]
                }
                groupItem("新建组", action: "group")
                let openGroups = store.openTabGroups
                if !openGroups.isEmpty { groups.addItem(.separator()) }
                for group in openGroups {
                    groupItem(group.name.isEmpty ? "未命名分组" : group.name, action: "group:" + group.id.uuidString)
                    groups.items.last?.state = tab.groupID == group.id ? .on : .off
                }
                let item = menu.addItem(withTitle: "向群组中添加标签页", action: nil, keyEquivalent: "")
                item.submenu = groups
                if tab.groupID != nil { add("移出分组", "ungroup") }
            }
            menu.addItem(.separator())
            add("重新加载", "reload", enabled: !tab.address.isEmpty)
            add("重命名…", "rename")
            add("复制", "duplicate")
            add(tab.pinned ? "取消固定" : "固定", "pin")
            menu.addItem(.separator())
            add("将此标签页加入书签", "bookmark", enabled: !tab.address.isEmpty)
            add("复制网址", "copy", enabled: !tab.address.isEmpty)
            menu.addItem(.separator())
            add("关闭", "close")
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
            case "rename": rename(tab)
            case "duplicate": store.newTab(address: tab.address, title: tab.title, after: id, customTitle: tab.customTitle)
            case "pin": store.pin(id)
            case "bookmark": _ = store.add(title: tab.displayTitle, address: tab.address)
            case "copy": copyAddress(tab.address)
            case "close": store.close(id)
            case "others": store.closeOthers(id)
            case "below": store.closeOthers(id, below: true)
            case "reopen": store.reopen()
            case "group":
                if let groupID = store.createTabGroup(id), let table {
                    update(table, compact: compact, theme: table.theme)
                    editGroup(groupID)
                }
            case "ungroup":
                if let groupID = tab.groupID, let last = store.tabs.lastIndex(where: { $0.groupID == groupID }) {
                    store.moveTab(id, to: last + 1, groupID: nil)
                }
            default:
                if args[1].hasPrefix("group:"), let groupID = UUID(uuidString: String(args[1].dropFirst(6))),
                   let last = store.tabs.lastIndex(where: { $0.groupID == groupID }) {
                    store.moveTab(id, to: last + 1, groupID: groupID)
                }
            }
        }

        private func rename(_ tab: Tab) {
            guard let window = table?.window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = "重命名标签页"
            alert.informativeText = "留空可恢复自动标题。"
            alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
            let field = NSTextField(string: tab.displayTitle)
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            field.setAccessibilityLabel("标签页名称")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { [weak store] response in
                if response == .alertFirstButtonReturn { store?.renameTab(tab.id, to: field.stringValue) }
            }
            field.selectText(nil)
        }
    }
}
