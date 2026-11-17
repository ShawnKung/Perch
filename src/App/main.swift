import AppKit
import SwiftUI
import WebKit

enum Style {
    static let ink = Color(red: 0.12, green: 0.20, blue: 0.19)
    static let muted = Color(red: 0.39, green: 0.46, blue: 0.44)
    static var accent: Color { Color(PerchTheme.shared.selection.accent) }
    static var mint: Color { Color(PerchTheme.shared.selection.mint) }
    static let paper = Color(red: 0.98, green: 0.98, blue: 0.96)
    static var sidebar: Color { Color(PerchTheme.shared.selection.sidebar) }
    static var line: Color { Color(PerchTheme.shared.selection.line) }
    static let chromeRadius: CGFloat = 10
}

struct Site: Identifiable, Codable {
    var id = UUID()
    var title: String
    var address: String
    var symbol: String = "globe"
    var folderID: UUID?
    var showOnHome: Bool?

    static let defaults = [
        Site(title: "Google", address: "https://www.google.com", symbol: "magnifyingglass"),
        Site(title: "DuckDuckGo", address: "https://duckduckgo.com", symbol: "magnifyingglass"),
        Site(title: "GitHub", address: "https://github.com", symbol: "chevron.left.forwardslash.chevron.right"),
        Site(title: "ChatGPT", address: "https://chatgpt.com", symbol: "bubble.left"),
        Site(title: "DeepSeek", address: "https://chat.deepseek.com", symbol: "bubble.left"),
        Site(title: "Qwen", address: "https://chat.qwen.ai", symbol: "bubble.left")
    ]
}

final class PageWebView: WKWebView {
    var extendMenu: ((NSMenu) -> Void)?
    private let scrollRouting = ScrollRouting()
    override func scrollWheel(with event: NSEvent) {
        for routed in scrollRouting.events(for: event) { super.scrollWheel(with: routed) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        extendMenu?(menu)
    }
}

enum WebsiteCookies {
    static func matches(_ cookie: HTTPCookie, host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let domain = cookie.domain.lowercased()
        let bareDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return !host.isEmpty && !bareDomain.isEmpty &&
            (host == bareDomain || (domain.hasPrefix(".") && host.hasSuffix("." + bareDomain)))
    }

    @MainActor static func clear(host: String, store: WKHTTPCookieStore) async -> Int {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        let selected = cookies.filter { matches($0, host: host) }
        for cookie in selected {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.delete(cookie) { continuation.resume() }
            }
        }
        return selected.count
    }
}

