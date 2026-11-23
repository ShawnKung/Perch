import AppKit
import SwiftUI

// The drag session owns its preview order; only an accepted local drop reaches Store.
struct HomeShortcutGrid<Card: View>: View {
    let store: Store
    let sites: [Site]
    let tabID: UUID
    let card: (Site) -> Card
    @State private var width: CGFloat = 704
    var body: some View {
        GeometryReader { geometry in
            HomeShortcutGridBridge(store: store, sites: sites, tabID: tabID, card: card)
                .onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { width = $0 }
        }.frame(height: HomeShortcutLayout.height(count: sites.count, width: width))
    }
}

enum HomeShortcutLayout {
    static let tileHeight: CGFloat = 68
    static let gap: CGFloat = 12
    static func columns(width: CGFloat) -> Int { max(1, Int((width + gap) / (190 + gap))) }
    static func height(count: Int, width: CGFloat) -> CGFloat {
        let rows = (count + columns(width: width) - 1) / columns(width: width)
        return CGFloat(rows) * (tileHeight + gap) - (rows == 0 ? 0 : gap)
    }
    static func frames(count: Int, width: CGFloat) -> [NSRect] {
        let columns = columns(width: width)
        let tileWidth = max(0, (width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        return (0..<count).map {
            NSRect(x: CGFloat($0 % columns) * (tileWidth + gap),
                   y: CGFloat($0 / columns) * (tileHeight + gap), width: tileWidth, height: tileHeight)
        }
    }
}

private struct HomeShortcutGridBridge<Card: View>: NSViewRepresentable {
    let store: Store
    let sites: [Site]
    let tabID: UUID
    let card: (Site) -> Card
    func makeNSView(context: Context) -> HomeShortcutGridView { HomeShortcutGridView() }
    func updateNSView(_ view: HomeShortcutGridView, context: Context) {
        view.store = store; view.tabID = tabID
        view.commit = { [weak store] in store?.reorderHomeShortcuts($0) ?? false }
        view.update(sites: sites, card: {
            AnyView(card($0).foregroundStyle(Style.ink).tint(Style.accent).preferredColorScheme(.light))
        }, open: { [weak store] in store?.open($0) })
    }
    static func dismantleNSView(_ view: HomeShortcutGridView, coordinator: ()) { view.cancelPreview() }
}

final class HomeShortcutGridView: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.perch.home-shortcut")
    override var isFlipped: Bool { true }
    private(set) var ids: [UUID] = []
    private(set) var dragID: UUID?
    private var original: [UUID] = []
    private var cells: [UUID: HomeShortcutCell] = [:]
    weak var store: Store?
    var tabID: UUID?
    var commit: (([UUID]) -> Bool)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.pasteboardType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(sites: [Site], card: (Site) -> AnyView, open: @escaping (Site) -> Void) {
        let incoming = sites.map(\.id)
        if dragID == nil { ids = incoming }
        else if incoming != original { cancelPreview(); ids = incoming }
        let valid = Set(incoming)
        for id in Array(cells.keys) where !valid.contains(id) { cells.removeValue(forKey: id)?.removeFromSuperview() }
        for site in sites {
            let cell = cells[site.id] ?? HomeShortcutCell(rootView: card(site))
            cell.rootView = card(site)
            cell.grid = self; cell.id = site.id; cell.open = { open(site) }
            if cells[site.id] == nil {
                cell.dragRequested = { [weak self, weak cell] event in
                    guard let cell else { return }
                    self?.beginDrag(cell, event: event)
                }
                cells[site.id] = cell; addSubview(cell)
            }
        }
        arrange(animated: false)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange(animated: false)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelPreview() }
    }
    private func arrange(animated: Bool) {
        let frames = HomeShortcutLayout.frames(count: ids.count, width: bounds.width)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : 0
            for (index, id) in ids.enumerated() {
                guard let cell = cells[id] else { continue }
                cell.alphaValue = id == dragID ? 0 : 1
                if context.duration > 0 { cell.animator().frame = frames[index] }
                else { cell.frame = frames[index] }
            }
        }
    }
    func beginDrag(_ cell: HomeShortcutCell, event: NSEvent) {
        guard let id = cell.id, let image = cell.dragImage(), beginPreview(id) else { return }
        let writer = NSPasteboardItem()
        writer.setString(id.uuidString, forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(cell.bounds, contents: image)
        let session = cell.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        arrange(animated: false)
    }
    @discardableResult func beginPreview(_ id: UUID) -> Bool {
        guard dragID == nil, ids.contains(id) else { return false }
        original = ids; dragID = id
        arrange(animated: false)
        return true
    }
    func cancelPreview() {
        if dragID != nil { ids = original }
        dragID = nil; original = []
        arrange(animated: false)
    }
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSource as? HomeShortcutGridView === self, let dragID else { return false }
        return sender.draggingPasteboard.string(forType: Self.pasteboardType) == dragID.uuidString
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender), let dragID else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        guard bounds.contains(point) else { return [] }
        let slots = HomeShortcutLayout.frames(count: ids.count, width: bounds.width)
        guard let target = slots.indices.min(by: {
            hypot(slots[$0].midX - point.x, slots[$0].midY - point.y) <
                hypot(slots[$1].midX - point.x, slots[$1].midY - point.y)
        }), let source = ids.firstIndex(of: dragID), source != target else { return .move }
        ids.remove(at: source); ids.insert(dragID, at: target)
        arrange(animated: true)
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard dragID != nil else { return }
        ids = original; arrange(animated: true)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        accepts(sender) && bounds.contains(convert(sender.draggingLocation, from: nil))
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard prepareForDragOperation(sender) else { return false }
        _ = draggingUpdated(sender)
        let result = ids
        guard commit?(result) == true else { cancelPreview(); return false }
        dragID = nil; original = []
        arrange(animated: false)
        return true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        cancelPreview()
    }
}

