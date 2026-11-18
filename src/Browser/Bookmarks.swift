import AppKit
import SwiftUI

struct BookmarkFolder: Identifiable, Codable {
    var id = UUID()
    var title: String
    var parentID: UUID?
}

enum BookmarkClipboard {
    static let type = NSPasteboard.PasteboardType("dev.perch.bookmarks")
    static let cutType = NSPasteboard.PasteboardType("dev.perch.bookmark-cut")
    struct Payload: Codable {
        var sites: [Site]
        var folders: [BookmarkFolder]
    }
    struct Cut: Codable {
        let session: UUID
        let ids: Set<UUID>
    }
    static func copy(_ sites: [Site], to board: NSPasteboard) {
        write(Payload(sites: sites, folders: []), to: board)
    }
    static func write(_ payload: Payload, to board: NSPasteboard) {
        guard !payload.sites.isEmpty || !payload.folders.isEmpty,
              let data = try? JSONEncoder().encode(payload) else { return }
        board.clearContents()
        board.setData(data, forType: type)
        board.setString(payload.sites.map(\.address).joined(separator: "\n"), forType: .string)
    }
    static func payload(_ board: NSPasteboard) -> Payload? {
        if let data = board.data(forType: type) {
            guard data.count <= 1_048_576 else { return nil }
            if let payload = try? JSONDecoder().decode(Payload.self, from: data) { return payload }
            return (try? JSONDecoder().decode([Site].self, from: data)).map { Payload(sites: $0, folders: []) }
        }
        guard let text = board.string(forType: .string), text.utf8.count <= 1_048_576 else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return Payload(sites: lines.map { Site(title: "", address: $0) }, folders: [])
    }
    static func read(_ board: NSPasteboard) -> [Site]? { payload(board)?.sites }
}

enum BookmarkDrag {
    static let type = NSPasteboard.PasteboardType("dev.perch.bookmark-item-id")
    static func ids(_ board: NSPasteboard) -> Set<UUID> {
        Set((board.pasteboardItems ?? []).compactMap { $0.string(forType: type).flatMap(UUID.init(uuidString:)) })
    }
}

final class BookmarkListItem {
    let key: String
    let title: String
    let site: Site?
    let folderID: UUID?
    let editable: Bool
    let children: [BookmarkListItem]?
    init(key: String, title: String = "", site: Site? = nil, folderID: UUID? = nil,
         editable: Bool = false, children: [BookmarkListItem]? = nil) {
        self.key = key; self.title = site.map { $0.title.isEmpty ? $0.address : $0.title } ?? title
        self.site = site; self.folderID = folderID; self.editable = editable; self.children = children
    }
    var id: UUID? { site?.id ?? folderID }
    var selectable: Bool { site.map { URLInput.parse($0.address, search: false) != nil } ?? (folderID != nil) }
    var signature: String {
        // Length-prefix each value so titles and URLs cannot collide with structural separators.
        let values = [key, title, site?.address ?? "", site?.id.uuidString ?? "",
                      folderID?.uuidString ?? "", String(site?.showOnHome != false),
                      String(editable), children == nil ? "leaf" : "folder"]
        return values.map { "\($0.utf8.count):\($0)" }.joined() + (children ?? []).map(\.signature).joined()
    }
    static func imported(_ nodes: [BookmarkNode], path: String) -> [BookmarkListItem] {
        nodes.enumerated().map { index, node in
            let key = "\(path)/\(index)/\(node.id)"
            if let children = node.children {
                return BookmarkListItem(key: key, title: node.title, folderID: node.id,
                                        children: imported(children, path: key))
            }
            return BookmarkListItem(key: key, title: node.title.isEmpty ? "分隔项" : node.title,
                site: node.address.map { Site(id: node.id, title: node.title, address: $0) })
        }
    }
}