@MainActor
final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSMenuItemValidation {
    let webView: PageWebView
    let passwordBridge: PasswordBridge
    let hoverLinks: HoverLinkTracker?
    let previewDefaults: UserDefaults
    @Published var address = ""
    @Published var title = ""
    @Published var loading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var error: String?
    @Published var httpAlternative: URL?
    @Published var finding = false
    @Published var findQuery = ""
    func find(backward: Bool = false) {
        guard !findQuery.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backward; configuration.wraps = true
        webView.find(findQuery, configuration: configuration) { _ in }
    }
    var onVisit: ((String, String) -> Void)?
    var onNewTab: ((URL) -> Void)?
    var onBookmark: (() -> Void)?
    var isBookmarked: (() -> Bool)?
    var clipboard = NSPasteboard.general
    let favicon = FaviconLoader()
    private var observations: [NSKeyValueObservation] = []
    private var activeNavigation: WKNavigation?
    private var pendingHistoryItem: WKBackForwardListItem?
    private var provisionalFailure = false

    init(url: URL, userAgent: String? = nil, dataStore: WKWebsiteDataStore? = nil,
         trackHoverLinks: Bool = false, previewDefaults: UserDefaults = .standard) {
        self.previewDefaults = previewDefaults
        let tracker = trackHoverLinks ? HoverLinkTracker() : nil
        hoverLinks = tracker
        let bridge = PasswordBridge()
        passwordBridge = bridge
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore ?? .default()
        configuration.userContentController.add(bridge, contentWorld: .defaultClient, name: "perchPassword")
        configuration.userContentController.addUserScript(WKUserScript(source: PasswordBridge.script,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.addUserScript(WKUserScript(source: ScrollRouting.script,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        if let tracker {
            configuration.userContentController.add(tracker, contentWorld: .defaultClient, name: "perchHoverLink")
            configuration.userContentController.addUserScript(WKUserScript(source: HoverLinkTracker.script,
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
        webView = PageWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.extendMenu = { [weak self] menu in self?.extendContextMenu(menu) }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.customUserAgent = userAgent
        observations = [
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.syncNavigationState() }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.syncNavigationState() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.syncNavigationState() }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.address = view.url?.absoluteString ?? ""; self?.syncNavigationState() }
            }
        ]
        load(url)
    }

    func extendContextMenu(_ menu: NSMenu) {
        guard !menu.items.contains(where: { $0.target === self }) else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        func add(_ title: String, _ action: String) {
            let item = menu.addItem(withTitle: title, action: #selector(performContextMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [action, address]
            item.isEnabled = validateMenuItem(item)
        }
        add("后退", "back")
        add("前进", "forward")
        add(loading ? "停止加载" : "重新加载", loading ? "stop" : "reload")
        menu.addItem(.separator())
        add("复制当前网址", "copy")
        add("在默认浏览器打开", "external")
        if onBookmark != nil { add(isBookmarked?() == true ? "移除书签" : "加入书签", "bookmark") }
        add("在页面中查找…", "find")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let values = item.representedObject as? [String], values.count == 2 else { return false }
        switch values[0] {
        case "back": syncNavigationState(); return canGoBack
        case "forward": syncNavigationState(); return canGoForward
        case "stop": return webView.isLoading
        case "copy", "external", "bookmark", "reload": return URLInput.parse(values[1], search: false) != nil
        case "find": return true
        default: return false
        }
    }

    @objc private func performContextMenu(_ item: NSMenuItem) {
        guard validateMenuItem(item), let values = item.representedObject as? [String] else { return }
        switch values[0] {
        case "back": goBack()
        case "forward": goForward()
        case "reload": webView.reload()
        case "stop": webView.stopLoading()
        case "copy": clipboard.clearContents(); clipboard.setString(values[1], forType: .string)
        case "external":
            if let url = URLInput.parse(values[1], search: false) { NSWorkspace.shared.open(url) }
        case "bookmark": onBookmark?()
        case "find": finding = true
        default: break
        }
    }

    func load(_ url: URL) {
        error = nil
        httpAlternative = nil
        address = url.absoluteString
        provisionalFailure = false; pendingHistoryItem = nil
        activeNavigation = webView.load(URLRequest(url: url))
        syncNavigationState()
    }

    private var historyItems: [WKBackForwardListItem] {
        webView.backForwardList.backList + (webView.backForwardList.currentItem.map { [$0] } ?? []) + webView.backForwardList.forwardList
    }
    private var canCancelNewNavigation: Bool {
        guard pendingHistoryItem == nil, let current = webView.backForwardList.currentItem else { return false }
        return provisionalFailure || (webView.isLoading && current.url != webView.url)
    }
    private func syncNavigationState() {
        loading = webView.isLoading
        if let target = pendingHistoryItem, let index = historyItems.firstIndex(where: { $0 === target }) {
            canGoBack = index > 0; canGoForward = index < historyItems.count - 1
        } else {
            canGoBack = webView.canGoBack || canCancelNewNavigation
            canGoForward = webView.canGoForward
        }
    }
    func goBack() { navigateHistory(-1) }
    func goForward() { navigateHistory(1) }
    private func navigateHistory(_ step: Int) {
        if step < 0, canCancelNewNavigation {
            guard let current = webView.backForwardList.currentItem else { return }
            // Explicitly return to the committed item; stopLoading alone can miss a not-yet-started navigation.
            pendingHistoryItem = current
            activeNavigation = webView.go(to: current)
            if activeNavigation == nil { webView.stopLoading(); pendingHistoryItem = nil }
            provisionalFailure = false
            error = nil; httpAlternative = nil
            address = webView.backForwardList.currentItem?.url.absoluteString ?? address
            syncNavigationState()
            return
        }
        let items = historyItems
        guard let current = pendingHistoryItem ?? webView.backForwardList.currentItem,
              let index = items.firstIndex(where: { $0 === current }), items.indices.contains(index + step) else { return }
        let target = items[index + step]
        error = nil; httpAlternative = nil; provisionalFailure = false
        if target === webView.backForwardList.currentItem {
            pendingHistoryItem = target
            activeNavigation = webView.go(to: target)
            if activeNavigation == nil { webView.stopLoading(); pendingHistoryItem = nil }
            address = target.url.absoluteString
        } else {
            pendingHistoryItem = target
            activeNavigation = webView.go(to: target)
            if activeNavigation == nil { pendingHistoryItem = nil }
        }
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activeNavigation = navigation
        hoverLinks?.clear()
        passwordBridge.dismiss()
        error = nil
        httpAlternative = nil
        favicon.reset()
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        pendingHistoryItem = nil; provisionalFailure = false
        title = webView.title ?? ""
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        pendingHistoryItem = nil; provisionalFailure = false
        error = nil; httpAlternative = nil
        syncNavigationState()
        title = webView.title ?? ""
        if let url = webView.url { onVisit?(url.absoluteString, title) }
        favicon.load(from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === activeNavigation, (error as NSError).code != NSURLErrorCancelled else { return }
        pendingHistoryItem = nil; provisionalFailure = true
        report(error)
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === activeNavigation, (error as NSError).code != NSURLErrorCancelled else { return }
        pendingHistoryItem = nil
        report(error)
        syncNavigationState()
    }

    private func report(_ error: Error) {
        let failure = error as NSError
        guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
        self.error = error.localizedDescription
        httpAlternative = URLInput.httpAlternative(for: address, error: failure)
        if httpAlternative != nil {
            self.error = "这个内网地址无法建立 HTTPS 连接。若服务使用 HTTP，可改用 HTTP 打开（连接不加密）。"
        }
    }


    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else {
            error = "这个链接需要其他应用打开，请使用右上角的「在浏览器打开」。"
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.canShowMIMEType else {
            error = "此内容需要下载。请在默认浏览器中打开后下载。"
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // shortcut: links open in tabs; OAuth flows requiring window.opener need a dedicated popup implementation.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            onNewTab?(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "网页提示"
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "网页确认"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "网页输入"
        alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = "网页进程已退出，点击重新加载即可恢复。"
    }
}

@MainActor
final class Store: ObservableObject {
    lazy var linkPreview = LinkPreviewController(store: self)
    private let bookmarkClipboardSession = UUID()
    @Published var sites: [Site] = [] { didSet { suggestionRevision &+= 1 } }
    @Published var tabs: [Tab] = [] { didSet {
        for page in oldValue where !tabs.contains(where: { $0.id == page.id }) {
            var parts = URLComponents(string: page.address)
            parts?.user = nil; parts?.password = nil; parts?.query = nil; parts?.fragment = nil
            ai.referenceClosed(page.id, reference: AIPageReference(title: page.title, url: parts?.url))
        }
        ai.retainTabs(Set(tabs.map(\.id) + tabs.compactMap(\.chatOwner) + tabs.compactMap(\.aiOwner) + [AIController.homeID]))
    } }
    @Published var history: [Visit] = [] { didSet { suggestionRevision &+= 1 } }
    @Published var importedBookmarks: [String: [BookmarkNode]] = [:] { didSet { suggestionRevision &+= 1 } }
    @Published private(set) var suggestionRevision = 0
    let addressSuggestionSearch = AddressSuggestionSearch()
    @Published var bookmarkFolders: [BookmarkFolder] = []
    @Published var pendingPassword: SavedPassword?
    let passwords: PasswordVault
    let ai: AIController
    @Published private var homeAIVisible = false
    var aiVisible: Bool {
        get {
            guard !isChatPage else { return false }
            if let page = tabs.first(where: { $0.id == selected }) { return page.aiSidebarOpen ?? false }
            return homeAIVisible
        }
        set {
            guard !isChatPage else { return }
            let wasVisible = aiVisible
            if let index = tabs.firstIndex(where: { $0.id == selected }) {
                tabs[index].aiSidebarOpen = newValue
                persistTabs()
            } else { homeAIVisible = newValue }
            if newValue && !wasVisible { referenceCurrentPage() }
        }
    }
    @Published var selected: UUID? { didSet {
        if pendingAddressFocus != selected { pendingAddressFocus = nil }
        if oldValue != selected, let oldValue { browsers[oldValue]?.passwordBridge.dismiss() }
        if oldValue != selected && isChatPage { chatHistoryVisible = true }
        if oldValue != selected { selectionChanged?(oldValue, selected) }
        persistTabs()
    } }
    @Published var pendingAddressFocus: UUID?
    @Published var pinned = false
    @Published var adding = false
    @Published var notice: String?
    @Published var libraryShowsHistory = false
    @Published var library: LibraryPage? { didSet {
        if library != nil { browser?.passwordBridge.dismiss() }
        if library != .bookmarks { libraryShowsHistory = false }
    } }
    @Published var importing = false
    @Published var recentlyClosed: [Tab] = []
    @Published var settings: BrowserSettings
    @Published var icons: [UUID: NSImage] = [:]
    private var browsers: [UUID: Browser] = [:]
    let defaults: UserDefaults
    func cachedFavicon(_ address: String) -> NSImage? { FaviconCache.image(for: address, defaults: defaults) }
    func openBookmarks(history: Bool = false) {
        libraryShowsHistory = history
        library = .bookmarks
    }
    private var protectedKeys = Set<String>()
    var changeWindow: (() -> Void)?
    var hideWindow: (() -> Void)?
    var applyHotkeys: ((BrowserSettings) throws -> Void)?
    var shortcutRecording: ((Bool) -> Void)?
    var prepareTabSelection: (() -> Void)?
    var selectionChanged: ((UUID?, UUID?) -> Void)?
    var homeAddressDrafts: [UUID: [Bool: String]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ai = AIController(defaults: defaults)
        passwords = PasswordVault(memoryOnly: defaults !== UserDefaults.standard)
        settings = BrowserSettings()
        if let data = defaults.data(forKey: "settings") {
            do { settings = try JSONDecoder().decode(BrowserSettings.self, from: data) }
            catch { protectedKeys.insert("settings"); notice = "设置数据无法读取，已保留原数据。" }
        }
        PerchTheme.shared.selection = settings.theme
        PerchTheme.shared.chatFontSize = settings.chatFontSize
        if let data = defaults.data(forKey: "sites") {
            do { sites = try JSONDecoder().decode([Site].self, from: data) }
            catch { notice = "收藏数据无法读取，原始数据已保留。请先备份再添加网站。" }
        } else { sites = Site.defaults }
        let restoredTabs = restore([Tab].self, key: "tabs") ?? []
        let restoredSelection = defaults.string(forKey: "selectedTab").flatMap(UUID.init(uuidString:))
        let chatTab = restoredTabs.first { $0.chatOwner != nil && $0.id == restoredSelection } ??
            restoredTabs.first { $0.chatOwner != nil }
        tabs = restoredTabs.filter { $0.chatOwner == nil || $0.id == chatTab?.id }
        ai.classifyWebConversations(owners: Set(tabs.filter { !$0.address.isEmpty && $0.chatOwner == nil }.map { $0.aiOwner ?? $0.id }))
        for tab in tabs { icons[tab.id] = FaviconCache.image(for: tab.address, defaults: defaults) }
        history = restore([Visit].self, key: "history") ?? []
        importedBookmarks = restore([String: [BookmarkNode]].self, key: "importedBookmarks") ?? [:]
        bookmarkFolders = restore([BookmarkFolder].self, key: "bookmarkFolders") ?? []
        if let raw = defaults.string(forKey: "selectedTab"), let id = UUID(uuidString: raw), tabs.contains(where: { $0.id == id }) {
            selected = id
            activate(id)
        }
        if tabs.count != restoredTabs.count { persistTabs() }
    }

    var browser: Browser? {
        guard let selected else { return nil }
        return browsers[selected]
    }
    func cachedBrowser(for id: UUID) -> Browser? { browsers[id] }

    func open(_ site: Site) {
        newTab(address: site.address, title: site.title)
    }

    func openReferencedPage(_ url: URL) {
        guard let page = AIController.pageURL(url),
              let safeURL = URLInput.parse(url.absoluteString, search: false) else { return }
        if let tab = tabs.first(where: { tab in
            guard tab.chatOwner == nil, let address = URL(string: browsers[tab.id]?.address ?? tab.address) else { return false }
            return AIController.pageURL(address) == page
        }) {
            activate(tab.id)
        } else {
            newTab(address: safeURL.absoluteString)
        }
    }

    func openBookmarks(_ sites: [Site]) {
        let added = sites.filter { URLInput.parse($0.address, search: false) != nil }
            .map { Tab(title: $0.title, address: $0.address) }
        guard let first = added.first else { return }
        tabs.append(contentsOf: added)
        // Only load the active page; the other tabs load when selected.
        activate(first.id)
    }

    func activate(_ id: UUID, select: Bool = true) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if icons[id] == nil { icons[id] = FaviconCache.image(for: tab.address, defaults: defaults) }
        if browsers[id] == nil, let url = URLInput.parse(tab.address, search: false) {
            let view = Browser(url: url, userAgent: settings.userAgent,
                               dataStore: defaults === UserDefaults.standard ? .default() : .nonPersistent(),
                               trackHoverLinks: true, previewDefaults: defaults)
            linkPreview.start()
            view.hoverLinks?.changed = { [weak self] in self?.linkPreview.hoverChanged() }
            view.onVisit = { [weak self] address, title in
                guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
                self.tabs[index].address = address
                self.tabs[index].title = title.isEmpty ? URL(string: address)?.host ?? address : title
                self.persistTabs()
                self.recordVisit(title: title, address: address)
            }
            view.onNewTab = { [weak self] url in self?.newTab(address: url.absoluteString) }
            view.onBookmark = { [weak self, weak view] in
                guard let self, let view else { return }
                self.toggleBookmark(title: view.title, address: view.address)
            }
            view.isBookmarked = { [weak self, weak view] in
                guard let self, let view else { return false }
                return self.bookmark(for: view.address) != nil
            }
            view.passwordBridge.requested = { [weak self, weak view] origin, rect, token in
                guard let self, let view, self.selected == id, self.library == nil, !self.adding,
                      self.pendingPassword == nil else { return }
                do {
                    try self.passwords.load()
                    view.passwordBridge.show(self.passwords.entries.filter { $0.origin == origin },
                        at: rect, token: token, in: view.webView,
                        manage: { [weak self] in self?.library = .passwords },
                        failed: { [weak self] error in self?.notice = error })
                } catch {
                    // Automatic field focus must not interrupt typing; management shows any vault error.
                    view.passwordBridge.dismiss()
                }
            }
            view.passwordBridge.detected = { [weak self] candidate in
                guard let self, self.settings.savePasswords, self.library == nil, !self.adding,
                      self.pendingPassword == nil, self.selected == id else { return }
                do {
                    try self.passwords.load()
                    if self.passwords.entries.contains(where: {
                        $0.origin == candidate.origin && $0.username == candidate.username && $0.password == candidate.password
                    }) { return }
                    self.pendingPassword = candidate
                } catch {
                    // Keep inaccessible records intact and skip the automatic save suggestion.
                }
            }
            view.favicon.changed = { [weak self, weak view] image in
                guard let self, let view, self.tabs.contains(where: { $0.id == id }) else { return }
                if let image {
                    FaviconCache.save(image, for: view.address, defaults: self.defaults)
                    self.icons[id] = image
                } else {
                    self.icons[id] = FaviconCache.image(for: view.address, defaults: self.defaults)
                }
            }
            browsers[id] = view
        }
        if select { selected = id }
    }

    func newTab(address: String = "", title: String = "新标签页", after: UUID? = nil) {
        let tab = Tab(title: title == "新标签页" ? URL(string: address)?.host ?? title : title, address: address)
        if let after, let index = tabs.firstIndex(where: { $0.id == after }) {
            tabs.insert(tab, at: tabs[index].pinned ? tabs.filter(\.pinned).count : index + 1)
        } else { tabs.append(tab) }
        activate(tab.id)
        if address.isEmpty { pendingAddressFocus = tab.id }
    }

    @Published var chatHistoryVisible = true
    var chatOwner: UUID {
        let page = tabs.first(where: { $0.id == selected })
        return page?.chatOwner ?? page?.aiOwner ?? selected ?? AIController.homeID
    }
    var isChatPage: Bool { tabs.first(where: { $0.id == selected })?.chatOwner != nil }
    var currentPageURL: URL? {
        guard !isChatPage, let page = tabs.first(where: { $0.id == selected }),
              let url = URL(string: browser?.address.isEmpty == false ? browser!.address : page.address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    private func referenceCurrentPage() {
        guard let selected, currentPageURL != nil, ai.pendingEdits[chatOwner] == nil else { return }
        if !(ai.draftReferences[chatOwner] ?? []).contains(selected) {
            ai.draftReferences[chatOwner, default: []].append(selected)
        }
    }
    func newChat() {
        let previous = chatOwner
        let owner = ai.sessions[previous] == nil ? previous : UUID()
        ai.selections[owner] = ai.selections[previous]
        ai.selectedModels[owner] = ai.selectedModels[previous]
        if let index = tabs.firstIndex(where: { $0.id == selected }) {
            if isChatPage { tabs[index].chatOwner = owner }
            else { tabs[index].aiOwner = owner }
            persistTabs()
        }
        ai.drafts[owner] = ""; ai.draftFiles[owner] = []
        ai.draftReferences[owner] = []; ai.draftClosedReferences[owner] = []
        if aiVisible { referenceCurrentPage() }
        if !isChatPage && browser == nil { openChat(owner: owner) }
    }
    func openSidebarConversation(_ conversation: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == selected }), !isChatPage else { return }
        tabs[index].aiOwner = ai.resumeConversation(conversation, tab: chatOwner)
        persistTabs()
    }
    func openChat(owner: UUID? = nil, conversation: UUID? = nil) {
        let owner = conversation.map { ai.resumeConversation($0, tab: UUID()) } ?? owner ?? chatOwner
        if let index = tabs.firstIndex(where: { $0.chatOwner != nil }) {
            let chatID = tabs[index].id
            tabs[index].chatOwner = owner
            tabs.removeAll { $0.chatOwner != nil && $0.id != chatID }
            activate(chatID)
        }
        else if let index = tabs.firstIndex(where: { $0.id == selected && $0.address.isEmpty && $0.chatOwner == nil }) {
            tabs[index].chatOwner = owner; tabs[index].title = "Chat"
            activate(tabs[index].id)
        }
        else {
            let tab = Tab(title: "Chat", address: "", chatOwner: owner)
            tabs.append(tab); activate(tab.id)
        }
        chatHistoryVisible = true
        aiVisible = false
    }
    func referenceBrowser(_ id: UUID) -> Browser? { activate(id, select: false); return browsers[id] }
    var loadedReferencePages: [Browser] { tabs.compactMap { browsers[$0.id] } }
    func restoreReference(_ reference: AIPageReference) -> Browser? {
        func matches(_ tab: Tab) -> Bool {
            guard tab.chatOwner == nil, let url = URL(string: tab.address) else { return false }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.user = nil; parts?.password = nil; parts?.query = nil; parts?.fragment = nil
            return parts?.url == reference.url
        }
        if let page = tabs.first(where: matches) { return referenceBrowser(page.id) }
        let address = recentlyClosed.last(where: matches)?.address ?? reference.url?.absoluteString
        guard let address, let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        let page = Tab(title: reference.title, address: address)
        tabs.append(page)
        return referenceBrowser(page.id)
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        homeAddressDrafts[id] = nil
        var closed = tabs[index]
        if closed.chatOwner == nil { closed.aiOwner = closed.aiOwner ?? closed.id }
        tabs.remove(at: index)
        recentlyClosed.append(closed)
        recentlyClosed = Array(recentlyClosed.suffix(20))
        if let browser = browsers.removeValue(forKey: id) {
            browser.passwordBridge.dismiss(); browser.favicon.reset(); browser.webView.stopLoading()
            browser.webView.removeFromSuperview()
        }
        icons.removeValue(forKey: id)
        if selected == id {
            selected = nil
            if !tabs.isEmpty { activate(tabs[min(index, tabs.count - 1)].id) }
        }
        persistTabs()
    }

    func reopen() {
        guard var tab = recentlyClosed.popLast() else { return }
        if tab.chatOwner != nil, let existing = tabs.first(where: { $0.chatOwner != nil }) {
            activate(existing.id); return
        }
        tab.id = UUID()
        tabs.append(tab); sortPinned(); activate(tab.id)
    }

    func pin(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].pinned.toggle(); sortPinned(); persistTabs()
    }

    private func sortPinned() { tabs = tabs.filter(\.pinned) + tabs.filter { !$0.pinned } }

    func move(_ id: UUID, before target: UUID, after: Bool = false) {
        guard id != target, let source = tabs.firstIndex(where: { $0.id == id }),
              let destination = tabs.firstIndex(where: { $0.id == target }),
              tabs[source].pinned == tabs[destination].pinned else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: tabs.firstIndex(where: { $0.id == target })! + (after ? 1 : 0))
        persistTabs()
    }

    func canMove(_ id: UUID, to insertion: Int) -> Bool {
        guard let source = tabs.firstIndex(where: { $0.id == id }), (0...tabs.count).contains(insertion) else { return false }
        let fixed = tabs.filter(\.pinned).count
        return tabs[source].pinned ? insertion <= fixed : insertion >= fixed
    }

    func move(_ id: UUID, to insertion: Int) {
        guard canMove(id, to: insertion), let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: insertion - (source < insertion ? 1 : 0))
        persistTabs()
    }

    func closeOthers(_ id: UUID, below: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let ids = tabs.enumerated().filter { $0.element.id != id && !$0.element.pinned && (!below || $0.offset > index) }.map { $0.element.id }
        ids.forEach(close)
    }

    func reload(_ id: UUID) { activate(id); browser?.webView.reload() }

    private func restore<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { protectedKeys.insert(key); notice = "\(key) 数据无法读取，已保留原数据。"; return nil }
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard !protectedKeys.contains(key) else { return }
        do { defaults.set(try JSONEncoder().encode(value), forKey: key) }
        catch { notice = "保存失败：\(error.localizedDescription)" }
    }

    private func persistTabs() {
        persist(tabs, key: "tabs")
        defaults.set(selected?.uuidString, forKey: "selectedTab")
    }

    func mergeHistory(_ visits: [Visit]) {
        var keys = Set<String>()
        history = Array((history + visits).filter { URLInput.parse($0.address, search: false) != nil }
            .sorted { $0.date > $1.date }.filter {
                keys.insert($0.address + "|" + String(Int($0.date.timeIntervalSince1970))).inserted
            }.prefix(10000))
        persist(history, key: "history")
    }

    func recordVisit(title: String, address: String) {
        guard settings.historyRecordingEnabled else { return }
        mergeHistory([Visit(title: title, address: address, date: Date())])
    }

    func deleteHistory(_ id: UUID? = nil) {
        if let id { history.removeAll { $0.id == id } } else { history.removeAll() }
        persist(history, key: "history")
    }

    func saveSettings(_ value: BrowserSettings) throws {
        guard !protectedKeys.contains("settings") else {
            throw PerchError("设置数据无法读取，已保留原数据。请先备份并修复设置。")
        }
        try value.validate()
        try applyHotkeys?(value)
        let changed = settings.userAgent != value.userAgent
        settings = value
        PerchTheme.shared.selection = value.theme
        PerchTheme.shared.chatFontSize = value.chatFontSize
        linkPreview.settingsChanged()
        persist(value, key: "settings")
        if changed {
            for browser in browsers.values { browser.webView.customUserAgent = value.userAgent; browser.webView.reload() }
        }
    }

    func navigate(_ text: String) {
        guard let url = URLInput.parse(text, searchTemplate: settings.searchURL) else {
            notice = "请输入有效的 http / https 网址，或输入关键词搜索。"
            return
        }
        if let selected { homeAddressDrafts[selected] = nil }
        if let browser {
            if let index = tabs.firstIndex(where: { $0.id == selected }) {
                tabs[index].address = url.absoluteString
                tabs[index].title = url.host ?? url.absoluteString
                persistTabs()
            }
            browser.load(url)
        }
        else {
            if let selected, let index = tabs.firstIndex(where: { $0.id == selected }) {
                tabs[index].chatOwner = nil
                tabs[index].address = url.absoluteString; activate(selected)
            } else { newTab(address: url.absoluteString) }
        }
    }

    @discardableResult
    func add(title: String, address: String, folderID: UUID? = nil) -> Bool {
        guard validBookmarkFolder(folderID) else { return false }
        guard let url = URLInput.parse(address, search: false) else {
            notice = "请输入完整网址，例如 https://example.com。"
            return false
        }
        guard !sites.contains(where: { URLInput.parse($0.address, search: false) == url }) else {
            notice = "这个网站已经在收藏里了。"
            return false
        }
        let site = Site(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? url.host! : String(title.prefix(80)), address: url.absoluteString, folderID: folderID)
        let updated = sites + [site]
        guard save(updated) else { return false }
        sites = updated
        return true
    }

    func remove(_ site: Site) {
        _ = removeBookmarks([site.id])
    }

    func toggleBookmarkHome(_ id: UUID) {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        var updated = sites
        updated[index].showOnHome = !(updated[index].showOnHome != false)
        guard save(updated) else { return }
        sites = updated
    }

    func bookmarkPreviewBrowser(for site: Site) -> Browser? {
        guard let url = URLInput.parse(site.address, search: false) else { return nil }
        let browser = Browser(url: url, userAgent: settings.userAgent,
                              dataStore: defaults === UserDefaults.standard ? .default() : .nonPersistent(),
                              previewDefaults: defaults)
        browser.onNewTab = { [weak browser] url in browser?.load(url) }
        return browser
    }

    @discardableResult
    func pasteBookmarks(from board: NSPasteboard, to folderID: UUID?) -> Set<UUID> {
        if let data = board.data(forType: BookmarkClipboard.cutType),
           let cut = try? JSONDecoder().decode(BookmarkClipboard.Cut.self, from: data),
           cut.session == bookmarkClipboardSession {
            guard moveBookmarkItems(cut.ids, to: folderID) else { return [] }
            board.setData(Data(), forType: BookmarkClipboard.cutType)
            return cut.ids
        }
        guard let payload = BookmarkClipboard.payload(board),
              !payload.sites.isEmpty || !payload.folders.isEmpty,
              payload.sites.count + payload.folders.count <= 10_000 else {
            notice = "剪贴板中没有可粘贴的书签、目录或网址。"; return []
        }
        let folderIDs = Set(payload.folders.map(\.id))
        guard folderIDs.count == payload.folders.count else { notice = "剪贴板目录数据无效。"; return [] }
        let parents = Dictionary(uniqueKeysWithValues: payload.folders.map { ($0.id, $0.parentID) })
        var checked = Set<UUID>()
        for folder in payload.folders {
            var visited = Set<UUID>()
            var current: UUID? = folder.id
            while let id = current, folderIDs.contains(id), !checked.contains(id) {
                guard visited.insert(id).inserted else { notice = "剪贴板目录包含循环。"; return [] }
                current = parents[id] ?? nil
            }
            checked.formUnion(visited)
        }
        let mapping = Dictionary(uniqueKeysWithValues: folderIDs.map { ($0, UUID()) })
        var folders: [BookmarkFolder] = []
        var pasted = Set<UUID>()
        for folder in payload.folders {
            let name = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { notice = "剪贴板目录名称为空。"; return [] }
            let id = mapping[folder.id]!
            let parent = folder.parentID.flatMap { mapping[$0] }
            folders.append(BookmarkFolder(id: id, title: String(name.prefix(80)), parentID: parent ?? folderID))
            if parent == nil { pasted.insert(id) }
        }
        var copies: [Site] = []
        for site in payload.sites {
            guard let url = URLInput.parse(site.address, search: false) else {
                notice = "剪贴板中包含无效网址，未粘贴任何书签。"; return []
            }
            let name = site.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = site.folderID.flatMap { mapping[$0] }
            let copy = Site(title: name.isEmpty ? url.host! : String(name.prefix(80)),
                            address: url.absoluteString, folderID: parent ?? folderID)
            copies.append(copy)
            if parent == nil { pasted.insert(copy.id) }
        }
        guard validBookmarkFolder(folderID),
              saveBookmarkOrganization(sites: sites + copies, folders: bookmarkFolders + folders) else { return [] }
        return pasted
    }

    var personalBookmarkItemIDs: Set<UUID> { Set(sites.map(\.id) + bookmarkFolders.map(\.id)) }
    var bookmarkItemIDs: Set<UUID> {
        func ids(_ nodes: [BookmarkNode]) -> [UUID] { nodes.flatMap { [$0.id] + ids($0.children ?? []) } }
        return personalBookmarkItemIDs.union(importedBookmarks.values.flatMap { ids($0) })
    }

    func bookmarkSelectionPayload(_ ids: Set<UUID>) -> BookmarkClipboard.Payload {
        let folders = bookmarkFolders.filter { ids.contains($0.id) }
            .reduce(into: Set<UUID>()) { $0.formUnion(bookmarkFolderDescendants($1.id)) }
        var payload = BookmarkClipboard.Payload(
            sites: sites.filter { ids.contains($0.id) || $0.folderID.map(folders.contains) == true },
            folders: bookmarkFolders.filter { folders.contains($0.id) })
        func visit(_ node: BookmarkNode, parent: UUID?, included: Bool) {
            let included = included || ids.contains(node.id)
            if let children = node.children {
                if included { payload.folders.append(BookmarkFolder(id: node.id, title: node.title, parentID: parent)) }
                for child in children { visit(child, parent: included ? node.id : nil, included: included) }
            } else if included, let address = node.address {
                payload.sites.append(Site(id: node.id, title: node.title, address: address, folderID: parent))
            }
        }
        for source in importedBookmarks.keys.sorted() {
            for node in importedBookmarks[source] ?? [] { visit(node, parent: nil, included: false) }
        }
        var seen = Set<UUID>()
        payload.sites = payload.sites.filter { seen.insert($0.id).inserted }
        seen.removeAll()
        payload.folders = payload.folders.filter { seen.insert($0.id).inserted }
        return payload
    }

    func copyBookmarkItems(_ ids: Set<UUID>, to board: NSPasteboard) {
        BookmarkClipboard.write(bookmarkSelectionPayload(ids), to: board)
    }
    func cutBookmarkItems(_ ids: Set<UUID>, to board: NSPasteboard) {
        guard !ids.isEmpty, ids.isSubset(of: personalBookmarkItemIDs) else {
            notice = "导入目录为只读，请使用复制。"; return
        }
        copyBookmarkItems(ids, to: board)
        if let data = try? JSONEncoder().encode(BookmarkClipboard.Cut(session: bookmarkClipboardSession, ids: ids)) {
            board.setData(data, forType: BookmarkClipboard.cutType)
        }
    }

    @discardableResult
    func moveBookmarkItems(_ ids: Set<UUID>, to destination: UUID?) -> Bool {
        guard !ids.isEmpty, ids.isSubset(of: personalBookmarkItemIDs), validBookmarkFolder(destination) else { return false }
        let selectedFolders = Set(bookmarkFolders.filter { ids.contains($0.id) }.map(\.id))
        let descendants = selectedFolders.reduce(into: Set<UUID>()) { $0.formUnion(bookmarkFolderDescendants($1)) }
        guard destination.map({ !descendants.contains($0) }) ?? true else {
            notice = "目录不能移到自身或子目录中。"; return false
        }
        var folders = bookmarkFolders
        for index in folders.indices where selectedFolders.contains(folders[index].id) {
            if folders[index].parentID.map(descendants.contains) != true { folders[index].parentID = destination }
        }
        var updated = sites
        for index in updated.indices where ids.contains(updated[index].id) {
            if updated[index].folderID.map(descendants.contains) != true { updated[index].folderID = destination }
        }
        return saveBookmarkOrganization(sites: updated, folders: folders)
    }

    @discardableResult
    func deleteBookmarkItems(_ ids: Set<UUID>) -> Bool {
        let folders = bookmarkFolders.filter { ids.contains($0.id) }
            .reduce(into: Set<UUID>()) { $0.formUnion(bookmarkFolderDescendants($1.id)) }
        return saveBookmarkOrganization(
            sites: sites.filter { !ids.contains($0.id) && $0.folderID.map(folders.contains) != true },
            folders: bookmarkFolders.filter { !folders.contains($0.id) })
    }

    @discardableResult
    func removeBookmarks(_ ids: Set<UUID>) -> Bool {
        let updated = sites.filter { !ids.contains($0.id) }
        guard save(updated) else { return false }
        sites = updated
        return true
    }

    func bookmark(for address: String) -> Site? {
        guard let url = URLInput.parse(address, search: false) else { return nil }
        return allBookmarks.first { URLInput.parse($0.address, search: false) == url }
    }

    var allBookmarks: [Site] {
        sites + importedBookmarks.keys.sorted().flatMap { (importedBookmarks[$0] ?? []).flatMap(\.sites) }
    }

    func toggleBookmark(title: String, address: String) {
        if let url = URLInput.parse(address, search: false),
           sites.contains(where: { URLInput.parse($0.address, search: false) == url }) {
            let updated = sites.filter { URLInput.parse($0.address, search: false) != url }
            guard save(updated) else { return }
            sites = updated
        } else if bookmark(for: address) != nil {
            notice = "这个书签由浏览器导入，为只读。可以在书签管理中查看，重新导入会更新对应目录。"
        } else { _ = add(title: title, address: address) }
    }

    func edit(_ site: Site, title: String, address: String) -> Bool {
        guard let url = URLInput.parse(address, search: false),
              let index = sites.firstIndex(where: { $0.id == site.id }) else {
            notice = "请输入有效网址。"; return false
        }
        var updated = sites
        updated[index].title = title.isEmpty ? url.host! : String(title.prefix(80))
        updated[index].address = url.absoluteString
        guard save(updated) else { return false }
        sites = updated; return true
    }

    func replaceImportedBookmarks(_ nodes: [BookmarkNode], source: ImportSource) -> Int {
        guard !protectedKeys.contains("importedBookmarks") else {
            notice = "导入书签数据损坏，已保留原值，暂时禁止覆盖。"; return 0
        }
        var updated = importedBookmarks
        updated.removeValue(forKey: source.rawValue)
        updated[source.rawValue] = nodes
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: "importedBookmarks")
            importedBookmarks = updated
            return nodes.flatMap(\.sites).count
        } catch { notice = "导入书签保存失败：\(error.localizedDescription)"; return 0 }
    }

    func bookmarkFolderPath(_ id: UUID) -> String {
        var names: [String] = []
        var current: UUID? = id
        var visited = Set<UUID>()
        while let key = current, visited.insert(key).inserted,
              let folder = bookmarkFolders.first(where: { $0.id == key }) {
            names.insert(folder.title, at: 0)
            current = folder.parentID
        }
        return names.joined(separator: " / ")
    }

    func bookmarkFolderDescendants(_ id: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [id]
        while true {
            let children = Set(bookmarkFolders.filter { $0.parentID.map(ids.contains) == true }.map(\.id))
            let added = children.subtracting(ids)
            if added.isEmpty { return ids }
            ids.formUnion(added)
        }
    }

    @discardableResult
    func saveBookmarkFolder(_ folder: BookmarkFolder) -> Bool {
        let name = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { notice = "请输入目录名称。"; return false }
        guard validBookmarkFolder(folder.parentID),
              folder.parentID.map({ !bookmarkFolderDescendants(folder.id).contains($0) }) ?? true else {
            notice = "目录不能移到自身或子目录中。"; return false
        }
        var updated = bookmarkFolders
        var value = folder; value.title = String(name.prefix(80))
        if let index = updated.firstIndex(where: { $0.id == folder.id }) { updated[index] = value }
        else { updated.append(value) }
        return saveBookmarkOrganization(sites: sites, folders: updated)
    }

    @discardableResult
    func moveBookmarks(_ ids: Set<UUID>, to folderID: UUID?) -> Bool {
        guard validBookmarkFolder(folderID) else { return false }
        var updated = sites
        for index in updated.indices where ids.contains(updated[index].id) { updated[index].folderID = folderID }
        return saveBookmarkOrganization(sites: updated, folders: bookmarkFolders)
    }

    @discardableResult
    func deleteBookmarkFolder(_ id: UUID) -> Bool {
        let ids = bookmarkFolderDescendants(id)
        return saveBookmarkOrganization(
            sites: sites.filter { $0.folderID.map(ids.contains) != true },
            folders: bookmarkFolders.filter { !ids.contains($0.id) })
    }

    private func validBookmarkFolder(_ id: UUID?) -> Bool {
        guard let id else { return true }
        guard !protectedKeys.contains("bookmarkFolders"),
              bookmarkFolders.contains(where: { $0.id == id }) else {
            notice = "目标目录不可用，请重新选择。"; return false
        }
        return true
    }

    private func saveBookmarkOrganization(sites updatedSites: [Site], folders: [BookmarkFolder]) -> Bool {
        guard !protectedKeys.contains("bookmarkFolders"),
              defaults.data(forKey: "bookmarkFolders").map({
                  (try? JSONDecoder().decode([BookmarkFolder].self, from: $0)) != nil
              }) ?? true else {
            notice = "书签目录数据损坏，原始数据已保留，暂时禁止修改目录。"; return false
        }
        do {
            let folderData = try JSONEncoder().encode(folders)
            guard save(updatedSites) else { return false }
            defaults.set(folderData, forKey: "bookmarkFolders")
            bookmarkFolders = folders; sites = updatedSites
            return true
        } catch { notice = "书签目录保存失败：\(error.localizedDescription)"; return false }
    }

    private func save(_ value: [Site]) -> Bool {
        // Preserve unreadable data instead of silently replacing it on the next edit.
        if let existing = defaults.data(forKey: "sites"),
           (try? JSONDecoder().decode([Site].self, from: existing)) == nil {
            notice = "原收藏数据损坏，暂时禁止覆盖。请备份偏好设置后重置。"
            return false
        }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: "sites")
            return true
        } catch {
            notice = "收藏保存失败：\(error.localizedDescription)"
            return false
        }
    }
}