final class HomeShortcutCell: NSView {
    private let content: NSHostingView<AnyView>
    var rootView: AnyView {
        get { content.rootView }
        set { content.rootView = newValue }
    }
    override var isFlipped: Bool { true }
    init(rootView: AnyView) {
        content = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        content.sizingOptions = []
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    weak var grid: HomeShortcutGridView?
    var id: UUID?
    var open: (() -> Void)?
    var dragRequested: ((NSEvent) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        let origin = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { open?() }
                return
            }
            if hypot(next.locationInWindow.x - origin.x, next.locationInWindow.y - origin.y) >= 5 {
                dragRequested?(event)
                return
            }
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard grid?.store?.sites.contains(where: { $0.id == id }) == true else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: String) {
            let item = menu.addItem(withTitle: title, action: #selector(performMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action
        }
        add("在新标签页打开", "newTab")
        add("临时浏览", "preview")
        menu.addItem(.separator())
        add("编辑书签…", "edit")
        add("复制网址", "copy")
        menu.addItem(.separator())
        add("从首页移除", "hide")
        add("删除书签", "delete")
        return menu
    }
    @objc private func performMenu(_ item: NSMenuItem) {
        guard let store = grid?.store, let tabID = grid?.tabID,
              let site = store.sites.first(where: { $0.id == id }) else { return }
        switch item.representedObject as? String {
        case "newTab": store.newTab(address: site.address, after: tabID)
        case "preview":
            guard let window else { return }
            store.bookmarkEditor.preview(site, store: store, parent: window, tabID: tabID)
        case "edit":
            store.bookmarkEditRequest = BookmarkEditRequest(site: site, ownerID: site.id, showAddress: true)
        case "copy":
            let board = store.browser?.clipboard ?? NSPasteboard.general
            board.clearContents(); board.setString(site.address, forType: .string)
        case "hide": store.toggleBookmarkHome(site.id)
        case "delete": store.remove(site)
        default: break
        }
    }
    func dragImage() -> NSImage? {
        dragPreview(radius: 12)
    }
}