final class BookmarkOutline: NSOutlineView {
    var clipboard = NSPasteboard.general
    var copyItems: ((NSPasteboard) -> Void)?
    var cutItems: ((NSPasteboard) -> Void)?
    var pasteItems: ((NSPasteboard) -> Void)?
    var requestDelete: (() -> Void)?
    var previewItem: (() -> Void)?
    var rowMenu: ((Int) -> NSMenu?)?
    var reloadCount = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
    override func reloadData() { reloadCount += 1; super.reloadData() }
    override func selectAll(_ sender: Any?) {
        expandItem(nil, expandChildren: true)
        selectRowIndexes(IndexSet((0..<numberOfRows).filter {
            (item(atRow: $0) as? BookmarkListItem)?.selectable == true
        }), byExtendingSelection: false)
    }
    @objc func copy(_ sender: Any?) {
        copyItems?(clipboard)
    }
    @objc func cut(_ sender: Any?) { cutItems?(clipboard) }
    @objc func paste(_ sender: Any?) { pasteItems?(clipboard) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 51 {
            if !event.isARepeat { requestDelete?() }
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": paste(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if window?.firstResponder === self, event.keyCode == 49,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if !event.isARepeat { previewItem?() }
            return
        }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return rowMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

final class BookmarkCell: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let address = NSTextField(labelWithString: "")
    let editButton = NSButton()
    let homeButton = NSButton()
    let openButton = NSButton()
    var edit: (() -> Void)?
    var toggleHome: (() -> Void)?
    var open: (() -> Void)?
    private var nameTop: NSLayoutConstraint!
    private var editWidth: NSLayoutConstraint!
    private var homeWidth: NSLayoutConstraint!
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("bookmarkCell")
        name.font = .systemFont(ofSize: 12, weight: .medium)
        address.font = .systemFont(ofSize: 10); address.textColor = .secondaryLabelColor
        for label in [name, address] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        editButton.target = self; editButton.action = #selector(editItem)
        homeButton.target = self; homeButton.action = #selector(toggleHomeItem)
        openButton.target = self; openButton.action = #selector(openItem)
        for button in [editButton, homeButton, openButton] { button.isBordered = false }
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "编辑书签")
        homeButton.image = NSImage(systemSymbolName: "house", accessibilityDescription: "在首页显示")
        openButton.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "打开书签")
        for view in [icon, name, address, editButton, homeButton, openButton] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        }
        nameTop = name.topAnchor.constraint(equalTo: topAnchor, constant: 3)
        editWidth = editButton.widthAnchor.constraint(equalToConstant: 22)
        homeWidth = homeButton.widthAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), nameTop,
            address.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            address.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            name.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -4),
            address.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            editWidth,
            editButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: homeButton.leadingAnchor, constant: -2),
            homeWidth,
            homeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            homeButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -2),
            openButton.widthAnchor.constraint(equalToConstant: 22),
            openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func editItem() { edit?() }
    @objc private func toggleHomeItem() { toggleHome?() }
    @objc private func openItem() { open?() }
    func configure(_ item: BookmarkListItem, favicon: NSImage? = nil, expanded: Bool = false) {
        name.stringValue = item.title
        address.stringValue = item.site?.address ?? ""
        address.isHidden = item.site == nil; nameTop.constant = item.site == nil ? 10 : 3
        icon.image = favicon ?? NSImage(systemSymbolName: item.site == nil && expanded ? "folder.fill" :
                            (item.site == nil ? "folder" : "globe"),
                            accessibilityDescription: item.site == nil ? (expanded ? "已展开目录" : "已收起目录") : "书签")
        editButton.isHidden = !item.editable
        editWidth.constant = item.editable ? 22 : 0
        editButton.setAccessibilityLabel("编辑 \(item.title)")
        homeButton.isHidden = !item.editable
        homeWidth.constant = item.editable ? 22 : 0
        let onHome = item.site?.showOnHome != false
        homeButton.image = NSImage(systemSymbolName: onHome ? "house.fill" : "house",
                                   accessibilityDescription: onHome ? "从首页移除" : "在首页显示")
        homeButton.contentTintColor = onHome ? NSColor(Style.accent) : .secondaryLabelColor
        homeButton.toolTip = onHome ? "从首页快捷入口移除" : "添加到首页快捷入口"
        homeButton.setAccessibilityLabel("\(onHome ? "从首页移除" : "在首页显示") \(item.title)")
        openButton.isHidden = !item.selectable && item.folderID == nil
        openButton.setAccessibilityLabel("打开 \(item.title)")
        toolTip = item.title + "\n" + (item.site?.address ?? "目录")
    }
}

