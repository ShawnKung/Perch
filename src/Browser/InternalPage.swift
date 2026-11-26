import AppKit
import WebKit

// Only bundled documents receive a bridge; arbitrary websites never own these actions.
enum InternalPage {
    private final class Handler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(userContentController, didReceive: message)
        }
    }
    static func asset(_ name: String) -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("internal/\(name)"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
    static func document(_ name: String) -> Data {
        let html = asset("\(name).html")
        guard !html.isEmpty else { return Data("<p>页面组件缺失，请重新安装 Perch。</p>".utf8) }
        return Data(html.replacingOccurrences(of: "/* internal.css */", with: asset("internal.css")).utf8)
    }
    static func install(_ name: String, handler: WKScriptMessageHandler, in configuration: WKWebViewConfiguration) {
        configuration.userContentController.add(Handler(handler), contentWorld: .defaultClient, name: "perchInternal")
        configuration.userContentController.addUserScript(WKUserScript(source: asset("\(name).js"),
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
