import AppKit
import WebKit

// Only bundled documents receive a bridge; arbitrary websites never own these actions.
enum InternalPage {
    static func matches(_ url: URL?, host: String) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "perch" && url.host?.lowercased() == host &&
            ["", "/"].contains(url.path) && url.query == nil && url.fragment == nil &&
            url.user == nil && url.password == nil && url.port == nil
    }
    private final class Handler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(userContentController, didReceive: message)
        }
    }
    // Bundled assets are immutable; decompress once instead of doing work for each new WebView.
    private static let assets: [String: String] = {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("internal"),
              let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var contents: [String: String] = [:]
        for url in urls where url.pathExtension == "lzma" {
            guard let packed = NSData(contentsOf: url), let data = try? packed.decompressed(using: .lzma),
                  let text = String(data: data as Data, encoding: .utf8) else { continue }
            contents[url.deletingPathExtension().lastPathComponent] = text
        }
        return contents
    }()
    static func document(_ name: String, style: String = "") -> Data {
        let html = assets["\(name).html"] ?? ""
        guard !html.isEmpty else { return Data("<p>页面组件缺失，请重新安装 Perch。</p>".utf8) }
        return Data(html.replacingOccurrences(of: "/* internal.css */", with: (assets["internal.css"] ?? "") + style).utf8)
    }
    static func install(_ name: String, handler: WKScriptMessageHandler, in configuration: WKWebViewConfiguration,
                        bridge: String = "perchInternal") {
        configuration.userContentController.add(Handler(handler), contentWorld: .defaultClient, name: bridge)
        configuration.userContentController.addUserScript(WKUserScript(source: assets["\(name).js"] ?? "",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    }
    static func accepts(_ message: WKScriptMessage, web: WKWebView?, matches: (URL?) -> Bool) -> Bool {
        guard let web, message.webView === web, message.frameInfo.isMainFrame,
              matches(message.frameInfo.request.url), matches(web.url) else { return false }
        return true
    }
    static func update(_ state: [String: Any], web: WKWebView) {
        web.callAsyncJavaScript("window.perchUpdate?.(state)", arguments: ["state": state],
                                in: nil, in: .defaultClient, completionHandler: nil)
    }
    static func icon(_ image: NSImage) -> String {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}

enum ChatPage {
    static let url = URL(string: "perch://chat")!
    static func matches(_ url: URL?) -> Bool { InternalPage.matches(url, host: "chat") }
}

final class InternalPageSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var settingsPage: SettingsPageBridge?

    init(settingsPage: SettingsPageBridge) { self.settingsPage = settingsPage }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let name: String
        if DownloadsPage.matches(task.request.url) { name = "downloads" }
        else if HistoryPage.matches(task.request.url) { name = "history" }
        else if SettingsRoute(task.request.url) != nil { name = "settings" }
        else if ChatPage.matches(task.request.url) { name = "chat" }
        else { task.didFailWithError(URLError(.unsupportedURL)); return }
        // Chat's shared renderer lives above this navigation document.
        // The outgoing Appearance page may still be previewing a different theme.
        let theme = name == "settings" ? (settingsPage?.store?.settings.theme ?? PerchTheme.shared.selection).webColors : [:]
        let style = theme.isEmpty ? "" : "\n:root{\(theme.map { "--perch-\($0.key):\($0.value)" }.joined(separator: ";"))}\n"
        let data = name == "chat" ? Data("<!doctype html><title>AI 聊天</title>".utf8) : InternalPage.document(name, style: style)
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html",
                                   expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