extension View {
    func arrowCursor() -> some View {
        onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }
}

struct GlyphButton: View {
    @ObservedObject private var theme = PerchTheme.shared
    let symbol: String
    let label: String
    var active = false
    var activeBackground = true
    var size: CGFloat = 32
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(active ? Style.accent : Style.muted)
                .background(active && activeBackground ? Style.mint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .arrowCursor()
    }
}

struct WebContent: NSViewRepresentable {
    let browser: Browser
    func makeNSView(context: Context) -> WebPageContainer { WebPageContainer() }
    func updateNSView(_ view: WebPageContainer, context: Context) {
        view.show(browser.webView)
    }
}

final class WebPageContainer: NSView {
    private var page: WKWebView?

    func show(_ page: WKWebView) {
        for view in subviews where view !== page { view.removeFromSuperview() }
        if page.superview !== self { addSubview(page) }
        self.page = page
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }

    override func layout() {
        super.layout()
        // The native tab controller owns visibility; detached pages keep their viewport.
        guard window != nil, let page, bounds.width > 0, bounds.height > 0 else { return }
        if page.frame != bounds { page.frame = bounds }
    }
}

struct BrowserAddressBar: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var browser: Browser
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 3) {
                GlyphButton(symbol: "chevron.left", label: "后退", size: 28) { browser.goBack() }
                    .disabled(!browser.canGoBack)
                GlyphButton(symbol: "chevron.right", label: "前进", size: 28) { browser.goForward() }
                    .disabled(!browser.canGoForward)
                GlyphButton(symbol: browser.loading ? "xmark" : "arrow.clockwise", label: browser.loading ? "停止加载" : "重新加载", size: 28) {
                    if browser.loading { browser.webView.stopLoading() } else { browser.webView.reload() }
                }
                HStack(spacing: 0) {
                    AddressEntry(store: store, currentAddress: browser.address)
                    PasswordFillButton(store: store, browser: browser)
                    let saved = store.bookmark(for: browser.address) != nil
                    GlyphButton(symbol: saved ? "star.fill" : "star",
                                label: saved ? "取消收藏当前网页" : "收藏当前网页", active: saved, activeBackground: false, size: 26) {
                        store.toggleBookmark(title: browser.title, address: browser.address)
                    }
                    .disabled(URLInput.parse(browser.address, search: false) == nil)
                    .accessibilityValue(saved ? "已收藏" : "未收藏")
                    .padding(.trailing, 3)
                }.background(Style.paper, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Style.line, lineWidth: 1).allowsHitTesting(false))
                    .overlay(alignment: .bottomLeading) {
                        if browser.loading {
                            let progress = min(max(browser.progress.isFinite ? browser.progress : 0, 0), 1)
                            GeometryReader { geometry in
                                Capsule().fill(Style.accent).frame(width: geometry.size.width * progress, height: 1.5)
                            }.frame(height: 1.5).padding(.horizontal, 8).padding(.bottom, 2).allowsHitTesting(false)
                                .accessibilityLabel("网页加载进度")
                                .accessibilityValue("\(Int(progress * 100))%")
                        }
                    }
        }
    }
}