struct NativeBookmarks: NSViewRepresentable {
    @ObservedObject private var theme = PerchTheme.shared
    let rows: [BookmarkListItem]
    @Binding var selection: Set<UUID>
    var expandAll: Bool
    var edit: (Site) -> Void
    var toggleHome: (Site) -> Void
    var open: (Site) -> Void
    var navigate: (UUID) -> Void
    var delete: (Site) -> Void
    var paste: (NSPasteboard) -> Void
    var copy: (Set<UUID>, NSPasteboard) -> Void
    var cut: (Set<UUID>, NSPasteboard) -> Void
    var movable: Set<UUID>
    var move: (Set<UUID>, UUID?) -> Bool
    var folderAction: (UUID, String) -> Void
    var pasteInto: (NSPasteboard, UUID) -> Void
    var requestDelete: () -> Void
    var preview: (Site) -> Browser?
    var favicon: (String) -> NSImage?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = context.coordinator.table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmarks"))
        table.addTableColumn(column); table.outlineTableColumn = column
        table.headerView = nil; table.rowHeight = 38; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.indentationPerLevel = 10
        table.style = .plain; table.autoresizesOutlineColumn = false
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        let scroll = TabScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = table
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.doubleClick)
        table.rowMenu = { [weak coordinator = context.coordinator] row in coordinator?.menu(row) }
        table.copyItems = { [weak coordinator = context.coordinator] board in
            guard let coordinator else { return }
            coordinator.parent.copy(coordinator.parent.selection, board)
        }
        table.cutItems = { [weak coordinator = context.coordinator] board in
            guard let coordinator else { return }
            coordinator.parent.cut(coordinator.parent.selection, board)
        }
        table.registerForDraggedTypes([BookmarkDrag.type])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.theme = theme.selection
        coordinator.table.pasteItems = paste
        coordinator.table.requestDelete = requestDelete
        coordinator.table.previewItem = { [weak coordinator] in
            guard let coordinator, coordinator.parent.selection.count == 1,
                  let item = coordinator.flattened(coordinator.roots).first(where: {
                      $0.id.map(coordinator.parent.selection.contains) == true
                  }), item.selectable, let site = item.site else { return }
            guard coordinator.previewController == nil, let parentWindow = coordinator.table.window,
                  let browser = coordinator.parent.preview(site) else { return }
            let controller = BookmarkPreviewController(browser: browser, title: site.title, parent: parentWindow,
                                                       defaults: browser.previewDefaults)
            controller.onOpenTab = { [weak coordinator] site in coordinator?.parent.open(site) }
            controller.onClose = { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.previewController = nil
                coordinator.table.window?.makeFirstResponder(coordinator.table)
            }
            coordinator.previewController = controller
            controller.show(in: parentWindow)
        }
        coordinator.update()
        for row in 0..<coordinator.table.numberOfRows {
            guard let item = coordinator.table.item(atRow: row) as? BookmarkListItem,
                  let cell = coordinator.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BookmarkCell else { continue }
            cell.configure(item, favicon: item.site.flatMap { favicon($0.address) },
                           expanded: coordinator.table.isItemExpanded(item))
        }
        coordinator.table.enumerateAvailableRowViews { row, _ in
            if let row = row as? TabSelectionRow { row.theme = theme.selection }
            row.needsDisplay = true
        }
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.previewController?.close()
    }
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: NativeBookmarks
        var theme: ThemeColor = .green
        let table = BookmarkOutline()
        var roots: [BookmarkListItem] = []
        var signature = ""
        var updating = false
        var previewController: BookmarkPreviewController?
        init(_ parent: NativeBookmarks) { self.parent = parent }
        func flattened(_ items: [BookmarkListItem]) -> [BookmarkListItem] {
            items.flatMap { [$0] + flattened($0.children ?? []) }
        }
        func update() {
            updating = true
            defer { updating = false }
            let next = parent.rows.map(\.signature).joined()
            if signature != next {
                let expanded = Set(flattened(roots).filter { table.isItemExpanded($0) }.map(\.key))
                let origin = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
                signature = next; roots = parent.rows
                table.reloadData()
                for item in flattened(roots) where expanded.contains(item.key) || parent.expandAll {
                    table.expandItem(item)
                }
                table.enclosingScrollView?.contentView.scroll(to: origin)
                if let scroll = table.enclosingScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
            }
            let indexes = IndexSet((0..<table.numberOfRows).filter {
                guard let item = table.item(atRow: $0) as? BookmarkListItem, let id = item.id else { return false }
                return item.selectable && parent.selection.contains(id)
            })
            if indexes != table.selectedRowIndexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating else { return }
            let selected = Set(table.selectedRowIndexes.compactMap { (table.item(atRow: $0) as? BookmarkListItem)?.id })
            parent.selection = selected
        }
        private func updateFolderIcon(_ notification: Notification) {
            guard !updating, let item = notification.userInfo?["NSObject"] as? BookmarkListItem else { return }
            let row = table.row(forItem: item)
            guard row >= 0, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BookmarkCell else { return }
            cell.configure(item, favicon: item.site.flatMap { parent.favicon($0.address) },
                           expanded: table.isItemExpanded(item))
        }
        func outlineViewItemDidExpand(_ notification: Notification) { updateFolderIcon(notification) }
        func outlineViewItemDidCollapse(_ notification: Notification) { updateFolderIcon(notification) }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? BookmarkListItem)?.children?.count ?? (item == nil ? roots.count : 0)
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? BookmarkListItem)?.children ?? roots)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? BookmarkListItem)?.children != nil
        }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? BookmarkListItem)?.selectable == true
        }
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let view = TabSelectionRow()
            view.theme = theme
            view.horizontalInset = 1
            view.extraLeadingInset = 11
            view.verticalInset = 2
            return view
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? BookmarkListItem else { return nil }
            let cell = table.makeView(withIdentifier: NSUserInterfaceItemIdentifier("bookmarkCell"), owner: self) as? BookmarkCell
                ?? BookmarkCell()
            cell.configure(item, favicon: item.site.flatMap { parent.favicon($0.address) },
                           expanded: table.isItemExpanded(item))
            cell.edit = { [weak self] in if let site = item.site { self?.parent.edit(site) } }
            cell.toggleHome = { [weak self] in if let site = item.site { self?.parent.toggleHome(site) } }
            cell.open = { [weak self] in self?.activate(item) }
            return cell
        }
        func activate(_ item: BookmarkListItem) {
            if let folder = item.folderID, item.children == nil { parent.navigate(folder) }
            else if item.children != nil {
                if table.isItemExpanded(item) { table.collapseItem(item) } else { table.expandItem(item) }
            }
            else if let site = item.site, item.selectable { parent.open(site) }
        }
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let id = (item as? BookmarkListItem)?.id, parent.movable.contains(id) else { return nil }
            let writer = NSPasteboardItem(); writer.setString(id.uuidString, forType: BookmarkDrag.type)
            return writer
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard !BookmarkDrag.ids(info.draggingPasteboard).isEmpty else { return [] }
            if let item = item as? BookmarkListItem {
                guard let folder = item.folderID, parent.movable.contains(folder) else { return [] }
                outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else { outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex) }
            return .move
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex: Int) -> Bool {
            parent.move(BookmarkDrag.ids(info.draggingPasteboard), (item as? BookmarkListItem)?.folderID)
        }
        @objc func doubleClick() {
            guard let item = table.item(atRow: table.clickedRow) as? BookmarkListItem else { return }
            activate(item)
        }
        func menu(_ row: Int) -> NSMenu? {
            guard let item = table.item(atRow: row) as? BookmarkListItem, let id = item.id else { return nil }
            if !parent.selection.contains(id) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            let menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ title: String, _ action: String, enabled: Bool = true) {
                let entry = menu.addItem(withTitle: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                entry.target = self; entry.representedObject = [item.key, action]; entry.isEnabled = enabled
            }
            add(item.site == nil ? "打开目录" : "在新标签页中打开", "open", enabled: item.selectable)
            add("复制", "copy")
            add("剪切", "cut", enabled: parent.selection.isSubset(of: parent.movable))
            if item.site != nil { add("复制网址", "address") }
            if item.editable {
                add("编辑书签…", "edit")
                menu.addItem(.separator())
                add("删除书签…", "delete")
            } else if let folder = item.folderID, parent.movable.contains(folder) {
                add("粘贴", "paste")
                menu.addItem(.separator())
                add("新建子目录…", "newFolder")
                add("重命名…", "rename")
                add("删除目录…", "deleteFolder")
            }
            return menu
        }
        @objc private func menuAction(_ sender: NSMenuItem) {
            guard let args = sender.representedObject as? [String], args.count == 2,
                  let item = flattened(roots).first(where: { $0.key == args[0] }) else { return }
            switch args[1] {
            case "open": activate(item)
            case "copy": parent.copy(parent.selection, table.clipboard)
            case "cut": parent.cut(parent.selection, table.clipboard)
            case "address": if let site = item.site { copyAddress(site.address) }
            case "edit": if let site = item.site { parent.edit(site) }
            case "delete": if let site = item.site { parent.delete(site) }
            case "paste": if let folder = item.folderID { parent.pasteInto(table.clipboard, folder) }
            case "newFolder", "rename", "deleteFolder":
                if let folder = item.folderID { parent.folderAction(folder, args[1]) }
            default: break
            }
        }
    }
}

