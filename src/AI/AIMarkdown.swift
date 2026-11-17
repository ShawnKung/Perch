import SwiftUI
import WebKit

extension Notification.Name {
    static let aiChatUserScroll = Notification.Name("PerchChatUserScroll")
}

private struct AICitationPreviewContent: View {
    @ObservedObject private var theme = PerchTheme.shared
    let source: AISearchSource
    let hover: (Bool) -> Void
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.title).font(.system(size: theme.chatDetailFontSize, weight: .semibold)).lineLimit(3)
            Text(source.url.host ?? "").font(.system(size: theme.chatFontSize(relativeTo: 10))).foregroundStyle(Style.muted)
            Text(source.excerpt ?? "来源未提供摘要").font(.system(size: theme.chatDetailFontSize)).lineLimit(8).textSelection(.enabled)
            Button(action: open) {
                Label("打开原链接", systemImage: "arrow.up.right.square").font(.system(size: theme.chatFontSize(relativeTo: 11)))
            }.buttonStyle(.plain).foregroundStyle(Style.accent).arrowCursor()
        }.foregroundStyle(Style.ink).padding(12).frame(width: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true).background(Style.paper)
            .onHover(perform: hover)
    }
}

final class AICitationPreview: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var showTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var sourceURL: URL?
    private var overLink = false
    private var overPopover = false
    override init() {
        super.init()
        popover.behavior = .semitransient; popover.delegate = self
    }
    func enter(source: AISearchSource, rect: NSRect, web: WKWebView) {
        guard ["http", "https"].contains(source.url.scheme?.lowercased() ?? ""),
              source.url.user == nil, source.url.password == nil else { close(); return }
        closeTask?.cancel()
        if sourceURL == source.url && popover.isShown { overLink = true; return }
        close()
        sourceURL = source.url; overLink = true
        showTask = Task { @MainActor [weak self, weak web] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, let web, web.window != nil,
                  self.sourceURL == source.url, self.overLink,
                  web.bounds.intersection(web.visibleRect).intersects(rect) else { return }
            let content = AICitationPreviewContent(source: source, hover: { [weak self] in self?.hover($0) },
                open: { [weak self] in self?.openOriginal() })
            let host = NSHostingController(rootView: content)
            self.popover.contentViewController = host
            self.popover.contentSize = host.view.fittingSize
            self.popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.popover.show(relativeTo: rect, of: web, preferredEdge: .maxY)
        }
    }
    func leave(url: URL) {
        guard sourceURL == url else { return }
        overLink = false; showTask?.cancel()
        scheduleClose()
    }
    func hover(_ value: Bool) {
        overPopover = value
        if value { closeTask?.cancel() } else { scheduleClose() }
    }
    func openOriginal() {
        guard let sourceURL, popover.isShown else { return }
        openURL(sourceURL); close()
    }
    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self, !self.overLink, !self.overPopover else { return }
            self.close()
        }
    }
    func close() {
        showTask?.cancel(); showTask = nil
        closeTask?.cancel(); closeTask = nil
        sourceURL = nil; overLink = false; overPopover = false
        popover.close()
    }
    func popoverWillClose(_ notification: Notification) {
        showTask?.cancel(); closeTask?.cancel()
        sourceURL = nil; overLink = false; overPopover = false
    }
    deinit { showTask?.cancel(); closeTask?.cancel(); popover.close() }
}