struct HomeAddressBar: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    var body: some View {
        AddressEntry(store: store, homeTab: store.selected ?? AIController.homeID)
            .id(store.selected)
            .background(Style.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Style.line, lineWidth: 1).allowsHitTesting(false))
    }
}

struct BrowserScreen: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var browser: Browser
    var body: some View {
        VStack(spacing: 0) {
            if browser.finding { BrowserFindBar(browser: browser) }
            if let error = browser.error {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 32)).foregroundStyle(Style.muted)
                    Text("暂时无法显示这个网页").font(.title3.weight(.semibold))
                    Text(error).font(.callout).foregroundStyle(Style.muted).multilineTextAlignment(.center)
                    Button("重新加载") {
                        if let url = URLInput.parse(browser.address) { browser.load(url) }
                    }.buttonStyle(.borderedProminent).tint(Style.accent)
                    if let url = browser.httpAlternative {
                        Button("使用 HTTP 打开") { browser.load(url) }.buttonStyle(.bordered)
                    }
                }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).background(Style.paper)
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}

struct ContentTopChrome: ViewModifier {
    @ObservedObject private var theme = PerchTheme.shared
    var enabled = true
    func body(content: Content) -> some View {
        content.clipShape(BrowserTopCorners(rounded: enabled))
            .background(enabled ? Style.paper : Color.clear)
            .overlay(alignment: .top) {
                if enabled {
                    BrowserTopBorder().stroke(Style.line, lineWidth: 1).frame(height: Style.chromeRadius)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct BrowserTopCorners: Shape {
    var rounded = true
    func path(in rect: CGRect) -> Path {
        if !rounded { return Path(rect) }
        let radius = min(Style.chromeRadius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct BrowserTopBorder: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(Style.chromeRadius - 0.5, (rect.width - 1) / 2, rect.height - 0.5)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 0.5, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.5),
                    tangent2End: CGPoint(x: rect.minX + radius + 0.5, y: rect.minY + 0.5), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX - radius - 0.5, y: rect.minY + 0.5))
        path.addArc(tangent1End: CGPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5),
                    tangent2End: CGPoint(x: rect.maxX - 0.5, y: rect.maxY), radius: radius)
        return path
    }
}

struct BrowserFindBar: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var browser: Browser
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            TextField("在页面中查找", text: $browser.findQuery).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit { browser.find() }
            Button { browser.find(backward: true) } label: { Image(systemName: "chevron.up") }
            Button { browser.find() } label: { Image(systemName: "chevron.down") }
            Button { browser.finding = false } label: { Image(systemName: "xmark") }
        }.padding(8).background(Style.sidebar).onAppear { focused = true }
            .onExitCommand { browser.finding = false }
    }
}

