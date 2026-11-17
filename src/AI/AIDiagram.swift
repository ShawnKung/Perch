import AppKit
import WebKit
import UniformTypeIdentifiers

final class AIDiagram: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    private static var viewers: [AIDiagram] = []
    let window: NSWindow
    let web: WKWebView
    let svg: String
    let source: String
    var loaded = false
    static let assets: (script: String, style: String, purify: String) =
        (AIMarkdownView.asset("diagram.js") ?? "", AIMarkdownView.asset("diagram.css") ?? "", AIMarkdownView.asset("purify.js") ?? "")
    static func open(svg: String, source: String, from parent: NSWindow?) -> AIDiagram {
        let level = parent?.level ?? .normal
        let viewer = AIDiagram(svg: svg, source: source)
        viewers.append(viewer)
        viewer.window.level = level
        viewer.window.center()
        viewer.window.makeKeyAndOrderFront(nil)
        viewer.window.makeFirstResponder(viewer.web)
        NSApp.activate(ignoringOtherApps: true)
        return viewer
    }
    private init(svg: String, source: String) {
        self.svg = svg; self.source = source
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Mermaid 图表"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = web; window.delegate = self
        web.navigationDelegate = self
        config.userContentController.add(self, name: "markdown")
        PerchTheme.shared.register(web)
        web.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;">
        <style>html,body{margin:0;height:100%;overflow:hidden;color:#28352e;font:13px -apple-system; color-scheme:light}*{box-sizing:border-box}\(Self.assets.style)</style>
        </head><body><script>\(Self.assets.purify)</script><script>\(Self.assets.script)</script></body></html>
        """, baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PerchTheme.shared.update(webView)
        Task { @MainActor in
            do {
                _ = try await webView.callAsyncJavaScript("document.body.append(makeDiagram(svg, source, true));",
                    arguments: ["svg": svg, "source": source], in: nil, contentWorld: .page)
                loaded = true
            } catch { Self.report(error, window: window) }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let copy = body["copy"] as? String {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copy, forType: .string)
        }
        Self.showContextMenu(body, web: web)
        if body["fullscreen"] as? Bool == true { window.toggleFullScreen(nil) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
    }
    static func pngData(_ value: String) -> Data? {
        let prefix = "data:image/png;base64,"
        guard value.hasPrefix(prefix), value.utf8.count < 100_000_000,
              let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        return data
    }
    static func save(_ png: String, window: NSWindow?) {
        guard let data = pngData(png) else {
            report(PerchError("图表图片生成失败，请重试。"), window: window); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Mermaid.png"
        let finish: (NSApplication.ModalResponse) -> Void = { result in
            panel.orderOut(nil)
            guard result == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { report(error, window: window) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
    private final class SaveImageAction: NSObject {
        let svg: String
        weak var web: WKWebView?
        init(svg: String, web: WKWebView) { self.svg = svg; self.web = web }
        @objc func saveImage(_ sender: Any?) {
            guard let web else { return }
            Task { @MainActor in
                do {
                    let png = try await web.callAsyncJavaScript("return await diagramPNG(svg);",
                        arguments: ["svg": svg], in: nil, contentWorld: .page) as? String
                    guard let png else { throw PerchError("图表图片生成失败，请重试。") }
                    AIDiagram.save(png, window: web.window)
                } catch { AIDiagram.report(error, window: web.window) }
            }
        }
    }
    static func imageMenu(svg: String, web: WKWebView) -> NSMenu {
        let menu = NSMenu()
        let action = SaveImageAction(svg: svg, web: web)
        let item = menu.addItem(withTitle: "保存为图片…", action: #selector(SaveImageAction.saveImage(_:)), keyEquivalent: "")
        item.target = action; item.representedObject = action
        return menu
    }
    static func showContextMenu(_ body: [String: Any], web: WKWebView) {
        guard let svg = body["diagramMenu"] as? String, let x = body["x"] as? Double,
              let y = body["y"] as? Double, x.isFinite, y.isFinite else { return }
        let point = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
        imageMenu(svg: svg, web: web).popUp(positioning: nil, at: point, in: web)
    }
    private static func report(_ error: Error, window: NSWindow?) {
        let alert = NSAlert(); alert.messageText = "无法保存或显示图表"
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
    func windowWillClose(_ notification: Notification) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "markdown")
        web.navigationDelegate = nil; web.stopLoading()
        Self.viewers.removeAll { $0 === self }
    }
}
