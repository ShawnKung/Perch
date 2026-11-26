import AppKit
import SwiftUI
import WebKit

struct HomeScreen: NSViewRepresentable {
    @ObservedObject var page: TabContentState
    private var controller: HomePageController { page.homeController }
    func makeCoordinator() -> HomePageController { controller }
    func makeNSView(context: Context) -> WebPageContainer {
        context.coordinator.load()
        return WebPageContainer()
    }
    func updateNSView(_ view: WebPageContainer, context: Context) {
        view.show(context.coordinator.web)
        context.coordinator.update()
    }
    static func dismantleNSView(_ view: WebPageContainer, coordinator: HomePageController) {
        coordinator.stop()
    }
}

final class HomePageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard task.request.url == HomeHistoryPage.url else { task.didFailWithError(URLError(.unsupportedURL)); return }
        let data = InternalPage.document("home")
        task.didReceive(URLResponse(url: HomeHistoryPage.url, mimeType: "text/html",
                                   expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class HomePageWebView: WKWebView {
    weak var controller: HomePageController?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if window == nil {
            controller?.stop()
            callAsyncJavaScript("window.perchSuspend?.()", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                (self.window as? Panel)?.restoreCurrentTabFocus()
            }
        }
    }
}

@MainActor
final class HomePageController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var store: Store?
    private(set) var web: HomePageWebView!
    var tabID: UUID
    private(set) var pristine = true
    private var ready = false
    private var search: Task<Void, Never>?
    private var iconCache: [UUID: (NSImage, String)] = [:]
    private static let chatIcon: String = {
        // Rasterize at 2× for the homepage's 27px Retina icon.
        guard let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 54, weight: .regular)) else { return "" }
        return InternalPage.icon(image)
    }()
    private let anchor = BookmarkEditorAnchor.Anchor()
    private var anchoredID: UUID?
    init(store: Store, tabID: UUID) {
        self.store = store; self.tabID = tabID
        super.init()
        anchor.controller = store.bookmarkEditor
    }
    func load() {
        guard web == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(HomePageSchemeHandler(), forURLScheme: "perch-home")
        InternalPage.install("home", handler: self, in: configuration)
        web = HomePageWebView(frame: .zero, configuration: configuration)
        web.controller = self; web.navigationDelegate = self
        PerchTheme.shared.register(web)
        web.load(URLRequest(url: HomeHistoryPage.url))
    }
    func stop() { search?.cancel(); search = nil }
    func restoreFocus() {
        web?.callAsyncJavaScript("window.perchRestoreFocus?.()", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
    }
    deinit { search?.cancel() }
    func update() {
        guard ready, let web, let store else { return }
        PerchTheme.shared.update(web)
        let sites = store.homeShortcuts.map { site -> [String: Any] in
            var icon = ""
            if let image = store.cachedFavicon(site.address) {
                if iconCache[site.id]?.0 !== image { iconCache[site.id] = (image, InternalPage.icon(image)) }
                icon = iconCache[site.id]?.1 ?? ""
            }
            let symbols = ["magnifyingglass": "search", "chevron.left.forwardslash.chevron.right": "code", "bubble.left": "chat"]
            return ["id": site.id.uuidString, "title": site.title, "host": URL(string: site.address)?.host ?? site.address,
                    "symbol": symbols[site.symbol] ?? "globe", "icon": icon]
        }
        iconCache = iconCache.filter { id, _ in sites.contains { $0["id"] as? String == id.uuidString } }
        if let anchoredID, !sites.contains(where: { $0["id"] as? String == anchoredID.uuidString }) {
            anchor.removeFromSuperview(); self.anchoredID = nil
        }
        InternalPage.update(["owner": tabID.uuidString, "draft": store.homeAddressDrafts[tabID]?[false] ?? "",
                             "sites": sites, "revision": store.suggestionRevision, "chatIcon": Self.chatIcon,
                             "date": Date().formatted(.dateTime.month(.wide).day().weekday(.wide))], web: web)
        if let request = store.bookmarkEditRequest, sites.contains(where: { $0["id"] as? String == request.ownerID.uuidString }),
           anchor.window != nil, store.library == nil, !store.adding {
            DispatchQueue.main.async { [weak self, weak store] in
                guard let self, let store, self.anchor.window != nil,
                      store.bookmarkEditRequest?.id == request.id, store.library == nil, !store.adding else { return }
                store.bookmarkEditRequest = nil
                store.bookmarkEditor.show(request, store: store, anchor: self.anchor)
            }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard InternalPage.accepts(message, web: web, matches: { $0 == HomeHistoryPage.url }),
              let body = message.body as? [String: Any], let action = body["action"] as? String,
              let store, let web else { return }
        if action == "ready" { ready = true; update(); return }
        guard body["owner"] as? String == tabID.uuidString else { return }
        if action == "state" { pristine = body["pristine"] as? Bool ?? false; return }
        guard (store.selected ?? AIController.homeID) == tabID else { return }
        switch action {
        case "draft":
            if let text = body["text"] as? String {
                store.homeAddressDrafts[tabID, default: [:]][false] = text
            }
        case "query":
            guard let text = body["text"] as? String, let request = body["request"] as? Int else { return }
            search?.cancel()
            let owner = tabID
            search = Task { @MainActor [weak self, weak web, weak store] in
                guard let store else { return }
                do {
                    let items = try await store.suggestions(for: text)
                    try Task.checkCancellation()
                    guard let self, self.tabID == owner, let web, web.url == HomeHistoryPage.url else { return }
                    let state: [String: Any] = ["text": text, "request": request, "items": items.map {
                        ["title": $0.title, "address": $0.address, "bookmark": $0.bookmark] as [String: Any]
                    }]
                    _ = try await web.callAsyncJavaScript("window.perchSuggestions?.(state)", arguments: ["state": state],
                                                         in: nil, contentWorld: .defaultClient)
                } catch { /* New queries and page removal cancel the previous search. */ }
            }
        case "navigate":
            guard let text = body["text"] as? String else { return }
            store.pendingAddressFocus = nil
            (web.window as? Panel)?.endAddressEditing()
            store.navigate(text)
        case "chat": store.openChat()
        case "bookmarks": store.openBookmarks(scope: .all)
        case "add": store.adding = true
        case "reorder":
            guard let raw = body["ids"] as? [String] else { return }
            let ids = raw.compactMap(UUID.init(uuidString:))
            if ids.count == raw.count { _ = store.reorderHomeShortcuts(ids) }
            update()
        case "open", "menu", "anchor":
            guard let raw = body["id"] as? String, let id = UUID(uuidString: raw),
                  let site = store.homeShortcuts.first(where: { $0.id == id }) else { return }
            if action == "open" {
                if body["background"] as? Bool == true { store.newTab(address: site.address, after: tabID, select: false) }
                else { store.open(site) }
            } else if let x = body["x"] as? Double, let y = body["y"] as? Double,
                      let rect = body["rect"] as? [String: Double],
                      let left = rect["x"], let top = rect["y"], let width = rect["width"], let height = rect["height"],
                      [x,y,left,top,width,height].allSatisfy(\.isFinite), width > 0, height > 0 {
                guard action == "menu" || anchoredID == id else { return }
                anchoredID = id
                if anchor.superview !== web { web.addSubview(anchor) }
                anchor.frame = NSRect(x: left, y: web.isFlipped ? top : web.bounds.height-top-height, width: width, height: height)
                store.bookmarkEditor.updatePosition(for: anchor)
                if action == "menu" {
                    contextMenu(site).popUp(positioning: nil, at: NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height-y), in: web)
                }
            }
        default: break
        }
    }
    func contextMenu(_ site: Site) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, action) in [("在新标签页打开","newTab"),("临时浏览","preview"),("",""),
                                ("编辑书签…","edit"),("复制网址","copy"),("",""),("从首页移除","hide"),("删除书签","delete")] {
            if title.isEmpty { menu.addItem(.separator()); continue }
            let item = menu.addItem(withTitle: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = ["id": site.id.uuidString, "action": action]
        }
        return menu
    }
    @objc private func menuAction(_ item: NSMenuItem) {
        guard let store, let web, let body = item.representedObject as? [String: String],
              let raw = body["id"], let id = UUID(uuidString: raw),
              let site = store.homeShortcuts.first(where: { $0.id == id }),
              (store.selected ?? AIController.homeID) == tabID else { return }
        switch body["action"] {
        case "newTab": store.newTab(address: site.address, after: tabID)
        case "preview": if let window = web.window { store.bookmarkEditor.preview(site, store: store, parent: window, tabID: tabID) }
        case "edit":
            store.bookmarkEditRequest = BookmarkEditRequest(site: site, ownerID: site.id, showAddress: true)
            update()
        case "copy":
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(site.address, forType: .string)
        case "hide": store.toggleBookmarkHome(site.id)
        case "delete": store.remove(site)
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == HomeHistoryPage.url && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stop(); ready = false; webView.reload()
    }
}