private enum BookmarkScope: Equatable {
    case all, root, folder(UUID), imported(String), history
}

struct BookmarkNode: Identifiable, Codable {
    var id = UUID()
    var title: String
    var address: String?
    var children: [BookmarkNode]?

    var sites: [Site] {
        if let address, URLInput.parse(address, search: false) != nil {
            return [Site(id: id, title: title, address: address)]
        }
        return (children ?? []).flatMap(\.sites)
    }
}

struct BookmarksPage: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var editing: Site?
    @State private var adding = false
    @State private var title = ""
    @State private var address = ""
    @State private var deleting = false
    @State private var scope = BookmarkScope.root
    @State private var folderPrompt = false
    @State private var folderDraft = BookmarkFolder(title: "")
    @State private var renamingFolder = false
    @State private var folderToDelete: BookmarkFolder?
    @State private var clearHistory = false

    init(store: Store) {
        self.store = store
        _scope = State(initialValue: store.libraryShowsHistory ? .history : .root)
    }

    private var currentFolder: UUID? {
        if case .folder(let id) = scope { return id }
        return nil
    }
    private var scopeTitle: String {
        switch scope {
        case .all: return "全部书签"
        case .root: return "个人书签"
        case .folder(let id): return store.bookmarkFolderPath(id)
        case .imported(let source): return "\(source)/ · 只读"
        case .history: return "历史记录"
        }
    }
    private var personal: [Site] {
        store.sites.filter { site in
            let inScope: Bool
            switch scope {
            case .all: inScope = true
            case .root: inScope = site.folderID == nil
            case .folder(let id): inScope = site.folderID == id
            case .imported, .history: inScope = false
            }
            return inScope && matches(site.title, site.address)
        }
    }
    private var sources: [String] {
        switch scope {
        case .all: return store.importedBookmarks.keys.sorted()
        case .imported(let source): return [source]
        default: return []
        }
    }
    private var filteredImports: [String: [BookmarkNode]] {
        store.importedBookmarks.mapValues(filteredNodes)
    }
    private var visible: [Site] {
        personal + sources.flatMap { (filteredImports[$0] ?? []).flatMap(\.sites) }
    }
    private var selected: [Site] { store.bookmarkSelectionPayload(selection).sites }
    private var deletable: Set<UUID> { store.personalBookmarkItemIDs.intersection(selection) }
    private func rowIDs(_ rows: [BookmarkListItem]) -> Set<UUID> {
        Set(rows.compactMap(\.id)).union(rows.reduce(into: Set<UUID>()) { $0.formUnion(rowIDs($1.children ?? [])) })
    }
    private var rows: [BookmarkListItem] {
        var result: [BookmarkListItem] = []
        if search.isEmpty, scope != .all, sources.isEmpty {
            result += store.bookmarkFolders.filter { $0.parentID == currentFolder }.map {
                BookmarkListItem(key: $0.id.uuidString, title: $0.title, folderID: $0.id)
            }
        }
        result += personal.map { BookmarkListItem(key: $0.id.uuidString, site: $0, editable: true) }
        for source in sources {
            let importedRows = BookmarkListItem.imported(filteredImports[source] ?? [], path: source)
            if case .imported = scope {
                result += importedRows
            } else {
                result.append(BookmarkListItem(key: source, title: "\(source)/ · 只读", children: importedRows))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("搜索名称或网址", text: $search).textFieldStyle(.roundedBorder)
                if scope != .history {
                    Button("添加书签") {
                        editing = nil; adding = true; title = ""; address = ""
                    }.disabled({ if case .imported = scope { return true }; return false }())
                    Button("新建目录") {
                        folderDraft = BookmarkFolder(title: "", parentID: currentFolder)
                        renamingFolder = false; folderPrompt = true
                    }
                }
            }
            if scope != .history && (adding || editing != nil) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(editing == nil ? "添加书签" : "编辑书签").font(.caption).foregroundStyle(Style.muted)
                    HStack {
                        TextField("名称", text: $title)
                        TextField("https://example.com", text: $address)
                        Button("保存") {
                            let ok = editing.map { store.edit($0, title: title, address: address) }
                                ?? store.add(title: title, address: address, folderID: currentFolder)
                            if ok { editing = nil; adding = false }
                        }
                        Button("取消") { editing = nil; adding = false }
                    }.textFieldStyle(.roundedBorder)
                }
            }
            if scope == .history {
                HStack {
                    Button("清空全部历史记录…", role: .destructive) { clearHistory = true }
                        .disabled(store.history.isEmpty)
                    Spacer()
                }
            } else {
                HStack(spacing: 10) {
                    Button(search.isEmpty ? "全选" : "全选搜索结果") { selection = rowIDs(rows) }
                        .disabled(rows.isEmpty)
                    Button("取消选择") { selection.removeAll() }.disabled(selection.isEmpty)
                    Spacer()
                    Text("已选 \(selection.count) 项").font(.caption).foregroundStyle(Style.muted)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                folderSidebar.frame(width: 170)
                if scope == .history {
                    historyRecords
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scopeTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1).padding(.leading, 6)
                        NativeBookmarks(rows: rows, selection: $selection, expandAll: !search.isEmpty,
                            edit: edit, toggleHome: { store.toggleBookmarkHome($0.id) },
                            open: { store.open($0); store.library = nil },
                            navigate: { scope = .folder($0) },
                            delete: { selection = [$0.id]; deleting = true },
                            paste: { board in
                                if case .imported = scope {
                                    store.notice = "请选择个人书签目录后再粘贴。"; return
                                }
                                let ids = store.pasteBookmarks(from: board, to: currentFolder)
                                if !ids.isEmpty { search = ""; selection = ids }
                            },
                            copy: { store.copyBookmarkItems($0, to: $1) },
                            cut: { store.cutBookmarkItems($0, to: $1) },
                            movable: store.personalBookmarkItemIDs,
                            move: { ids, folder in
                                let moved = store.moveBookmarkItems(ids, to: folder ?? currentFolder)
                                if moved { selection.removeAll() }
                                return moved
                            },
                            folderAction: { id, action in
                                guard let folder = store.bookmarkFolders.first(where: { $0.id == id }) else { return }
                                switch action {
                                case "newFolder":
                                    scope = .folder(id); folderDraft = BookmarkFolder(title: "", parentID: id)
                                    renamingFolder = false; folderPrompt = true
                                case "rename": folderDraft = folder; renamingFolder = true; folderPrompt = true
                                case "deleteFolder": folderToDelete = folder
                                default: break
                                }
                            },
                            pasteInto: { board, id in _ = store.pasteBookmarks(from: board, to: id) },
                            requestDelete: { if !deletable.isEmpty { deleting = true } },
                            preview: { store.bookmarkPreviewBrowser(for: $0) },
                            favicon: { store.cachedFavicon($0) })
                            .padding(.leading, -16)
                            .overlay(alignment: .topLeading) {
                                if rows.isEmpty {
                                    Text(search.isEmpty ? "此处没有书签" : "没有匹配的书签")
                                        .foregroundStyle(Style.muted).padding(16).allowsHitTesting(false)
                                }
                            }
                    }
                }
            }
            if scope == .history {
                Text("\(store.history.count) 条记录 · 最多保留最近 10,000 条")
                    .font(.caption).foregroundStyle(Style.muted).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Button("打开所选") {
                        store.openBookmarks(selected); store.library = nil
                    }.disabled(selected.isEmpty)
                    Button("删除所选…", role: .destructive) { deleting = true }
                        .disabled(deletable.isEmpty)
                    Menu("移动到…") {
                        Button("个人书签") { moveSelection(to: nil) }
                        ForEach(sortedFolders) { folder in
                            Button(store.bookmarkFolderPath(folder.id)) { moveSelection(to: folder.id) }
                        }
                    }.disabled(deletable.isEmpty)
                    Spacer()
                    Text("\(store.allBookmarks.count) 个书签").font(.caption).foregroundStyle(Style.muted)
                    }
            }
        }.padding(20)
            .onChange(of: search) { _ in selection.removeAll() }
            .onChange(of: scope) { value in
                selection.removeAll(); editing = nil; adding = false; search = ""
                store.libraryShowsHistory = value == .history
            }
            .onChange(of: store.bookmarkItemIDs) { ids in selection.formIntersection(ids) }
            .alert("清空全部历史记录？", isPresented: $clearHistory) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { store.deleteHistory() }
            } message: { Text("此操作不可撤销。书签和 Cookie 不受影响。") }
            .alert("删除 \(deletable.count) 个所选项目？", isPresented: $deleting) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    let ids = deletable
                    if store.deleteBookmarkItems(ids) {
                        selection.subtract(ids)
                        if let editing, ids.contains(editing.id) { self.editing = nil }
                    }
                }
            } message: { Text("将删除所选书签，以及所选目录中的所有子目录和书签。此操作不可撤销，导入数据和已打开的标签页不受影响。") }
            .alert(renamingFolder ? "重命名目录" : "新建目录", isPresented: $folderPrompt) {
                TextField("目录名称", text: $folderDraft.title)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    if store.saveBookmarkFolder(folderDraft) { scope = .folder(folderDraft.id) }
                }
            } message: {
                Text(renamingFolder ? "输入新的目录名称。" :
                     "创建在 \(currentFolder.map(store.bookmarkFolderPath) ?? "个人书签") 中。")
            }
            .alert("删除目录「\(folderToDelete?.title ?? "")」？", isPresented: Binding(
                get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }
            )) {
                Button("取消", role: .cancel) { folderToDelete = nil }
                Button("删除", role: .destructive) {
                    if let folder = folderToDelete, store.deleteBookmarkFolder(folder.id) {
                        if let currentFolder, store.bookmarkFolderDescendants(folder.id).contains(currentFolder)
                            || !store.bookmarkFolders.contains(where: { $0.id == currentFolder }) { scope = .root }
                    }
                    folderToDelete = nil
                }
            } message: {
                Text("将删除此目录、所有子目录及其中的 \(folderDeletionCount) 个书签。此操作不可撤销，导入目录不受影响。")
            }
    }

    private var sortedFolders: [BookmarkFolder] {
        store.bookmarkFolders.sorted { store.bookmarkFolderPath($0.id).localizedStandardCompare(store.bookmarkFolderPath($1.id)) == .orderedAscending }
    }
    private var folderDeletionCount: Int {
        guard let folderToDelete else { return 0 }
        let ids = store.bookmarkFolderDescendants(folderToDelete.id)
        return store.sites.filter { $0.folderID.map(ids.contains) == true }.count
    }
    private func moveSelection(to folderID: UUID?) {
        if store.moveBookmarkItems(deletable, to: folderID) { selection.removeAll() }
    }
    private var folderSidebar: some View {
        List {
            scopeButton("全部书签", icon: "square.stack", target: .all)
            scopeButton("个人书签", icon: "bookmark", target: .root)
            ForEach(store.bookmarkFolders.filter { $0.parentID == nil }) { folder in
                folderRow(folder, ancestors: [])
            }
            if !store.importedBookmarks.isEmpty {
                Section("浏览器导入") {
                    ForEach(store.importedBookmarks.keys.sorted(), id: \.self) { source in
                        scopeButton(source, icon: "folder", target: .imported(source))
                    }
                }
            }
            Section("历史记录") {
                scopeButton("全部记录", icon: "clock", target: .history)
            }
        }.listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Style.sidebar, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func scopeButton(_ name: String, icon: String, target: BookmarkScope) -> some View {
        Button { scope = target } label: {
            Label {
                Text(name)
            } icon: {
                Image(systemName: icon).foregroundStyle(Style.accent)
            }.lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                .background(scope == target ? Style.mint : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
            .onDrop(of: [BookmarkDrag.type.rawValue], isTargeted: nil) { providers in
                switch target {
                case .root: return drop(providers, to: nil)
                case .folder(let id): return drop(providers, to: id)
                default: return false
                }
            }
    }
    private func drop(_ providers: [NSItemProvider], to folder: UUID?) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var ids = Set<UUID>()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(BookmarkDrag.type.rawValue) {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: BookmarkDrag.type.rawValue) { data, _ in
                if let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) {
                    lock.lock(); ids.insert(id); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if store.moveBookmarkItems(ids, to: folder) { selection.removeAll() }
        }
        return !providers.isEmpty
    }
    private func folderRow(_ folder: BookmarkFolder, ancestors: Set<UUID>) -> AnyView {
        let children = store.bookmarkFolders.filter { $0.parentID == folder.id && !ancestors.contains($0.id) && $0.id != folder.id }
        let label = scopeButton(folder.title, icon: "folder", target: .folder(folder.id))
            .contextMenu { folderActions(folder) }
        if children.isEmpty { return AnyView(label) }
        return AnyView(DisclosureGroup {
            ForEach(children) { child in folderRow(child, ancestors: ancestors.union([folder.id])) }
        } label: { label })
    }
    @ViewBuilder
    private func folderActions(_ folder: BookmarkFolder) -> some View {
        Button("新建子目录…") {
            scope = .folder(folder.id)
            folderDraft = BookmarkFolder(title: "", parentID: folder.id); renamingFolder = false; folderPrompt = true
        }
        Button("重命名…") { folderDraft = folder; renamingFolder = true; folderPrompt = true }
        Menu("移动目录到") {
            Button("个人书签") {
                var moved = folder; moved.parentID = nil; _ = store.saveBookmarkFolder(moved)
            }
            ForEach(sortedFolders.filter { !store.bookmarkFolderDescendants(folder.id).contains($0.id) }) { destination in
                Button(store.bookmarkFolderPath(destination.id)) {
                    var moved = folder; moved.parentID = destination.id; _ = store.saveBookmarkFolder(moved)
                }
            }
        }
        Button("删除目录…", role: .destructive) { folderToDelete = folder }
    }
    private func edit(_ site: Site) {
        editing = site; adding = false; title = site.title; address = site.address
    }
    private var historyRecords: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scopeTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1).padding(.leading, 6)
            List {
                ForEach(store.history.filter { matches($0.title, $0.address) }) { visit in
                    Button {
                        store.newTab(address: visit.address, title: visit.title)
                        store.library = nil
                    } label: {
                        HStack {
                            Image(systemName: "clock").foregroundStyle(Style.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(visit.title.isEmpty ? visit.address : visit.title)
                                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(visit.address).font(.caption).foregroundStyle(Style.muted).lineLimit(1)
                            }
                            Spacer()
                            Text(visit.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(Style.muted)
                        }.padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain).contextMenu {
                        Button("在新标签页中打开") {
                            store.newTab(address: visit.address, title: visit.title)
                            store.library = nil
                        }
                        Button("加入书签") { _ = store.add(title: visit.title, address: visit.address) }
                        Button("复制网址") { copyAddress(visit.address) }
                        Button("从历史记录中移除", role: .destructive) { store.deleteHistory(visit.id) }
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(Style.paper)
        }
    }
    private func matches(_ title: String, _ address: String) -> Bool {
        search.isEmpty || title.localizedCaseInsensitiveContains(search) || address.localizedCaseInsensitiveContains(search)
    }
    private func filteredNodes(_ nodes: [BookmarkNode]) -> [BookmarkNode] {
        guard !search.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if matches(node.title, node.address ?? "") { return node }
            var copy = node
            if let children = node.children {
                copy.children = filteredNodes(children)
                if copy.children?.isEmpty == false { return copy }
            }
            return nil
        }
    }
}

@MainActor
final class BookmarkPreviewController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let browser: Browser
    var onClose: (() -> Void)?
    var onOpenTab: ((Site) -> Void)?
    private var closing = false
    private var finished = false
    private let defaults: UserDefaults
    private weak var parentWindow: NSWindow?
    private var escapeMonitor: Any?

    init(browser: Browser, title: String, parent: NSWindow, defaults: UserDefaults = .standard) {
        self.browser = browser
        self.defaults = defaults
        self.parentWindow = parent
        let available = parent.screen?.visibleFrame.size ?? NSSize(width: 1040, height: 720)
        let saved = defaults.string(forKey: LayoutPreference.previewContentSize.rawValue).map(NSSizeFromString) ?? NSSize(width: 960, height: 640)
        let valid = saved.width.isFinite && saved.height.isFinite && saved.width >= 640 && saved.height >= 420
        let preferred = valid ? saved : NSSize(width: 960, height: 640)
        let size = NSSize(width: max(640, min(preferred.width, available.width - 80)),
                          height: max(420, min(preferred.height, available.height - 80)))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary]
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 640, height: 420)
        let content = NSHostingView(rootView: BookmarkWebPreview(browser: browser, title: title,
                                                               openTab: { [weak self] in self?.openInTab() }))
        // The native window owns sizing; SwiftUI must not resize it during presentation or page updates.
        content.sizingOptions = []
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        window.setContentSize(size)
    }
    func show(in parent: NSWindow) {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53 else { return event }
            self.close()
            return nil
        }
        let bounds = parent.screen?.visibleFrame ?? parent.frame
        let frame = ScreenPlacement.fit(NSRect(x: parent.frame.midX - window.frame.width / 2,
                                               y: parent.frame.midY - window.frame.height / 2,
                                               width: window.frame.width, height: window.frame.height),
                                        from: bounds, to: bounds)
        window.setFrame(frame, display: false)
        parent.addChildWindow(window, ordered: .above)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.alphaValue = reduceMotion ? 1 : 0
        window.makeKeyAndOrderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                window.animator().alphaValue = 1
            }
        }
    }
    func openInTab() {
        guard !closing, let url = URLInput.parse(browser.address, search: false) else { return }
        onOpenTab?(Site(title: browser.title, address: url.absoluteString))
        close()
    }
    func close() {
        guard !closing else { return }
        closing = true
        window.ignoresMouseEvents = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !window.isVisible {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                window.animator().alphaValue = 0
            } completionHandler: { [self] in
                Task { @MainActor in finish() }
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    func windowDidResize(_ notification: Notification) { saveSize() }
    private func saveSize() {
        guard !window.styleMask.contains(.fullScreen), !changingFullScreen,
              let content = window.contentView, content.bounds.width >= 640, content.bounds.height >= 420 else { return }
        defaults.set(NSStringFromSize(content.bounds.size), forKey: LayoutPreference.previewContentSize.rawValue)
    }
    deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }
    private func finish() {
        guard !finished else { return }
        finished = true
        saveSize()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        let parent = parentWindow
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        if parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) }
        browser.webView.stopLoading()
        window.contentView = nil
        onClose?()
        onClose = nil
        onOpenTab = nil
    }
    private var changingFullScreen = false
    func windowWillEnterFullScreen(_ notification: Notification) { changingFullScreen = true }
    func windowDidEnterFullScreen(_ notification: Notification) { changingFullScreen = false }
    func windowWillExitFullScreen(_ notification: Notification) { changingFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { changingFullScreen = false; saveSize() }
}

