import AppKit
import SwiftUI
import QuartzCore

final class AIHistoryChevron: NSView {
    let shape = CAShapeLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4, y: 2))
        path.addLine(to: CGPoint(x: 8, y: 6))
        path.addLine(to: CGPoint(x: 4, y: 10))
        shape.path = path; shape.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        shape.fillColor = nil; shape.strokeColor = NSColor(Style.muted).cgColor
        shape.lineWidth = 1.5; shape.lineCap = .round; shape.lineJoin = .round
        layer?.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}

final class AIHistoryArchiveButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? super.hitTest(point) : nil
    }
}

final class AIHistoryProgress: NSProgressIndicator {
    private var displayObserver: NSObjectProtocol?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .spinning; controlSize = .small
        isIndeterminate = true; isDisplayedWhenStopped = true
        setAccessibilityLabel("正在生成")
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateAnimation() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
    private func updateAnimation() {
        if window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { startAnimation(nil) }
        else { stopAnimation(nil) }
    }
    deinit {
        if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) }
    }
}

final class AIHistoryCell: NSTableCellView {
    var archive: (() -> Void)?
    var archiveButton: NSButton?
    var disclosure: AIHistoryChevron?
    var progress: AIHistoryProgress?
    var titleTrailing: NSLayoutConstraint?
    private var hoverRevision = 0
    func rotateDisclosure(expanded: Bool, animated: Bool) {
        guard let layer = disclosure?.shape else { return }
        let angle = expanded ? -CGFloat.pi / 2 : 0
        let from = layer.presentation()?.value(forKeyPath: "transform.rotation.z") ?? layer.value(forKeyPath: "transform.rotation.z")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        CATransaction.commit()
        layer.removeAnimation(forKey: "disclosure")
        if animated {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = from; rotation.toValue = angle; rotation.duration = 0.22
            rotation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(rotation, forKey: "disclosure")
        }
    }
    func setHovered(_ hovered: Bool, animated: Bool) {
        let showArchive = hovered && progress == nil && archiveButton != nil
        hoverRevision += 1
        let revision = hoverRevision
        layoutSubtreeIfNeeded()
        titleTrailing?.constant = progress != nil || showArchive ? -38 : -8
        if showArchive { archiveButton?.isHidden = false }
        archiveButton?.isEnabled = showArchive
        let changes = {
            self.archiveButton?.alphaValue = showArchive ? 1 : 0
            self.layoutSubtreeIfNeeded()
        }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16; context.allowsImplicitAnimation = true
                changes()
            } completionHandler: { [weak self] in
                guard let self, self.hoverRevision == revision else { return }
                self.archiveButton?.isHidden = !showArchive
            }
        } else {
            changes(); archiveButton?.isHidden = !showArchive
        }
    }
    @objc func archiveConversation() { archive?() }
}

