import AppKit
import WebKit
import Combine

enum HistoryPage {
    static let url = URL(string: "perch://history")!
    static func matches(_ url: URL?) -> Bool { InternalPage.matches(url, host: "history") }
}

@MainActor
final class HistoryPageBridge: NSObject, WKScriptMessageHandler {
    weak var web: WKWebView?
    weak var store: Store?
    private var subscriptions: [AnyCancellable] = []
    private var error = ""
    private var viewState: [String: Any] = [:]

    func stop() { subscriptions.removeAll() }
    func start() {
        guard subscriptions.isEmpty, let store else { update(); return }
        store.$history.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &subscriptions)
        store.$settings.map(\.historyRecordingEnabled).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &subscriptions)
        PerchTheme.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &subscriptions)
        update()
    }
    func update() {
        guard let web, HistoryPage.matches(web.url), let store else { return }
        PerchTheme.shared.update(web)
        let records = store.history.map {
            ["id": $0.id.uuidString, "title": $0.title, "address": $0.address,
             "date": $0.date.timeIntervalSince1970 * 1000] as [String: Any]
        }
        InternalPage.update(["records": records, "recording": store.settings.historyRecordingEnabled,
                             "error": error, "viewState": viewState], web: web)
    }
    func restoreView() {
        guard let web, HistoryPage.matches(web.url) else { return }
        // WebKit restores form controls during history traversal, after the document's ready message.
        web.callAsyncJavaScript("window.perchRestore?.(state)", arguments: ["state": viewState],
                                in: nil, in: .defaultClient, completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard InternalPage.accepts(message, web: web, matches: HistoryPage.matches),
              let body = message.body as? [String: Any], let action = body["action"] as? String,
              let store else { return }
        switch action {
        case "ready": start()
        case "viewState":
            guard let query = body["query"] as? String, query.count <= 10000,
                  let ids = body["selected"] as? [String], ids.count <= 10000,
                  let scroll = body["scroll"] as? Double, scroll.isFinite, scroll >= 0,
                  let limit = body["limit"] as? Int, (100...10000).contains(limit) else { return }
            viewState = ["query": query, "selected": ids, "scroll": scroll, "limit": limit]
        case "recording":
            guard let enabled = body["enabled"] as? Bool else { return }
            var settings = store.settings
            settings.historyRecordingEnabled = enabled
            do { try store.saveSettings(settings); error = "" }
            catch { self.error = "设置未生效：\(error.localizedDescription)" }
            update()
        case "delete":
            guard let raw = body["ids"] as? [String], raw.count <= 10000 else { return }
            let ids = Set(raw.compactMap(UUID.init(uuidString:)))
            guard ids.count == raw.count else { return }
            store.deleteHistory(ids: ids)
        case "open":
            guard let raw = body["id"] as? String, let id = UUID(uuidString: raw),
                  let visit = store.history.first(where: { $0.id == id }),
                  URLInput.parse(visit.address, search: false) != nil else { return }
            store.newTab(address: visit.address, title: visit.title, select: body["background"] as? Bool != true)
        default: break
        }
    }
}