struct HomeScreen: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    var body: some View {
        let shortcuts = store.sites.filter { $0.showOnHome != false }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 27)).foregroundStyle(Style.accent)
                        .frame(width: 52, height: 52).background(Style.mint, in: RoundedRectangle(cornerRadius: 16))
                    Spacer()
                    Text(Date(), format: .dateTime.month(.wide).day().weekday(.wide))
                        .font(.system(size: 12)).foregroundStyle(Style.muted)
                }
                VStack(alignment: .leading, spacing: 13) {
                    Text("把常用网页，\n放在手边。")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .tracking(-1).lineSpacing(3)
                    Text("少一次切换，多一点专注。").font(.system(size: 14)).foregroundStyle(Style.muted)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Style.muted)
                    AddressEntry(store: store, focusShortcut: false, homeTab: store.selected ?? AIController.homeID)
                        .id(store.selected)
                }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Style.line, lineWidth: 1))
                    .zIndex(20)
                Button { store.openChat() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.system(size: 23)).foregroundStyle(Style.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("打开 Chat").font(.system(size: 15, weight: .semibold))
                            Text("提问、引用标签页，继续之前的对话").font(.system(size: 12)).foregroundStyle(Style.muted)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(Style.muted)
                    }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Style.line))
                }.buttonStyle(.plain)

                if !shortcuts.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("快捷入口").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button { store.adding = true } label: { Label("添加", systemImage: "plus") }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Style.accent)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                            ForEach(shortcuts) { site in
                                Button { store.open(site) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: site.symbol).font(.system(size: 20))
                                            .frame(width: 32).foregroundStyle(Style.accent)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(site.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                            Text(URL(string: site.address)?.host ?? site.address)
                                                .font(.system(size: 10)).foregroundStyle(Style.muted).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Style.paper)
    }
}

struct AddSite: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    @State private var title = ""
    @State private var address = ""
    @FocusState private var focus: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("给网页留个位置", systemImage: "bookmark.fill")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Style.ink)
            Text("保存后，可以从菜单栏随时打开。").foregroundStyle(Style.muted)
            VStack(alignment: .leading, spacing: 8) {
                Text("网址").font(.callout)
                TextField("https://example.com", text: $address).focused($focus)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("新网站网址")
                Text("名称（可选）").font(.callout).padding(.top, 5)
                TextField("我的常用网站", text: $title).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("网站名称")
            }
            HStack {
                Spacer()
                Button("取消") { store.adding = false }.keyboardShortcut(.cancelAction)
                Button("添加网站") {
                    if store.add(title: title, address: address) { store.adding = false }
                }.buttonStyle(.borderedProminent).tint(Style.accent)
                    .keyboardShortcut(.defaultAction).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(28).frame(width: 380).onAppear { focus = true }
            .alert("提示", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button("知道了") { store.notice = nil }
            } message: { Text(store.notice ?? "") }
    }
}

struct WindowTools: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    @State private var cookieTarget: (host: String, store: WKHTTPCookieStore)?
    @State private var confirmingCookies = false
    var body: some View {
        HStack(spacing: 3) {
            if !store.isChatPage {
                GlyphButton(symbol: "sparkles", label: "AI 聊天", active: store.aiVisible, size: 28) {
                    store.aiVisible.toggle()
                }
            }
            GlyphButton(symbol: store.pinned ? "pin.fill" : "pin", label: "窗口置顶", active: store.pinned, size: 28) {
                store.pinned.toggle(); store.changeWindow?()
            }
            Menu {
                Button("书签管理") { store.openBookmarks() }
                Button("历史记录") { store.openBookmarks(history: true) }
                Button("密码管理") { store.library = .passwords }
                Divider()
                Button("在默认浏览器打开") {
                    if let url = URLInput.parse(store.browser?.address ?? "", search: false) { NSWorkspace.shared.open(url) }
                }.disabled(store.browser == nil)
                Divider()
                Button("回到首页") { store.selected = nil }
                Button("添加网站") { store.adding = true }
                Button("从浏览器导入…") { store.library = .importer }
                Button("清除当前网站的 Cookie…") {
                    guard let browser = store.browser, let url = browser.webView.url,
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host else { return }
                    cookieTarget = (host, browser.webView.configuration.websiteDataStore.httpCookieStore)
                    confirmingCookies = true
                }.disabled(store.browser?.webView.url?.host == nil || store.isChatPage)
                Divider()
                Text("Perch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                Button("退出 Perch") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("更多").accessibilityLabel("更多")
        }
        .alert("清除当前网站的 Cookie？", isPresented: $confirmingCookies) {
            Button("取消", role: .cancel) { cookieTarget = nil }
            Button("清除", role: .destructive) {
                guard let target = cookieTarget else { return }
                cookieTarget = nil
                Task { @MainActor in
                    let count = await WebsiteCookies.clear(host: target.host, store: target.store)
                    store.notice = count == 0 ? "此网站没有可清除的 Cookie。" : "已清除 \(count) 个 Cookie，请刷新网页后重新登录。"
                }
            }
        } message: {
            Text("将清除 \(cookieTarget?.host ?? "") 及共享给它的 Cookie。相同域名的其他端口或子域名可能同时退出登录；缓存和本地存储不受影响。")
        }
    }
}

struct SidebarResizeHandle: NSViewRepresentable {
    var changed: (CGFloat) -> Void
    var ended: () -> Void
    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.changed = changed; view.ended = ended
    }
    final class ResizeView: NSView {
        override var isFlipped: Bool { true }
        var changed: ((CGFloat) -> Void)?
        var ended: (() -> Void)?
        private var tracking: NSTrackingArea?
        private var resizeCursorActive = false
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
                                      owner: self)
            addTrackingArea(tracking!)
            window?.invalidateCursorRects(for: self)
            DispatchQueue.main.async { [weak self] in self?.syncCursor() }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { clearResizeCursor() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func cursorUpdate(with event: NSEvent) { syncCursor(at: event.locationInWindow) }
        override func mouseEntered(with event: NSEvent) { syncCursor(at: event.locationInWindow) }
        override func mouseExited(with event: NSEvent) { clearResizeCursor() }
        private func syncCursor(at windowPoint: NSPoint? = nil) {
            guard let window else { clearResizeCursor(); return }
            let point = convert(windowPoint ?? window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.intersection(visibleRect).contains(point) {
                resizeCursorActive = true
                NSCursor.resizeLeftRight.set()
            } else {
                clearResizeCursor()
            }
        }
        private func clearResizeCursor() {
            guard resizeCursorActive else { return }
            resizeCursorActive = false
            NSCursor.arrow.set()
        }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let start = event.locationInWindow.x
            NSCursor.resizeLeftRight.push()
            defer {
                NSCursor.pop()
                syncCursor()
                ended?()
                window.invalidateCursorRects(for: self)
            }
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                changed?(next.locationInWindow.x - start)
                if next.type == .leftMouseUp { break }
            }
        }
    }
}