final class AIHistoryRow: TabSelectionRow {
    private(set) var hovered = false
    var conversation = false
    private var tracking: NSTrackingArea?
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? AIHistoryCell)?.setHovered(hovered, animated: false)
    }
    func setHovered(_ value: Bool, animated: Bool = true) {
        guard hovered != value else { return }
        hovered = value; needsDisplay = true
        subviews.compactMap { $0 as? AIHistoryCell }.forEach { $0.setHovered(value, animated: animated) }
    }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if conversation && hovered && !isSelected {
            theme.mint.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        setHovered(window.map { $0.isKeyWindow && bounds.intersection(visibleRect).contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false)
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseMoved(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
}

final class AIHistoryTable: NSTableView {
    var conversationIDs: [UUID?] = []
    var activateRow: ((Int) -> Void)?
    var makeMenu: ((Int) -> NSMenu?)?
    private var anchor: UUID?
    func choose(_ row: Int, modifiers: NSEvent.ModifierFlags) {
        guard conversationIDs.indices.contains(row), let id = conversationIDs[row] else {
            if conversationIDs.indices.contains(row) { activateRow?(row) }
            return
        }
        if modifiers.contains(.shift), let anchor, let start = conversationIDs.firstIndex(of: anchor) {
            let range = min(start, row)...max(start, row)
            selectRowIndexes(IndexSet(range.filter { conversationIDs[$0] != nil }), byExtendingSelection: modifiers.contains(.command) || modifiers.contains(.control))
        } else if modifiers.contains(.control) || modifiers.contains(.command) {
            if selectedRowIndexes.contains(row) { deselectRow(row) }
            else { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true) }
            anchor = id
        } else {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            anchor = id; activateRow?(row)
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        choose(row(at: convert(event.locationInWindow, from: nil)), modifiers: event.modifierFlags)
    }
    func contextMenu(at row: Int) -> NSMenu? {
        guard conversationIDs.indices.contains(row), conversationIDs[row] != nil else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            anchor = conversationIDs[row]
        }
        return makeMenu?(row)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu(at: row(at: convert(event.locationInWindow, from: nil)))
    }
}

enum AIHistoryGroup: String, CaseIterable {
    case pinned, chat, web
    var title: String {
        switch self {
        case .pinned: return "置顶会话"
        case .chat: return AIConversationOrigin.chat.title
        case .web: return AIConversationOrigin.web.title
        }
    }
    static func group(for session: AISession, archived: Bool) -> Self {
        if !archived && session.isPinned == true { return .pinned }
        return session.origin == .web ? .web : .chat
    }
}

struct AIHistoryList: NSViewRepresentable {
    @ObservedObject private var theme = PerchTheme.shared
    let conversations: [AISession]
    let active: UUID?
    let open: (UUID) -> Void
    let delete: (Set<UUID>) -> Void
    let fork: (UUID) -> Void
    var archived = false
    var restore: (Set<UUID>) -> Void = { _ in }
    var newChat: () -> Void = {}
    var rename: (UUID, String) -> Void = { _, _ in }
    var pin: (Set<UUID>, Bool) -> Void = { _, _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TabScrollView()
        let table = AIHistoryTable()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 40; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = NSColor(Style.sidebar); table.focusRingType = .none
        table.style = .plain
        table.floatsGroupRows = true
        table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.activateRow = { [weak coordinator = context.coordinator] in coordinator?.activate($0) }
        table.makeMenu = { [weak coordinator = context.coordinator] in coordinator?.menu($0) }
        table.setAccessibilityLabel("历史对话，Ctrl 或 Shift 多选")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.useTransientScrollers()
        scroll.fadesScrollerIn = true
        context.coordinator.table = table
        context.coordinator.refresh()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let table = scroll.documentView as? NSTableView {
            table.backgroundColor = NSColor(Style.sidebar)
        }
        context.coordinator.parent = self
        context.coordinator.theme = theme.selection
        context.coordinator.refresh()
        if let table = scroll.documentView as? NSTableView {
            table.enumerateAvailableRowViews { row, _ in
                if let row = row as? AIHistoryRow { row.theme = theme.selection }
                row.needsDisplay = true
            }
        }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: AIHistoryList
        var theme: ThemeColor = .green
        weak var table: AIHistoryTable?
        var rows: [(origin: AIHistoryGroup, session: AISession?)] = []
        var collapsed: Set<AIHistoryGroup> = []
        var menuSelection: Set<UUID> = []
        var forkID: UUID?
        private var pinSelection = false
        private var renderedRows: [String] = []
        private var renderedActive: UUID?
        private var renderedFontSize = BrowserSettings.defaultChatFontSize
        init(_ parent: AIHistoryList) { self.parent = parent }
        func sourceTitle(_ session: AISession) -> String? {
            let references = (session.pageReferences ?? []) + session.messages.flatMap(\.references)
            var seen = Set<String>()
            let titles = references.compactMap { reference -> String? in
                let title = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = !title.isEmpty ? title : (reference.url?.host ?? "")
                let key = reference.url?.absoluteString ?? name
                return !name.isEmpty && seen.insert(key).inserted ? "@ " + name : nil
            }
            if !titles.isEmpty { return titles.joined(separator: "  ") }
            let urls = (session.webPageURLs ?? []) + session.messages.compactMap(\.sourceURL)
            return urls.first.map { "@ " + ($0.host ?? $0.absoluteString) }
        }
        func refresh(animatedOrigin: AIHistoryGroup? = nil) {
            guard let table else { return }
            let signature = parent.conversations.map {
                "\($0.id)|\($0.title)|\(sourceTitle($0) ?? "")|\($0.updated.timeIntervalSince1970)|\($0.origin?.rawValue ?? "chat")|\($0.isPinned == true)|\($0.requestID != nil)"
            } +
                AIHistoryGroup.allCases.filter { collapsed.contains($0) }.map(\.rawValue)
            let fontSize = PerchTheme.shared.chatFontSize
            let fontChanged = renderedFontSize != fontSize
            guard signature != renderedRows || renderedActive != parent.active || fontChanged else { return }
            let topRow = table.rows(in: table.visibleRect).location
            let offset = topRow != NSNotFound && topRow < rows.count ? table.visibleRect.minY - table.rect(ofRow: topRow).minY : 0
            let activeChanged = renderedActive != parent.active
            renderedRows = signature; renderedActive = parent.active; renderedFontSize = fontSize
            let selected = Set(table.selectedRowIndexes.compactMap { table.conversationIDs.indices.contains($0) ? table.conversationIDs[$0] : nil })
            let oldRows = rows
            rows = AIHistoryGroup.allCases.flatMap { origin -> [(origin: AIHistoryGroup, session: AISession?)] in
                let sessions = parent.conversations.filter { AIHistoryGroup.group(for: $0, archived: parent.archived) == origin }
                if origin == .pinned && sessions.isEmpty { return [] }
                return [(origin: origin, session: nil)] + (collapsed.contains(origin) ? [] :
                    sessions.map { (origin: origin, session: Optional($0)) })
            }
            table.conversationIDs = rows.map { $0.session?.id }
            if let origin = animatedOrigin {
                let closing = collapsed.contains(origin)
                let affectedRows = closing ? oldRows : rows
                let affected = IndexSet(affectedRows.indices.filter {
                    affectedRows[$0].origin == origin && affectedRows[$0].session != nil
                })
                let header = oldRows.firstIndex { $0.origin == origin && $0.session == nil }!
                let cell = table.view(atColumn: 0, row: header, makeIfNecessary: false) as? AIHistoryCell
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduceMotion ? 0 : 0.22
                    cell?.rotateDisclosure(expanded: !closing, animated: !reduceMotion)
                    table.beginUpdates()
                    if closing {
                        table.removeRows(at: affected, withAnimation: reduceMotion ? [] : [.slideUp, .effectFade])
                    } else {
                        table.insertRows(at: affected, withAnimation: reduceMotion ? [] : [.slideDown, .effectFade])
                    }
                    table.endUpdates()
                }
            } else {
                table.reloadData()
            }
            if fontChanged {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
                if !activeChanged, topRow != NSNotFound, topRow < rows.count, let scroll = table.enclosingScrollView {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: topRow).minY + offset))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            let followActive = activeChanged || selected.isEmpty
            let ids = followActive ? Set(parent.active.map { [$0] } ?? []) : selected
            table.selectRowIndexes(IndexSet(rows.indices.filter { rows[$0].session.map { ids.contains($0.id) } == true }), byExtendingSelection: false)
            if animatedOrigin == nil, followActive, let active = parent.active, let row = table.conversationIDs.firstIndex(of: active) {
                table.scrollRowToVisible(row)
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].session != nil }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].session == nil }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            CGFloat((rows[row].session == nil ? 32 : 40) * PerchTheme.shared.chatScale)
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = AIHistoryRow()
            view.theme = theme
            view.conversation = rows[row].session != nil
            view.verticalInset = 3
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let entry = rows[row]
            let cell = AIHistoryCell()
            let textContainer: NSView
            if entry.session != nil {
                let clip = TabTitleClipView()
                clip.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(clip)
                cell.titleTrailing = clip.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8)
                NSLayoutConstraint.activate([
                    clip.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                    cell.titleTrailing!,
                    clip.topAnchor.constraint(equalTo: cell.topAnchor),
                    clip.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
                ])
                textContainer = clip
            } else { textContainer = cell }
            let label = NSTextField(labelWithString: entry.session.map {
                $0.title.isEmpty ? "附件对话" : $0.title
            } ?? entry.origin.title)
            label.font = .systemFont(ofSize: PerchTheme.shared.chatFontSize(relativeTo: 13), weight: entry.session == nil ? .semibold : .regular)
            label.textColor = NSColor(Style.ink); label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            textContainer.addSubview(label)
            cell.textField = label
            let source = entry.session.flatMap(sourceTitle)
            if source != nil { label.maximumNumberOfLines = 1 }
            let sourceLabel = source.map { text -> NSTextField in
                let view = NSTextField(labelWithString: text)
                view.font = .systemFont(ofSize: PerchTheme.shared.chatFontSize(relativeTo: 9.5))
                view.textColor = .secondaryLabelColor
                view.lineBreakMode = .byTruncatingTail
                view.translatesAutoresizingMaskIntoConstraints = false
                textContainer.addSubview(view)
                return view
            }
            if entry.session == nil {
                let disclosure = AIHistoryChevron()
                disclosure.translatesAutoresizingMaskIntoConstraints = false
                cell.disclosure = disclosure; cell.addSubview(disclosure)
                NSLayoutConstraint.activate([
                    disclosure.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    disclosure.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    disclosure.widthAnchor.constraint(equalToConstant: 12),
                    disclosure.heightAnchor.constraint(equalToConstant: 12)
                ])
                cell.rotateDisclosure(expanded: !collapsed.contains(entry.origin), animated: false)
            }
            if entry.session == nil && entry.origin == .chat && !parent.archived {
                let button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "新建对话")!, target: self, action: #selector(newConversation))
                button.isBordered = false; button.imagePosition = .imageOnly
                button.toolTip = "新建对话"; button.setAccessibilityLabel("在 Chat 分组新建对话")
                button.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(button)
                NSLayoutConstraint.activate([
                    button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    button.widthAnchor.constraint(equalToConstant: 22),
                    button.heightAnchor.constraint(equalToConstant: 22)
                ])
            }
            if let session = entry.session, !parent.archived {
                let button = AIHistoryArchiveButton(image: NSImage(systemSymbolName: "archivebox", accessibilityDescription: "归档对话")!,
                                      target: cell, action: #selector(AIHistoryCell.archiveConversation))
                button.isBordered = false; button.imagePosition = .imageOnly
                button.alphaValue = 0; button.isEnabled = false; button.isHidden = true
                button.toolTip = "归档对话"; button.setAccessibilityLabel("归档对话")
                button.translatesAutoresizingMaskIntoConstraints = false
                cell.archive = { [weak self] in self?.parent.delete([session.id]) }
                cell.archiveButton = button; cell.addSubview(button)
                NSLayoutConstraint.activate([
                    button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    button.widthAnchor.constraint(equalToConstant: 22),
                    button.heightAnchor.constraint(equalToConstant: 22)
                ])
            }
            if entry.session?.requestID != nil {
                let progress = AIHistoryProgress()
                progress.translatesAutoresizingMaskIntoConstraints = false
                cell.progress = progress; cell.addSubview(progress)
                NSLayoutConstraint.activate([
                    progress.centerXAnchor.constraint(equalTo: cell.trailingAnchor, constant: -21),
                    progress.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    progress.widthAnchor.constraint(equalToConstant: 16),
                    progress.heightAnchor.constraint(equalToConstant: 16)
                ])
            }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: entry.session == nil ? 20 : 10),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: entry.session == nil && !parent.archived ? -38 : -8)
            ])
            if let sourceLabel {
                let textGroup = NSLayoutGuide()
                cell.addLayoutGuide(textGroup)
                NSLayoutConstraint.activate([
                    textGroup.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    textGroup.topAnchor.constraint(equalTo: label.topAnchor),
                    textGroup.bottomAnchor.constraint(equalTo: sourceLabel.bottomAnchor),
                    textGroup.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                    textGroup.trailingAnchor.constraint(equalTo: label.trailingAnchor),
                    sourceLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                    sourceLabel.trailingAnchor.constraint(equalTo: label.trailingAnchor),
                    sourceLabel.topAnchor.constraint(equalTo: label.bottomAnchor)
                ])
            } else {
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
            }
            cell.toolTip = [entry.session?.title, source].compactMap { $0 }.joined(separator: "\n")
            cell.setHovered(false, animated: false)
            return cell
        }
        func activate(_ row: Int) {
            guard rows.indices.contains(row) else { return }
            if let session = rows[row].session { parent.open(session.id) }
            else {
                let origin = rows[row].origin
                if collapsed.contains(origin) { collapsed.remove(origin) } else { collapsed.insert(origin) }
                refresh(animatedOrigin: origin)
            }
        }
        func menu(_ row: Int) -> NSMenu? {
            guard let table, rows.indices.contains(row), let session = rows[row].session else { return nil }
            menuSelection = Set(table.selectedRowIndexes.compactMap { rows[$0].session?.id })
            forkID = session.id
            let menu = NSMenu()
            if menuSelection.count == 1 {
                let rename = NSMenuItem(title: "重命名…", action: #selector(renameConversation), keyEquivalent: "")
                rename.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
                rename.target = self; menu.addItem(rename)
            }
            let copy = NSMenuItem(title: "复制会话", action: #selector(copyConversation), keyEquivalent: "")
            copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            copy.target = self; menu.addItem(copy)
            if !parent.archived {
                pinSelection = parent.conversations.contains { menuSelection.contains($0.id) && $0.isPinned != true }
                let pin = NSMenuItem(title: pinSelection ? "置顶会话" : "取消置顶", action: #selector(pinConversations), keyEquivalent: "")
                pin.image = NSImage(systemSymbolName: pinSelection ? "pin" : "pin.slash", accessibilityDescription: nil)
                pin.target = self; menu.addItem(pin)
            }
            if parent.archived {
                let restore = NSMenuItem(title: "恢复对话", action: #selector(restoreSelection), keyEquivalent: "")
                restore.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
                restore.target = self; menu.addItem(restore)
            }
            let verb = parent.archived ? "彻底删除" : "归档"
            let remove = NSMenuItem(title: menuSelection.count > 1 ? "\(verb) \(menuSelection.count) 个会话" : "\(verb)会话",
                                    action: #selector(deleteSelection), keyEquivalent: "")
            remove.image = NSImage(systemSymbolName: parent.archived ? "trash" : "archivebox", accessibilityDescription: nil)
            remove.target = self; menu.addItem(remove)
            for item in menu.items { item.showImageIfSupported() }
            return menu
        }
        @objc func copyConversation() { if let forkID { parent.fork(forkID) } }
        @objc func renameConversation() {
            guard let id = forkID, let session = parent.conversations.first(where: { $0.id == id }),
                  let window = table?.window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = "重命名会话"
            alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
            let field = NSTextField(string: session.title)
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            field.setAccessibilityLabel("会话名称")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.parent.rename(id, field.stringValue) }
            }
            field.selectText(nil)
        }
        @objc func pinConversations() { parent.pin(menuSelection, pinSelection) }
        @objc func deleteSelection() { parent.delete(menuSelection) }
        @objc func restoreSelection() { parent.restore(menuSelection) }
        @objc func newConversation() { parent.newChat() }
    }
}