private struct BookmarkWebPreview: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var browser: Browser
    let title: String
    let openTab: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                WindowControls().frame(width: 64, height: 28)
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack).help("后退")
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
                VStack(alignment: .leading, spacing: 3) {
                    Text(browser.title.isEmpty ? title : browser.title).font(.headline)
                    Text(browser.address).font(.caption).foregroundStyle(.secondary)
                }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                GlyphButton(symbol: "arrow.up.right.square", label: "在新标签页打开", size: 28, action: openTab)
            }.padding(.horizontal, 12).padding(.vertical, 8).background(WindowDragArea())
            Divider()
            ZStack(alignment: .top) {
                WebContent(browser: browser)
                if browser.loading { ProgressView(value: browser.progress).progressViewStyle(.linear) }
                if let error = browser.error {
                    VStack(spacing: 10) {
                        Text(error).foregroundStyle(.secondary)
                        Button("重试") { browser.webView.reload() }
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Style.paper)
                }
            }
        }.frame(minWidth: 640, idealWidth: 960, maxWidth: .infinity,
                minHeight: 420, idealHeight: 640, maxHeight: .infinity)
            .background(Style.paper).tint(Style.accent).preferredColorScheme(.light)
            .ignoresSafeArea(.container, edges: .top)
            .onDisappear { browser.webView.stopLoading() }
    }
}
