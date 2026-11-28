import AppKit
import SwiftUI
import Combine

struct BookmarkFolder: Identifiable, Codable {
    var id = UUID()
    var title: String
    var parentID: UUID?
}

struct BookmarkEditRequest: Identifiable {
    let id = UUID()
    let site: Site
    let ownerID: UUID
    var showAddress = false
    var isNew = false
}

// A passive native anchor keeps the editor attached to the button without intercepting clicks.
struct BookmarkEditorAnchor: NSViewRepresentable {
    @ObservedObject var store: Store
    let ownerID: UUID
    final class Anchor: NSView {
        weak var controller: BookmarkEditorController?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { controller?.updatePosition(for: self) }
        }
    }
    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        view.controller = store.bookmarkEditor
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        store.bookmarkEditor.updatePosition(for: view)
        guard let request = store.bookmarkEditRequest, request.ownerID == ownerID else { return }
        DispatchQueue.main.async { [weak view, weak store] in
            guard let view, view.window != nil, let store,
                  store.bookmarkEditRequest?.id == request.id else { return }
            store.bookmarkEditRequest = nil
            guard !store.adding else { return }
            store.bookmarkEditor.show(request, store: store, anchor: view)
        }
    }
}

@MainActor
final class BookmarkEditorDraft: ObservableObject {
    let store: Store
    let request: BookmarkEditRequest
    @Published var title: String
    @Published var address: String
    @Published var folderID: UUID?
    @Published var showOnHome: Bool
    @Published var error: String?
    var finished = false
    init(store: Store, request: BookmarkEditRequest) {
        self.store = store; self.request = request
        title = request.site.title; address = request.site.address
        folderID = request.site.folderID; showOnHome = request.site.showOnHome != false
    }
    @discardableResult func save() -> Bool {
        if finished { return true }
        let site = request.site
        if title == site.title, address == site.address, folderID == site.folderID,
           showOnHome == (site.showOnHome != false) {
            finished = true; return true
        }
        guard store.edit(site, title: title, address: address, folderID: folderID, showOnHome: showOnHome) else {
            error = store.notice ?? "书签保存失败。"
            store.notice = nil
            return false
        }
        finished = true; return true
    }
    func remove() -> Bool {
        guard store.removeBookmarks([request.site.id]) else {
            error = store.notice ?? "书签删除失败。"; store.notice = nil; return false
        }
        finished = true; return true
    }
}

struct BookmarkEditorView: View {
    @ObservedObject var draft: BookmarkEditorDraft
    let close: () -> Void
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.request.isNew ? "已添加书签" : "编辑书签").font(.system(size: 16, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("名称")
                    TextField("名称", text: $draft.title).focused($nameFocused)
                        .accessibilityIdentifier("bookmark-editor-name")
                }
                if draft.request.showAddress {
                    GridRow {
                        Text("网址")
                        TextField("网址", text: $draft.address).accessibilityIdentifier("bookmark-editor-address")
                    }
                }
                GridRow {
                    Text("文件夹")
                    Picker("文件夹", selection: $draft.folderID) {
                        Text("个人书签").tag(Optional<UUID>.none)
                        ForEach(draft.store.bookmarkFolders.sorted {
                            draft.store.bookmarkFolderPath($0.id).localizedStandardCompare(draft.store.bookmarkFolderPath($1.id)) == .orderedAscending
                        }) { folder in
                            Text(draft.store.bookmarkFolderPath(folder.id)).tag(Optional(folder.id))
                        }
                    }.labelsHidden().accessibilityIdentifier("bookmark-editor-folder")
                }
            }
            Toggle("展示在首页", isOn: $draft.showOnHome)
                .toggleStyle(.checkbox).accessibilityIdentifier("bookmark-editor-home")
            if let error = draft.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("移除") { if draft.remove() { close() } }
                Spacer()
                Button("完成") { if draft.save() { close() } }.keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 340)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Style.line).allowsHitTesting(false))
        .foregroundStyle(Style.ink).tint(Style.accent).preferredColorScheme(.light)
        .onAppear { nameFocused = true }
    }
}

