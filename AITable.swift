import AppKit
import SwiftUI
import WebKit

final class AITable: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private static var viewers: [AITable] = []
    let window: NSWindow
    let web: WKWebView
    let rows: [[String]]
    let bridge = AIMarkdownView.Coordinator(height: .constant(0))
    var loaded = false
    static func open(rows: [[String]], from parent: NSWindow?) -> AITable? {
        guard !rows.isEmpty, rows.count <= 10000, rows.allSatisfy({ $0.count <= 100 }),
              rows.flatMap({ $0 }).reduce(0, { $0 + $1.utf8.count }) <= 512 * 1024 else { return nil }
        let viewer = AITable(rows: rows)
        viewers.append(viewer)
        viewer.window.level = parent?.level ?? .normal
        viewer.window.center(); viewer.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return viewer
    }
    private init(rows: [[String]]) {
        self.rows = rows
        web = AIMarkdownView.webView(handler: bridge, embedded: false)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "表格"; window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = web; window.delegate = self; web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PerchTheme.shared.update(webView)
        Task { @MainActor in
            do {
                _ = try await web.callAsyncJavaScript("renderTable(rows);", arguments: ["rows": rows], in: nil, contentWorld: .page)
                loaded = true
            } catch { window.title = "表格显示失败" }
        }
    }
    func windowWillClose(_ notification: Notification) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "markdown")
        web.navigationDelegate = nil; web.stopLoading()
        Self.viewers.removeAll { $0 === self }
    }
}