final class RootHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        resizeHandle(in: self, rootPoint: point) ?? super.hitTest(point)
    }
    private func resizeHandle(in view: NSView, rootPoint: NSPoint) -> SidebarResizeHandle.ResizeView? {
        for child in view.subviews.reversed() where !child.isHidden && child.alphaValue > 0 {
            let local = child.convert(rootPoint, from: self)
            guard child.bounds.contains(local) else { continue }
            if let handle = child as? SidebarResizeHandle.ResizeView { return handle }
            if let handle = resizeHandle(in: child, rootPoint: rootPoint) { return handle }
        }
        return nil
    }
}

struct RootView: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    @AppStorage("sidebarHidden") private var sidebarCollapsed = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 199.0
    @State private var dragWidth: Double?
    @State private var liveSidebarWidth: Double?
    @AppStorage("aiSidebarWidth") private var aiWidth = 320.0
    @State private var aiDragWidth: Double?
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let sidebarAvailable = geometry.size.width - (store.aiVisible && !store.isChatPage ? aiSize(geometry.size.width) : 0)
                let tabSidebarWidth = liveSidebarWidth ?? (sidebarCollapsed ? 48 : Self.sidebarSize(sidebarWidth, available: sidebarAvailable))
                let controlsInset = Self.controlsInset(tabSidebarWidth)
                let topBarHeight = Self.topBarHeight(chat: store.isChatPage)
                HStack(spacing: 0) {
                    TabSidebar(store: store, compact: sidebarCollapsed, topBarHeight: topBarHeight)
                        .frame(width: tabSidebarWidth)
                        .clipped()
                    SidebarResizeHandle(changed: { translation in
                                if dragWidth == nil {
                                    dragWidth = sidebarCollapsed ? 48 : Self.sidebarSize(sidebarWidth, available: sidebarAvailable)
                                }
                                let width = Self.sidebarDragSize(dragWidth! + translation, available: sidebarAvailable)
                                liveSidebarWidth = width
                                sidebarCollapsed = width < 110
                                if width >= 145 { sidebarWidth = width }
                            }, ended: {
                                if let width = liveSidebarWidth, !sidebarCollapsed {
                                    sidebarWidth = Self.sidebarSize(width, available: sidebarAvailable)
                                }
                                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                    liveSidebarWidth = nil
                                }
                                dragWidth = nil
                            })
                        .frame(width: 7, height: max(0, geometry.size.height - topBarHeight - Style.chromeRadius))
                        .padding(.top, topBarHeight + Style.chromeRadius)
                        .padding(.horizontal, -3)
                        .background {
                            VStack(spacing: 0) {
                                Style.paper.frame(height: topBarHeight)
                                Style.sidebar
                            }
                        }
                        .overlay(alignment: .bottom) {
                            Style.line.frame(width: 1, height: max(0, geometry.size.height - topBarHeight - Style.chromeRadius))
                                .allowsHitTesting(false)
                        }
                        .accessibilityLabel("侧栏宽度")
                        .accessibilityAdjustableAction { direction in
                            let width = Self.sidebarDragSize((sidebarCollapsed ? 48 : sidebarWidth) +
                                (direction == .increment ? 20 : -20), available: sidebarAvailable)
                            sidebarCollapsed = width < 145
                            if direction == .increment && sidebarCollapsed {
                                sidebarCollapsed = false; sidebarWidth = 145
                            } else if !sidebarCollapsed { sidebarWidth = width }
                        }
                    TabContents(store: store, controlsInset: controlsInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.aiVisible && !store.isChatPage { HStack(spacing: 0) {
                        SidebarResizeHandle(changed: { translation in
                            if aiDragWidth == nil { aiDragWidth = aiSize(geometry.size.width) }
                            aiWidth = min(max(aiDragWidth! - translation, 260), 480)
                        }, ended: { aiDragWidth = nil })
                            .frame(width: 7).padding(.horizontal, -3)
                            .background(Style.sidebar)
                            .overlay(Style.line.frame(width: 1).allowsHitTesting(false))
                            .accessibilityLabel("AI 侧栏宽度")
                        AIChatSidebar(store: store, ai: store.ai) { store.aiVisible = false }
                            .id(store.chatOwner)
                            .frame(width: aiSize(geometry.size.width))
                    }.frame(width: aiSize(geometry.size.width) + 1, alignment: .leading)
                        .clipped()
                        .transition(.move(edge: .trailing))
                    }
                }.overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        WindowControls().frame(width: 64, height: 28)
                            .offset(x: 12, y: 8)
                        Button { sidebarCollapsed.toggle() } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.gray)
                        .help(sidebarCollapsed ? "展开侧栏" : "折叠侧栏")
                        .accessibilityLabel("切换侧栏")
                        .offset(x: 84, y: 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22),
                            value: sidebarCollapsed)
                    .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22),
                               value: store.aiVisible)
                    .transaction {
                        if liveSidebarWidth != nil || aiDragWidth != nil { $0.animation = nil; $0.disablesAnimations = true }
                    }
            }
        }
        .foregroundStyle(Style.ink).tint(Style.accent).preferredColorScheme(.light)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $store.adding) { AddSite(store: store) }
        .sheet(item: $store.library) { page in LibraryView(store: store, page: page) }
        .sheet(item: $store.pendingPassword) { candidate in PasswordPrompt(store: store, candidate: candidate) }
        .alert("提示", isPresented: Binding(get: { store.notice != nil && !store.adding && store.library == nil },
                                          set: { if !$0 { store.notice = nil } })) {
            Button("知道了") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }

    static func sidebarSize(_ width: Double, available: Double) -> Double {
        min(max(width.isFinite ? width : 199, 145), min(360, max(145, available - 285)))
    }
    static func controlsInset(_ sidebarWidth: Double) -> Double {
        max(0, 109 - sidebarWidth)
    }
    static func topBarHeight(chat: Bool) -> CGFloat {
        44
    }
    private func aiSize(_ available: Double) -> Double {
        min(max(aiWidth.isFinite ? aiWidth : 320, 260), min(480, max(260, available - (sidebarCollapsed ? 48 : 145) - 240)))
    }
    static func sidebarDragSize(_ width: Double, available: Double) -> Double {
        min(max(width.isFinite ? width : 199, 48), min(360, max(145, available - 285)))
    }
}

extension Notification.Name { static let focusAddress = Notification.Name("PerchFocusAddress") }

enum ScreenPlacement {
    static func screenIndex(for frame: NSRect, in screens: [NSRect]) -> Int? {
        screens.indices.filter { screens[$0].intersects(frame) }.max {
            let a = screens[$0].intersection(frame), b = screens[$1].intersection(frame)
            return a.width * a.height < b.width * b.height
        }
    }
    static func fit(_ frame: NSRect, from source: NSRect, to target: NSRect) -> NSRect {
        guard target.width > 0, target.height > 0 else { return frame }
        if frame.width > target.width || frame.height > target.height { return target }
        var result = frame
        if source != target {
            let x = max(0, min(1, (frame.minX - source.minX) / max(1, source.width - frame.width)))
            let y = max(0, min(1, (frame.minY - source.minY) / max(1, source.height - frame.height)))
            result.origin = NSPoint(x: target.minX + x * (target.width - frame.width),
                                    y: target.minY + y * (target.height - frame.height))
        }
        result.origin.x = max(target.minX, min(result.minX, target.maxX - result.width))
        result.origin.y = max(target.minY, min(result.minY, target.maxY - result.height))
        return result
    }
}

final class Panel: NSPanel {
    private final class FocusSnapshot {
        weak var responder: NSView?
        weak var field: NSTextField?
        let fieldIdentifier: NSUserInterfaceItemIdentifier?
        let selection: NSRange?
        let text: String?
        init(_ responder: NSView) {
            self.responder = responder
            if let editor = responder as? NSTextView {
                field = editor.isFieldEditor ? editor.delegate as? NSTextField : nil
                fieldIdentifier = field?.identifier
                selection = editor.selectedRange()
                text = editor.string
            } else {
                field = nil
                fieldIdentifier = nil
                selection = nil
                text = nil
            }
        }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private(set) var isHiding = false
    private var transition = 0
    private var focusedBeforeStatusClick = false
    private var tabFocus: [UUID: FocusSnapshot] = [:]
    private var selectedTab: UUID?
    private var restoringTabFocus = false
    private var pendingFieldSelection: (UUID, NSUserInterfaceItemIdentifier, NSRange, String)?
    var statusItemPressed: (() -> Bool)?

    @discardableResult override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if !restoringTabFocus, responder !== firstResponder, firstResponder is NSTextView {
            captureFocus(for: selectedTab)
        }
        return super.makeFirstResponder(responder)
    }

    func bindTabFocus(to store: Store) {
        selectedTab = store.selected
        store.prepareTabSelection = { [weak self, weak store] in self?.captureFocus(for: store?.selected) }
        store.selectionChanged = { [weak self, weak store] old, new in
            self?.captureFocus(for: old)
            self?.selectedTab = new
            self?.pendingFieldSelection = nil
            guard let new else { return }
            DispatchQueue.main.async {
                guard store?.selected == new else { return }
                self?.restoreFocus(for: new)
            }
        }
    }

