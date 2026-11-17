import SwiftUI
import WebKit

struct AIFilePreview: NSViewRepresentable {
    let content: String
    static func supports(_ name: String) -> Bool {
        ["html", "htm", "svg"].contains((name as NSString).pathExtension.lowercased())
    }
    static func document(_ content: String) -> String {
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; form-action 'none'; base-uri 'none';"
        let child = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + content
        let escaped = child.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src about:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none';">
        <style>html,body,iframe{margin:0;width:100%;height:100%;border:0;background:white}body{overflow:hidden}</style>
        </head><body><iframe title="文件预览" sandbox="allow-scripts" referrerpolicy="no-referrer" srcdoc="\(escaped)"></iframe></body></html>
        """
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.content != content else { return }
        context.coordinator.content = content
        web.loadHTMLString(Self.document(content), baseURL: nil)
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading(); web.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var content: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url?.absoluteString ?? ""
            decisionHandler(action.navigationType == .other && ["about:blank", "about:srcdoc"].contains(url) ? .allow : .cancel)
        }
    }
}