final class AIMarkdownWebView: WKWebView {
    var mermaidLoaded = false
    var diagramRects: [NSRect] = []
    private var scrollMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let screenPoint = NSEvent.mouseLocation
            guard NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber else { return event }
            let point = window.convertPoint(fromScreen: screenPoint)
            guard self.forwardVerticalScroll(event, at: self.convert(point, from: nil)) else { return event }
            return nil
        }
    }
    override func scrollWheel(with event: NSEvent) {
        let viewport = bounds.intersection(visibleRect)
        let point = event.window === window && event.window != nil
            ? convert(event.locationInWindow, from: nil) : NSPoint(x: viewport.midX, y: viewport.midY)
        if !forwardVerticalScroll(event, at: point) {
            super.scrollWheel(with: event)
        }
    }
    deinit { if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) } }
    @discardableResult
    func forwardVerticalScroll(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, bounds.intersection(visibleRect).contains(point),
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return false }
        // Local monitors must respect the window's hit testing, including overlays.
        if let window, let content = window.contentView {
            let windowPoint = convert(point, to: nil)
            let parentPoint = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
            guard let hit = content.hitTest(parentPoint),
                  hit === self || hit.isDescendant(of: self) else { return false }
        }
        let pagePoint = NSPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
        guard !diagramRects.contains(where: { $0.contains(pagePoint) }) else { return false }
        var parent = superview
        while let view = parent {
            if let scroll = view as? NSScrollView {
                NotificationCenter.default.post(name: .aiChatUserScroll, object: scroll)
                if event.momentumPhase.isEmpty { scroll.scrollWheel(with: event) }
                else { scroll.scrollAIWheelContents(with: event) }
                return true
            }
            parent = view.superview
        }
        return false
    }
}