    private func captureFocus(for tab: UUID?) {
        guard let tab, let view = firstResponder as? NSView, view.window === self else { return }
        if let editor = view as? NSTextView, editor.isFieldEditor, !(editor.delegate is NSTextField) { return }
        if let editor = view as? NSTextView, let nativeField = editor.delegate as? NSTextField,
           let field = nativeField as? AddressTextField.Field,
           field.ownerTab != tab { return }
        if let pending = pendingFieldSelection, pending.0 == tab,
           let editor = view as? NSTextView, (editor.delegate as? NSTextField)?.identifier == pending.1 { return }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current is TabTable { return }
            ancestor = current.superview
        }
        tabFocus[tab] = FocusSnapshot(view)
    }

    func restoreCurrentTabFocus() {
        if let selectedTab { restoreFocus(for: selectedTab) }
    }

    func restorePendingSelection(for field: NSTextField) {
        guard let (tab, identifier, range, text) = pendingFieldSelection, tab == selectedTab,
              field.identifier == identifier, let editor = field.currentEditor() as? NSTextView,
              editor.string == text else { return }
        pendingFieldSelection = nil
        let location = min(range.location, editor.string.utf16.count)
        editor.setSelectedRange(NSRange(location: location, length: min(range.length, editor.string.utf16.count - location)))
    }

    func cancelPendingFieldSelection() { pendingFieldSelection = nil }

    private func field(with identifier: NSUserInterfaceItemIdentifier, tab: UUID, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.identifier == identifier,
           (field as? AddressTextField.Field).map({ $0.ownerTab == tab }) ?? true { return field }
        return view.subviews.lazy.compactMap { self.field(with: identifier, tab: tab, in: $0) }.first
    }

    private func restoreFocus(for tab: UUID) {
        guard tab == selectedTab, let snapshot = tabFocus[tab] else { return }
        let target: NSView?
        if let identifier = snapshot.fieldIdentifier, let contentView {
            target = field(with: identifier, tab: tab, in: contentView)
        } else if let field = snapshot.field, field.window === self {
            target = field
        } else if let responder = snapshot.responder, responder.window === self {
            target = responder
        } else {
            tabFocus[tab] = nil
            return
        }
        guard let target, !target.isHiddenOrHasHiddenAncestor else { return }
        restoringTabFocus = true
        defer { restoringTabFocus = false }
        guard makeFirstResponder(target) else { return }
        guard let range = snapshot.selection,
              let editor = ((target as? NSTextField)?.currentEditor() as? NSTextView) ?? target as? NSTextView else { return }
        if let identifier = snapshot.fieldIdentifier, let text = snapshot.text, editor.string != text {
            pendingFieldSelection = (tab, identifier, range, text)
        } else {
            pendingFieldSelection = nil
        }
        let location = min(range.location, editor.string.utf16.count)
        editor.setSelectedRange(NSRange(location: location,
                                        length: min(range.length, editor.string.utf16.count - location)))
    }

    func restorePlacement(from defaults: UserDefaults = .standard) -> Bool {
        // AppKit frame autosave can relocate to the current main screen; retain global coordinates.
        guard let raw = defaults.string(forKey: "windowFrame") else { return false }
        let frame = NSRectFromString(raw)
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return false }
        setFrame(frame, display: false)
        return true
    }

    func savePlacement(to defaults: UserDefaults = .standard) {
        guard !styleMask.contains(.fullScreen) else { return }
        defaults.set(NSStringFromRect(frame), forKey: "windowFrame")
    }

    override func becomeKey() {
        super.becomeKey()
        focusedBeforeStatusClick = true
    }

    override func resignKey() {
        super.resignKey()
        if attachedSheet == nil { recordFocusLoss(statusItemPress: statusItemPressed?() ?? false) }
    }

    func recordFocusLoss(statusItemPress: Bool) {
        // The menu bar may take key/active status before delivering the button action.
        if !statusItemPress { focusedBeforeStatusClick = false }
    }

    func shouldHideForStatusClick() -> Bool {
        isVisible && !isHiding && focusedBeforeStatusClick
    }

    func focusWindow() {
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
        focusedBeforeStatusClick = true
    }

    func showAnimated() {
        transition += 1
        isHiding = false
        ignoresMouseEvents = false
        if !isVisible { alphaValue = 0 }
        focusWindow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            animator().alphaValue = 1
        }
    }

    func hideAnimated() {
        guard isVisible, !isHiding else { return }
        focusedBeforeStatusClick = false
        transition += 1
        let token = transition
        isHiding = true
        ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.transition == token else { return }
            self.orderOut(nil)
            self.alphaValue = 1
            self.ignoresMouseEvents = false
            self.isHiding = false
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: Store
    init(store: Store) { self.store = store; super.init() }
    override convenience init() { self.init(store: Store()) }
    var statusItem: NSStatusItem!
    var panel: Panel!
    let hotkeys = Hotkeys()
    private var hasWindowPlacement = false
    private var fittingScreen = false
    private var menuScreen: NSScreen?

    private static func statusImage() -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                   accessibilityDescription: "Perch 菜单栏浏览器"),
              let regular = symbol.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold)),
              let thicker = symbol.withSymbolConfiguration(.init(pointSize: 18, weight: .bold)) else { return nil }
        let image = NSImage(size: regular.size, flipped: false) { bounds in
            regular.draw(in: bounds)
            NSGraphicsContext.saveGraphicsState()
            let edges = NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 4))
            edges.appendRect(NSRect(x: 0, y: bounds.height - 4, width: bounds.width, height: 4))
            edges.addClip()
            thicker.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Perch 菜单栏浏览器"
        return image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.statusImage()
        statusItem.button?.toolTip = "Perch — 网页，轻轻停靠"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 850, height: 660),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                      backing: .buffered, defer: false)
        panel.title = "Perch"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 640, height: 520)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        panel.contentView = RootHostingView(rootView: RootView(store: store))
        panel.bindTabFocus(to: store)
        hasWindowPlacement = panel.restorePlacement()
        panel.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigurationChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        panel.statusItemPressed = { [weak self] in self?.isPressingStatusItem() ?? false }
        store.changeWindow = { [weak self] in self?.updateWindowLevel() }
        store.hideWindow = { [weak self] in self?.panel.hideAnimated() }
        store.applyHotkeys = { [weak self] settings in try self?.hotkeys.apply(settings) }
        store.shortcutRecording = { [weak self] recording in
            guard let self else { return }
            do {
                if recording { self.hotkeys.suspend() }
                else { try self.hotkeys.apply(self.store.settings) }
            } catch { self.store.notice = error.localizedDescription }
        }
        hotkeys.action = { [weak self] id in
            guard let self else { return }
            if id == 1 { self.present(on: self.mouseScreen()) }
            else if id == 3 { self.toggleWindow(on: self.mouseScreen()) }
            else if self.panel.attachedSheet == nil { self.panel.hideAnimated() }
        }
        do { try hotkeys.apply(store.settings) }
        catch { store.notice = error.localizedDescription }
        if store.settings.showWindowOnLaunch { show() }
    }

    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Perch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let edit = NSMenuItem()
        edit.title = "编辑"
        let editMenu = NSMenu(title: "编辑")
        for (name, selector, key) in [
            ("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
            ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")
        ] { editMenu.addItem(withTitle: name, action: Selector(selector), keyEquivalent: key) }
        edit.submenu = editMenu
        main.addItem(edit)
        let location = NSMenuItem(title: "输入网址", action: #selector(focusAddress), keyEquivalent: "l")
        location.target = self
        appMenu.addItem(location)
        for (title, action, key, shift) in [
            ("新建标签页", #selector(newTab), "t", false),
            ("关闭标签页", #selector(closeTab), "w", false),
            ("重新打开关闭的标签页", #selector(reopenTab), "t", true),
            ("设置…", #selector(settings), ",", false),
            ("历史记录", #selector(history), "y", false)
        ] {
            let item = appMenu.addItem(withTitle: title, action: action, keyEquivalent: shift ? key.uppercased() : key)
            item.target = self
            item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
        }
        let navigation = NSMenuItem(title: "浏览", action: nil, keyEquivalent: "")
        let navigationMenu = NSMenu(title: "浏览")
        for (title, action, key, modifiers) in [
            ("重新加载", #selector(reloadPage), "r", NSEvent.ModifierFlags.command),
            ("强制重新加载", #selector(reloadFromOrigin), "r", [.command, .shift]),
            ("后退", #selector(goBack), "[", .command),
            ("前进", #selector(goForward), "]", .command),
            ("收藏当前网页", #selector(bookmarkPage), "d", .command),
            ("查找", #selector(findPage), "f", .command),
            ("查找下一个", #selector(findNext), "g", .command),
            ("查找上一个", #selector(findPrevious), "g", [.command, .shift]),
            ("放大", #selector(zoomIn), "=", .command),
            ("放大", #selector(zoomIn), "+", [.command, .shift]),
            ("缩小", #selector(zoomOut), "-", .command),
            ("实际大小", #selector(resetZoom), "0", .command),
            ("下一个标签页", #selector(nextTab), "\t", .control),
            ("上一个标签页", #selector(previousTab), "\t", [.control, .shift]),
            ("下一个标签页", #selector(nextTab), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
            ("上一个标签页", #selector(previousTab), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
        ] {
            let equivalent = modifiers.contains(.shift) ?
                (key == "\t" ? String(UnicodeScalar(NSBackTabCharacter)!) : key.uppercased()) : key
            let item = navigationMenu.addItem(withTitle: title, action: action, keyEquivalent: equivalent)
            item.target = self; item.keyEquivalentModifierMask = modifiers
        }
        for number in 1...9 {
            let item = navigationMenu.addItem(withTitle: "标签页 \(number)", action: #selector(numberedTab(_:)), keyEquivalent: "\(number)")
            item.target = self; item.tag = number
        }
        navigation.submenu = navigationMenu; main.addItem(navigation)
        NSApp.mainMenu = main
    }

    @objc func newTab() { guard store.library == nil && !store.adding else { return }; store.newTab() }
    @objc func closeTab() {
        guard let window = NSApp.keyWindow else { return }
        if store.library != nil && (window === panel || window === panel?.attachedSheet) {
            if !store.importing { store.library = nil }
            return
        }
        if window !== panel { window.performClose(nil); return }
        guard store.library == nil && !store.adding else { return }
        if let id = store.selected { store.close(id) }
    }
    @objc func reopenTab() { guard store.library == nil && !store.adding else { return }; store.reopen() }
    @objc func settings() { store.library = .settings }
    @objc func history() { store.openBookmarks(history: true) }
    @objc func focusAddress() { NotificationCenter.default.post(name: .focusAddress, object: nil) }
    private var activeBrowser: Browser? { panel?.attachedSheet == nil && store.library == nil && !store.adding ? store.browser : nil }
    @objc func reloadPage() { activeBrowser?.webView.reload() }
    @objc func reloadFromOrigin() { activeBrowser?.webView.reloadFromOrigin() }
    @objc func goBack() { activeBrowser?.goBack() }
    @objc func goForward() { activeBrowser?.goForward() }
    @objc func bookmarkPage() {
        if let browser = activeBrowser { store.toggleBookmark(title: browser.title, address: browser.address) }
    }
    @objc func findPage() { activeBrowser?.finding = true }
    @objc func findNext() { activeBrowser?.find() }
    @objc func findPrevious() { activeBrowser?.find(backward: true) }
    @objc func zoomIn() { if let view = activeBrowser?.webView { view.pageZoom = min(3, view.pageZoom * 1.1) } }
    @objc func zoomOut() { if let view = activeBrowser?.webView { view.pageZoom = max(0.3, view.pageZoom / 1.1) } }
    @objc func resetZoom() { activeBrowser?.webView.pageZoom = 1 }
    @objc func nextTab() { switchTab(by: 1) }
    @objc func previousTab() { switchTab(by: -1) }
    private func switchTab(by offset: Int) {
        guard store.library == nil, !store.adding, panel?.attachedSheet == nil,
              let index = store.tabs.firstIndex(where: { $0.id == store.selected }), !store.tabs.isEmpty else { return }
        store.activate(store.tabs[(index + offset + store.tabs.count) % store.tabs.count].id)
    }
    @objc func numberedTab(_ sender: NSMenuItem) {
        guard store.library == nil, !store.adding, panel?.attachedSheet == nil, !store.tabs.isEmpty else { return }
        let index = sender.tag == 9 ? store.tabs.count - 1 : sender.tag - 1
        if store.tabs.indices.contains(index) { store.activate(store.tabs[index].id) }
    }
    @objc func toggle() {
        let clickedScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let showItem = menu.addItem(withTitle: "打开 Perch", action: #selector(show), keyEquivalent: "")
            showItem.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Perch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            menuScreen = clickedScreen
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            menuScreen = nil
            return
        }
        toggleWindow(on: clickedScreen)
    }

    func toggleWindow(on target: NSScreen? = nil) {
        if let target, target.frame != currentScreen()?.frame {
            present(on: target)
            return
        }
        if panel.shouldHideForStatusClick() { panel.hideAnimated() }
        else {
            NSApp.activate(ignoringOtherApps: true)
            if panel.isVisible && !panel.isHiding { clampToScreen(on: target); panel.focusWindow() }
            else { show() }
        }
    }

    private func isPressingStatusItem() -> Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0 ||
                NSApp.currentEvent?.type == .leftMouseDown ||
                NSApp.currentEvent?.type == .leftMouseUp,
              let button = statusItem?.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    func applicationDidResignActive(_ notification: Notification) {
        panel?.recordFocusLoss(statusItemPress: isPressingStatusItem())
    }

    @objc func show() {
        present(on: menuScreen)
    }

    private func mouseScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func currentScreen() -> NSScreen? {
        NSScreen.screens.max {
            let a = $0.visibleFrame.intersection(panel.frame)
            let b = $1.visibleFrame.intersection(panel.frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        } ?? NSScreen.main
    }

    private func present(on target: NSScreen?) {
        if !hasWindowPlacement, let button = statusItem.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            panel.setFrameOrigin(NSPoint(x: rect.maxX - panel.frame.width, y: rect.minY - panel.frame.height - 6))
        }
        clampToScreen(on: target)
        hasWindowPlacement = true
        panel.savePlacement()
        NSApp.activate(ignoringOtherApps: true)
        panel.showAnimated()
    }

    func clampToScreen(on target: NSScreen? = nil) {
        guard !fittingScreen, !panel.styleMask.contains(.fullScreen), !changingFullScreen,
              let screen = target ?? currentScreen() else { return }
        fittingScreen = true
        defer { fittingScreen = false }
        let bounds = screen.visibleFrame
        let source = currentScreen()?.visibleFrame ?? bounds
        let frame = ScreenPlacement.fit(panel.frame, from: source, to: bounds)
        panel.minSize = NSSize(width: min(640, bounds.width), height: min(520, bounds.height))
        panel.maxSize = bounds.size
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    @objc private func screenConfigurationChanged() {
        clampToScreen()
        panel.savePlacement()
    }

    func updateWindowLevel() {
        panel.level = store.pinned ? .floating : .normal
    }

    private var changingFullScreen = false
    func windowShouldClose(_ sender: NSWindow) -> Bool { panel.hideAnimated(); return false }
    func windowWillEnterFullScreen(_ notification: Notification) { changingFullScreen = true }
    func windowDidEnterFullScreen(_ notification: Notification) { changingFullScreen = false }
    func windowWillExitFullScreen(_ notification: Notification) { changingFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { changingFullScreen = false; clampToScreen() }
    func windowDidMove(_ notification: Notification) { if !changingFullScreen { panel.savePlacement() } }
    func windowDidResize(_ notification: Notification) { clampToScreen(); if !changingFullScreen { panel.savePlacement() } }
    func windowDidChangeScreen(_ notification: Notification) { clampToScreen(); if !changingFullScreen { panel.savePlacement() } }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { store.ai.saveConversations() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }
}

@main
enum Perch {
@MainActor
static func main() throws {
var appearanceDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
appearanceDefaults["AppleShowScrollBars"] = "WhenScrolling"
UserDefaults.standard.setVolatileDomain(appearanceDefaults, forName: UserDefaults.argumentDomain)
if CommandLine.arguments.contains("--scroll-self-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        setbuf(stdout, nil)
        do { try await ScrollSelfCheck.run(); exit(0) }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if CommandLine.arguments.contains("--web-tabs-self-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        setbuf(stdout, nil)
        do { try await WebTabSelfCheck.run(); exit(0) }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--navigation-self-test"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await NavigationSelfCheck.run(baseURL: CommandLine.arguments[index + 1]); exit(0) }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if CommandLine.arguments.contains("--ai-typography-self-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        setbuf(stdout, nil)
        app.activate(ignoringOtherApps: true)
        do { try await AISelfCheck.typographyUI(); exit(0) }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if CommandLine.arguments.contains("--ai-markdown-self-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        setbuf(stdout, nil)
        app.activate(ignoringOtherApps: true)
        do { try await AISelfCheck.markdown(); exit(0) }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--ai-background-self-test"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        setbuf(stdout, nil)
        do { try await AISelfCheck.backgroundChatChecks(baseURL: CommandLine.arguments[index + 1]); exit(0) }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--ai-streaming-self-test"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        setbuf(stdout, nil)
        do {
            let baseURL = CommandLine.arguments[index + 1]
            guard URL(string: baseURL)?.host == "127.0.0.1" else { throw PerchError("Streaming self-check requires loopback") }
            try await AISelfCheck.streamingChecks(baseURL: baseURL); exit(0)
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--ai-experience-self-test"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        setbuf(stdout, nil)
        do {
            let baseURL = CommandLine.arguments[index + 1]
            guard URL(string: baseURL)?.host == "127.0.0.1" else { throw PerchError("Experience self-check requires loopback") }
            try await AISelfCheck.experienceChecks(baseURL: baseURL); exit(0)
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--ai-files-self-test"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        do {
            setbuf(stdout, nil)
            let baseURL = CommandLine.arguments[index + 1]
            guard URL(string: baseURL)?.host == "127.0.0.1" else { throw PerchError("File self-check requires a loopback fixture") }
            try await AISelfCheck.fileChecks(baseURL: baseURL); exit(0)
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--ai-search-self-test"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            setbuf(stdout, nil)
            let baseURL = CommandLine.arguments[index + 1]
            guard URL(string: baseURL)?.host == "127.0.0.1" else { throw PerchError("Search self-check requires a loopback fixture") }
            try await AISelfCheck.searchChecks(baseURL: baseURL); exit(0)
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--ai-self-test"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    // GUI checks need a foreground application for accessibility and keyboard focus.
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        app.activate(ignoringOtherApps: true)
        do { try await AISelfCheck.run(baseURL: CommandLine.arguments[index + 1]); exit(0) }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--ai-composer-self-test"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        app.activate(ignoringOtherApps: true)
        do {
            setbuf(stdout, nil)
            let baseURL = CommandLine.arguments[index + 1]
            guard URL(string: baseURL)?.host == "127.0.0.1" else { throw PerchError("Composer self-check requires a loopback fixture") }
            try await AISelfCheck.composerUI(baseURL: baseURL); exit(0)
        }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if CommandLine.arguments.contains("--ai-reading-self-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            try await AISelfCheck.readingUI(config: AIConfiguration(provider: .custom, baseURL: "http://127.0.0.1:9/v1", model: "synthetic"))
            exit(0)
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if CommandLine.arguments.contains("--ai-connectivity-check") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await AISelfCheck.connection(); exit(0) }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else if CommandLine.arguments.contains("--ai-keychain-self-test") {
    try AISelfCheck.keychain()
} else if CommandLine.arguments.contains("--ai-preview") || CommandLine.arguments.contains("--ai-settings-preview") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = AISelfCheck.preview()
    withExtendedLifetime(window) { app.run() }
} else if CommandLine.arguments.contains("--self-test") {
    URLInput.selfTest()
    let encoded = try JSONEncoder().encode(Site.defaults)
    let decoded = try JSONDecoder().decode([Site].self, from: encoded)
    precondition(decoded.map(\.address) == Site.defaults.map(\.address))
    let suite = "dev.perch.selftest.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    let store = Store(defaults: preferences)
    precondition(!store.add(title: "Existing", address: "https://duckduckgo.com/"))
    precondition(store.add(title: "Example", address: "example.com"))
    precondition(!store.add(title: "Duplicate", address: "example.com"))
    let restored = Store(defaults: preferences)
    precondition(restored.sites.count == Site.defaults.count + 1)
    restored.remove(restored.sites.last!)
    precondition(Store(defaults: preferences).sites.count == Site.defaults.count)
    let damaged = Data("broken".utf8)
    preferences.set(damaged, forKey: "sites")
    let protected = Store(defaults: preferences)
    precondition(!protected.add(title: "Example", address: "example.com"))
    precondition(preferences.data(forKey: "sites") == damaged)
    preferences.removePersistentDomain(forName: suite)
    print("PASS: bookmark round trip, duplicate prevention, removal, corrupted-data preservation")
    try SelfTests.run()
} else if CommandLine.arguments.contains("--keychain-upgrade-write") || CommandLine.arguments.contains("--keychain-upgrade-read") || CommandLine.arguments.contains("--keychain-upgrade-deny") {
    try SelfTests.keychainUpgrade(write: CommandLine.arguments.contains("--keychain-upgrade-write"))
} else if CommandLine.arguments.contains("--keychain-self-test") {
    try SelfTests.keychain()
} else if CommandLine.arguments.contains("--ui-self-test") || CommandLine.arguments.contains("--ui-preview") {
    let app = NSApplication.shared
    // A CLI-launched test needs its own foreground identity while the installed menu-bar app is running.
    app.setActivationPolicy(CommandLine.arguments.contains("--ui-self-test") ? .regular : .accessory)
    Task { @MainActor in
        setbuf(stdout, nil)
        // Activate only after AppKit has finished launching the CLI process.
        _ = LayoutSelfCheck(preview: CommandLine.arguments.contains("--ui-preview"))
    }
    app.run()
} else if CommandLine.arguments.contains("--window-self-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let check = WindowSelfCheck()
    withExtendedLifetime(check) { app.run() }
} else if CommandLine.arguments.contains("--web-self-test") {
    let app = NSApplication.shared
    let check = WebSelfCheck()
    withExtendedLifetime(check) { app.run() }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
}
}