@MainActor
final class BookmarkEditorController: NSObject, NSWindowDelegate {
    private final class EditorPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    private(set) var window: NSPanel?
    private(set) var draft: BookmarkEditorDraft?
    private weak var anchor: NSView?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var draftObservation: AnyCancellable?
    private var previewController: BookmarkPreviewController?
    func show(_ request: BookmarkEditRequest, store: Store, anchor: NSView) {
        guard let parent = anchor.window, close() else { return }
        let draft = BookmarkEditorDraft(store: store, request: request)
        let window = EditorPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.delegate = self
        let content = NSHostingView(rootView: BookmarkEditorView(draft: draft) { [weak self] in
            self?.close()
        })
        content.sizingOptions = [.intrinsicContentSize]
        window.contentView = content
        self.draft = draft; self.window = window; self.anchor = anchor
        updatePosition(for: anchor)
        parent.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        draftObservation = draft.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let anchor = self.anchor else { return }
                self.updatePosition(for: anchor)
            }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            if event.type == .keyDown {
                if event.window === window, event.keyCode == 53 { self.close(); return nil }
            } else if let target = event.window, target !== window, target.level < .popUpMenu {
                self.close()
            }
            return event
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if note.name == NSWindow.willCloseNotification { self.window?.close() }
                    else if let anchor = self.anchor { self.updatePosition(for: anchor) }
                }
            })
        }
    }
    func updatePosition(for anchor: NSView) {
        guard self.anchor === anchor, let window, let content = window.contentView else { return }
        guard let parent = anchor.window else { window.close(); return }
        let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let bounds = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } ?? parent.screen)?.visibleFrame ?? parent.frame
        let size = content.intrinsicContentSize
        // Right-align below the trigger; use the space above only at the bottom screen edge.
        let y = rect.minY - size.height - 6
        let frame = NSRect(x: rect.maxX - size.width, y: y >= bounds.minY ? y : rect.maxY + 6,
                           width: size.width, height: size.height)
        window.setFrame(ScreenPlacement.fit(frame, from: bounds, to: bounds), display: window.isVisible)
    }
    @discardableResult func close() -> Bool {
        guard draft?.save() != false else { window?.makeKeyAndOrderFront(nil); return false }
        let parent = window?.parent
        let wasKey = window?.isKeyWindow == true
        window?.close()
        if wasKey, parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) }
        return true
    }
    func windowDidResignKey(_ notification: Notification) { close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        if let draft, !draft.save() { draft.store.notice = draft.error }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        draftObservation = nil
        if let window { window.parent?.removeChildWindow(window) }
        window = nil; draft = nil; anchor = nil
    }
    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    func preview(_ site: Site, store: Store, parent: NSWindow, tabID: UUID) {
        guard previewController == nil, let browser = store.bookmarkPreviewBrowser(for: site) else { return }
        let controller = BookmarkPreviewController(browser: browser, title: site.title, parent: parent, defaults: store.defaults)
        controller.onOpenTab = { [weak store] site in store?.newTab(address: site.address, after: tabID) }
        controller.onClose = { [weak self] in self?.previewController = nil }
        previewController = controller
        controller.show(in: parent)
    }
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

final class BookmarkListItem {
    let key: String
    var title: String
    var site: Site?
    let folderID: UUID?
    let editable: Bool
    let groupID: UUID?
    let groupColor: TabGroupColor?
    var children: [BookmarkListItem]?
    init(key: String, title: String = "", site: Site? = nil, folderID: UUID? = nil,
         editable: Bool = false, children: [BookmarkListItem]? = nil,
         groupID: UUID? = nil, groupColor: TabGroupColor? = nil) {
        self.key = key; self.title = site.map { $0.title.isEmpty ? $0.address : $0.title } ?? title
        self.site = site; self.folderID = folderID; self.editable = editable; self.children = children
        self.groupID = groupID; self.groupColor = groupColor
    }
    var id: UUID? { site?.id ?? folderID }
    var selectable: Bool { groupID != nil || (site.map { URLInput.parse($0.address, search: false) != nil } ?? (folderID != nil)) }
    var signature: String {
        // Length-prefix each value so titles and URLs cannot collide with structural separators.
        let values = [key, title, site?.address ?? "", site?.id.uuidString ?? "",
                      folderID?.uuidString ?? "", String(site?.showOnHome != false),
                      String(editable), children == nil ? "leaf" : "folder", groupID?.uuidString ?? "", groupColor?.rawValue ?? ""]
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
    static func personal(_ sites: [Site], folders: [BookmarkFolder], parentID: UUID?, query: String) -> [BookmarkListItem] {
        let sitesByFolder = Dictionary(grouping: sites, by: \.folderID)
        let foldersByParent = Dictionary(grouping: folders, by: \.parentID)
        func matches(_ title: String, _ address: String = "") -> Bool {
            query.isEmpty || title.localizedCaseInsensitiveContains(query) || address.localizedCaseInsensitiveContains(query)
        }
        func rows(in parent: UUID?, ancestors: Set<UUID>, includeAll: Bool) -> [BookmarkListItem] {
            guard ancestors.count < 64 else { return [] }
            let directories = (foldersByParent[parent] ?? []).compactMap { folder -> BookmarkListItem? in
                guard !ancestors.contains(folder.id) else { return nil }
                let matched = includeAll || matches(folder.title)
                let children = rows(in: folder.id, ancestors: ancestors.union([folder.id]), includeAll: matched)
                guard matched || !children.isEmpty else { return nil }
                return BookmarkListItem(key: folder.id.uuidString, title: folder.title, folderID: folder.id, children: children)
            }
            return directories + (sitesByFolder[parent] ?? []).filter {
                includeAll || matches($0.title, $0.address)
            }.map { BookmarkListItem(key: $0.id.uuidString, site: $0, editable: true) }
        }
        return rows(in: parentID, ancestors: Set(parentID.map { [$0] } ?? []), includeAll: query.isEmpty)
    }
}

enum BookmarkScope: Equatable {
    case all, root, folder(UUID), imported(String), group(UUID)
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
        browser.onOpenInPerch = { [weak self] url in
            self?.openInTab(url)
        }
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.animationBehavior = .none
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
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Adding a child orders it on screen, so prepare opacity before attachment.
        window.alphaValue = reduceMotion ? 1 : 0
        parent.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                window.animator().alphaValue = 1
            }
        }
    }
    func openInTab(_ address: URL? = nil) {
        guard !closing, let url = URLInput.parse(address?.absoluteString ?? browser.address, search: false) else { return }
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