struct AIMarkdownView: View {
    let text: String
    var sources: [AISearchSource] = []
    @State private var height: CGFloat = 40
    static func asset(_ name: String) -> String? {
        let filename = name == "mermaid.js" ? "mermaid.lzma" : name + ".lzma"
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("markdown/" + filename),
              let packed = NSData(contentsOf: url), let data = try? packed.decompressed(using: .lzma) else { return nil }
        return String(data: data as Data, encoding: .utf8)
    }
    private static let scripts: (String, String)? = {
        guard let marked = asset("marked.js"), let purify = asset("purify.js") else { return nil }
        return (marked, purify)
    }()
    private static let mermaidSource = asset("mermaid.js") ?? ""
    private static let tableSource = asset("tables.js") ?? ""
    static func render(_ text: String, web: WKWebView, sources: [AISearchSource] = []) {
        Task { @MainActor in
            PerchTheme.shared.update(web)
            let needsMermaid = text.contains("mermaid") && (web as? AIMarkdownWebView)?.mermaidLoaded != true
            do {
                _ = try await web.callAsyncJavaScript("""
                if (source && !window.mermaid) {
                  const script = document.createElement('script'); script.textContent = source; document.head.append(script);
                }
                if (window.mermaid) {
                  window.perchDiagramColors = colors;
                  mermaid.initialize({startOnLoad:false,securityLevel:'strict',maxTextSize:32000,
                    theme:'base',themeVariables:{primaryColor:colors.mint,secondaryColor:colors.sidebar,
                      tertiaryColor:colors.mint,primaryTextColor:'#28352e',primaryBorderColor:colors.line,
                      lineColor:colors.accent,actorBkg:colors.mint,actorBorder:colors.line,
                      fontFamily:'-apple-system,sans-serif',fontSize:'13px'},flowchart:{htmlLabels:false}});
                }
                window.citationSources = sources;
                return await renderMarkdown(text);
                """, arguments: ["text": text, "source": needsMermaid ? mermaidSource : "",
                    "colors": PerchTheme.shared.selection.webColors,
                    "sources": sources.map { ["title": $0.title, "url": $0.url.absoluteString, "excerpt": $0.excerpt ?? ""] }], in: nil, contentWorld: .page)
                if needsMermaid { (web as? AIMarkdownWebView)?.mermaidLoaded = true }
            } catch {}
        }
    }
    static func webView(handler: WKScriptMessageHandler, embedded: Bool = true) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(handler, name: "markdown")
        let web = embedded ? AIMarkdownWebView(frame: .zero, configuration: config) : WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        PerchTheme.shared.register(web)
        guard let (marked, purify) = scripts else {
            web.loadHTMLString("<p>Markdown 组件缺失，请重新安装应用。</p>", baseURL: nil)
            return web
        }
        web.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;">
        <style>
        :root {color-scheme:light;--perch-accent:#216452;--perch-mint:#e0f0e6;--perch-sidebar:#f0f5ed;--perch-line:#dbe3db} *{box-sizing:border-box}
        html,body{margin:0;padding:0;background:transparent;color:#28352e;font:var(--perch-chat-font-size,13px)/1.65 -apple-system,BlinkMacSystemFont,sans-serif;overflow:hidden}
        #content{overflow-wrap:anywhere;padding-bottom:2px} #content>:first-child{margin-top:0} #content>:last-child{margin-bottom:0}
        h1,h2,h3{font-size:1.3em;line-height:1.4;margin:14px 0 8px} p,ul,ol{margin:8px 0}
        ul,ol{padding-left:22px} a{color:var(--perch-accent)} blockquote{margin:10px 0;padding:2px 12px;border-left:3px solid var(--perch-line);color:#68776d;background:var(--perch-sidebar)}
        code{font:calc(var(--perch-chat-font-size,13px) * 12 / 13)/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--perch-mint);border-radius:4px;padding:2px 4px;box-decoration-break:clone;-webkit-box-decoration-break:clone}
        pre{position:relative;overflow-x:auto;background:var(--perch-mint);padding:calc(34px + (var(--perch-chat-font-size,13px) - 13px) * 1.2) 12px 12px;border-radius:8px;margin:10px 0}
        .code-tools{position:absolute;right:8px;top:6px;display:flex;flex-direction:row-reverse;gap:6px}
        pre code{padding:0;white-space:pre;overflow-wrap:normal} pre button{border:1px solid var(--perch-line);border-radius:5px;background:white;color:var(--perch-accent);padding:2px 8px;font:calc(var(--perch-chat-font-size,13px) * 11 / 13) -apple-system;white-space:nowrap;cursor:pointer}
        .table-wrap{overflow-x:auto} table{border-collapse:collapse;font-size:calc(var(--perch-chat-font-size,13px) * 12 / 13);min-width:100%;margin:8px 0}
        .table-tools{display:flex;flex-wrap:wrap;gap:6px;padding-top:5px} .table-tools button,th button{font:calc(var(--perch-chat-font-size,13px) * 11 / 13) -apple-system;color:var(--perch-accent);border:1px solid var(--perch-line);border-radius:5px;background:white;padding:3px 7px;cursor:pointer}
        th button{border:0;background:none;text-align:left;padding:0;width:100%;font:inherit;font-weight:600}
        th[aria-sort=ascending]::after{content:' ↑'} th[aria-sort=descending]::after{content:' ↓'}
        .source-citation{font-size:calc(var(--perch-chat-font-size,13px) * 11 / 13);color:#68776d;text-decoration:underline dashed;text-underline-offset:3px}
        th,td{border:1px solid var(--perch-line);padding:6px 8px;text-align:left} th{background:var(--perch-mint)} hr{border:0;border-top:1px solid var(--perch-line)}
        input[type=checkbox]{accent-color:var(--perch-accent)} img{max-width:100%}
        \(AIDiagram.assets.style)
        </style></head><body><div id="content"></div>
        <script>\(marked)</script><script>\(purify)</script><script>\(AIDiagram.assets.script)</script>
        <script>\(tableSource)</script><script>
        let renderRevision = 0, diagramID = 0;
        window.renderMarkdown = async text => {
          const revision = ++renderRevision;
          const root = document.getElementById('content');
          window.webkit.messageHandlers.markdown.postMessage({citation:{action:'clear'}});
          root.innerHTML = DOMPurify.sanitize(marked.parse(text, {gfm:true, breaks:true}), {USE_PROFILES:{html:true}, FORBID_TAGS:['style','form','iframe','img'], FORBID_ATTR:['style']});
          window.updateDiagramBounds?.();
          root.querySelectorAll('pre').forEach(pre => {
            const code = pre.querySelector('code'), button = document.createElement('button');
            const tools = document.createElement('div'); tools.className = 'code-tools';
            button.textContent = '复制代码';
            button.onclick = () => { window.webkit.messageHandlers.markdown.postMessage({copy:code?.textContent || ''}); button.textContent='已复制'; };
            tools.append(button); pre.prepend(tools);
            if (code && !code.classList.contains('language-mermaid')) {
              const save = document.createElement('button');
              save.textContent = '另存为';
              save.onclick = () => window.webkit.messageHandlers.markdown.postMessage({saveCode:code.textContent, language:Array.from(code.classList).find(x=>x.startsWith('language-'))?.slice(9) || ''});
              tools.append(save);
            }
          });
          root.querySelectorAll('table').forEach(enhanceTable);
          root.querySelectorAll('a').forEach(link => {if (!/^https?:/i.test(link.href)) link.removeAttribute('href')});
          enhanceCitations(root, window.citationSources || []);
          const diagrams = Array.from(root.querySelectorAll('pre code.language-mermaid'));
          if (diagrams.length) await new Promise(resolve => setTimeout(resolve, 180));
          for (const code of diagrams) {
            if (revision !== renderRevision || !code.isConnected) return;
            const id = 'perchDiagram' + (++diagramID);
            try {
              const result = await mermaid.render(id, code.textContent);
              if (revision !== renderRevision || !code.isConnected) return;
              const diagram = makeDiagram(result.svg, code.textContent);
              code.parentElement.replaceWith(diagram);
            } catch (_) {
              // Incomplete streamed diagrams remain readable and copyable as code.
            } finally { document.getElementById('d' + id)?.remove(); }
          }
        };
        window.updateDiagramBounds = () => window.webkit.messageHandlers.markdown.postMessage({
          diagramRects:Array.from(document.querySelectorAll('.diagram-image')).filter(image => !image.hidden)
            .map(image => {const r=image.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};})
        });
        new ResizeObserver(() => {
          window.webkit.messageHandlers.markdown.postMessage({height:document.getElementById('content').getBoundingClientRect().height});
          updateDiagramBounds();
        }).observe(document.getElementById('content'));
        </script></body></html>
        """, baseURL: nil)
        return web
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var text = ""
        var sources: [AISearchSource] = []
        var loaded = false
        weak var container: MarkdownContainer?
        weak var scroll: NSScrollView?
        var web: WKWebView?
        var observers: [NSObjectProtocol] = []
        var scheduled = false
        var unloadTask: Task<Void, Never>?
        let citationPreview = AICitationPreview()
        init(height: Binding<CGFloat>) { self.height = height }
        func scheduleVisibility() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.refreshVisibility()
            }
        }
        func refreshVisibility() {
            guard let container, container.window != nil, container.bounds.width > 0 else { return }
            if scroll == nil {
                var parent = container.superview
                while let view = parent {
                    if let value = view as? NSScrollView { scroll = value; break }
                    parent = view.superview
                }
                if let scroll {
                    scroll.contentView.postsBoundsChangedNotifications = true
                    observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                        object: scroll.contentView, queue: .main) { [weak self] _ in
                            self?.citationPreview.close(); self?.scheduleVisibility()
                        })
                    if let document = scroll.documentView {
                        document.postsFrameChangedNotifications = true
                        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                            object: document, queue: .main) { [weak self] _ in self?.scheduleVisibility() })
                    }
                }
            }
            // Keep measured height when unloading; only render near the viewport.
            let visible = nearViewport()
            if visible { unloadTask?.cancel(); unloadTask = nil }
            if visible && web == nil {
                let view = AIMarkdownView.webView(handler: self)
                web = view; loaded = false
                view.navigationDelegate = self
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
            } else if !visible, web != nil, unloadTask == nil {
                // Let bookmark corrections settle before discarding a rendered answer.
                unloadTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.unloadTask = nil
                    if !self.nearViewport() { self.unload() }
                }
            }
        }
        func nearViewport() -> Bool {
            guard let container, container.window != nil else { return false }
            guard let scroll, let document = scroll.documentView else { return true }
            return container.convert(container.bounds, to: document)
                .intersects(scroll.contentView.bounds.insetBy(dx: 0, dy: -600))
        }
        func unload() {
            citationPreview.close()
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "markdown")
            web?.navigationDelegate = nil
            web?.stopLoading()
            web?.removeFromSuperview()
            web = nil; loaded = false
        }
        func stop() {
            unloadTask?.cancel(); unloadTask = nil
            unload()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            scroll = nil
        }
        deinit {
            unloadTask?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let citation = body["citation"] as? [String: Any], message.frameInfo.isMainFrame {
                if citation["action"] as? String == "clear" { citationPreview.close() }
                else if let address = citation["url"] as? String,
                        let source = sources.first(where: { $0.url.absoluteString == address }) {
                    if citation["action"] as? String == "leave" { citationPreview.leave(url: source.url) }
                    else if citation["action"] as? String == "enter", let web = message.webView,
                            let x = citation["x"] as? Double, let y = citation["y"] as? Double,
                            let width = citation["width"] as? Double, let height = citation["height"] as? Double,
                            [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height > 0 {
                        let rect = NSRect(x: x, y: web.isFlipped ? y : web.bounds.height - y - height,
                                          width: width, height: height)
                        citationPreview.enter(source: source, rect: rect, web: web)
                    }
                }
            }
            if let rects = body["diagramRects"] as? [[String: Double]], let web = message.webView as? AIMarkdownWebView {
                web.diagramRects = rects.compactMap { rect in
                    guard let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"],
                          [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height > 0 else { return nil }
                    return NSRect(x: x, y: y, width: width, height: height)
                }
            }
            if let value = body["height"] as? Double, value.isFinite {
                let value = CGFloat(max(24, min(value, 100000)))
                if abs(height.wrappedValue - value) > 1 { height.wrappedValue = value }
            }
            if let copy = body["copy"] as? String {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copy, forType: .string)
            }
            if let rows = body["table"] as? [[String]] { _ = AITable.open(rows: rows, from: message.webView?.window) }
            if let csv = body["csv"] as? String, csv.utf8.count <= 1024 * 1024 {
                AIGeneratedFile(name: "table.csv", content: "\u{FEFF}" + csv).saveAs(window: message.webView?.window) { result in
                    if case .failure(let error) = result {
                        let alert = NSAlert(); alert.messageText = "导出失败"; alert.informativeText = error.localizedDescription; alert.runModal()
                    }
                }
            }
            if let code = body["saveCode"] as? String, code.utf8.count <= 256 * 1024 {
                let extensions = ["python": "py", "py": "py", "javascript": "js", "js": "js", "typescript": "ts",
                                  "bash": "sh", "shell": "sh", "sh": "sh", "zsh": "zsh", "html": "html", "css": "css",
                                  "json": "json", "yaml": "yaml", "yml": "yml", "markdown": "md", "md": "md",
                                  "csv": "csv", "sql": "sql", "swift": "swift", "go": "go", "rust": "rs"]
                let file = AIGeneratedFile(name: "code." + (extensions[body["language"] as? String ?? ""] ?? "txt"), content: code)
                file.saveAs(window: message.webView?.window) { result in
                    if case .failure(let error) = result {
                        let alert = NSAlert(); alert.messageText = "保存失败"; alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
            if let svg = body["diagram"] as? String, let source = body["source"] as? String {
                _ = AIDiagram.open(svg: svg, source: source, from: message.webView?.window)
            }
            if let web = message.webView { AIDiagram.showContextMenu(body, web: web) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            PerchTheme.shared.update(webView)
            loaded = true; AIMarkdownView.render(text, web: webView, sources: sources)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
    final class MarkdownContainer: NSView {
        var refresh: (() -> Void)?
        override var isFlipped: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh?() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); refresh?() }
        override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); refresh?() }
    }
    var body: some View { SizedMarkdown(text: text, sources: sources, height: $height).frame(height: height) }
    struct SizedMarkdown: NSViewRepresentable {
        let text: String
        var sources: [AISearchSource] = []
        @Binding var height: CGFloat
        func makeCoordinator() -> Coordinator { Coordinator(height: $height) }
        func makeNSView(context: Context) -> MarkdownContainer {
            let view = MarkdownContainer()
            context.coordinator.container = view
            context.coordinator.text = text
            context.coordinator.sources = sources
            view.refresh = { [weak coordinator = context.coordinator] in coordinator?.scheduleVisibility() }
            return view
        }
        func updateNSView(_ view: MarkdownContainer, context: Context) {
            if context.coordinator.text != text || context.coordinator.sources != sources {
                context.coordinator.text = text
                context.coordinator.sources = sources
                context.coordinator.citationPreview.close()
                if context.coordinator.loaded, let web = context.coordinator.web { AIMarkdownView.render(text, web: web, sources: sources) }
            }
            context.coordinator.scheduleVisibility()
        }
        static func dismantleNSView(_ view: MarkdownContainer, coordinator: Coordinator) {
            view.refresh = nil
            coordinator.stop()
        }
    }
}
