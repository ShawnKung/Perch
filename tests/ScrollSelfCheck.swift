import AppKit
import WebKit
import SwiftUI

@MainActor
enum ScrollSelfCheck {
    static func run() async throws {
        try await hiddenChatScroll()
        let suite = "dev.perch.scroll-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = Browser(url: URL(string: "about:blank")!, dataStore: .nonPersistent(),
                              previewDefaults: defaults)
        let page = browser.webView
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(page)
        defer { window.close() }
        let html = """
        <!doctype html><style>
        html,body{margin:0;height:100%;overflow:hidden}
        #outer{height:100%;overflow:auto}
        #content{height:3000px;padding-top:220px}
        .box{position:relative;width:300px;height:160px;margin-left:320px;overflow:auto;overscroll-behavior:contain}
        .tall{height:800px} #short,#wide{height:100px;overflow-x:auto;overflow-y:hidden}
        #wide>div{width:1000px;height:80px}
        </style>
        <div id="outer"><div id="content">
        <div class="box" id="card"><div class="tall">Long card</div></div>
        <div class="box" id="short">Short table</div>
        <div class="box" id="wide"><div>Wide table</div></div>
        <div class="box" id="other"><div class="tall">Other card</div></div>
        </div></div>
        <script>window.wheels=[];document.addEventListener('wheel',e=>{
          const record={trusted:e.isTrusted,x:e.clientX,y:e.clientY,target:e.target.id,
                        dy:e.deltaY,dx:e.deltaX,cancelable:e.cancelable,ctrl:e.ctrlKey,
                        hit:document.elementFromPoint(e.clientX,e.clientY)?.id};wheels.push(record);
          setTimeout(()=>record.prevented=e.defaultPrevented,0);
        },{capture:true,passive:true});</script>
        """
        func load() async throws {
            page.loadHTMLString(html, baseURL: URL(string: "https://scroll-fixture.invalid"))
            try await AISelfCheck.wait { !page.isLoading }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        func js(_ source: String) async throws -> Any? {
            try await page.evaluateJavaScript(source)
        }
        func position(_ id: String) async throws -> NSPoint {
            let coordinates = try await js("""
                (()=>{const r=document.getElementById('\(id)').getBoundingClientRect();
                return [r.x+r.width/2,r.y+Math.min(r.height/2,40)]})()
                """) as! [Double]
            return NSPoint(x: coordinates[0], y: coordinates[1])
        }
        func wheel(_ point: NSPoint, dy: Int32 = -100, dx: Int32 = 0,
                   phase: Int64 = 0, momentum: Int64 = 0, flags: CGEventFlags = []) async throws {
            // Dispatch only to this isolated web view; never post events or move the system pointer.
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: dy, wheel2: dx, wheel3: 0)!
            event.flags = flags
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            let local = page.convert(point, to: nil)
            event.location = CGPoint(x: local.x, y: NSScreen.screens[0].frame.height - local.y)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                       value: Int64(window.windowNumber))
            page.scrollWheel(with: NSEvent(cgEvent: event)!)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        func expect(_ condition: String, _ message: String) async throws {
            guard try await js(condition) as? Bool == true else {
                let state = try await js("JSON.stringify({outer:outer.scrollTop,card:card.scrollTop,other:other.scrollTop,wide:wide.scrollLeft,wheels})")
                throw PerchError("\(message): \(state as? String ?? "unavailable")")
            }
        }
        let outside = NSPoint(x: 100, y: 100)
        try await load()
        _ = try await js("outer.scrollTop=100;wheels=[]")
        try await wheel(try await position("card"), phase: 1)
        try await expect("card.scrollTop>0 && outer.scrollTop===100", "Card must scroll independently")
        _ = try await js("window.cardBefore=card.scrollTop")
        try await wheel(outside, dy: 100, phase: 2)
        try await expect("outer.scrollTop<100 && card.scrollTop===cardBefore",
                         "Moving from card to page must release the initial wheel target")
        try await wheel(outside, dy: 0, phase: 4)
        print("PASS: trusted continuous wheel gesture changes from nested card to outer page")

        _ = try await js("outer.scrollTop=100;card.scrollTop=0;wheels=[]")
        try await wheel(outside, phase: 1)
        _ = try await js("window.outerBefore=outer.scrollTop")
        try await wheel(try await position("card"), phase: 2)
        try await expect("card.scrollTop>0 && outer.scrollTop===outerBefore",
                         "Moving from page to card must scroll the pointed card")
        try await wheel(outside, dy: 0, phase: 8)
        print("PASS: page-to-card routing and cancelled gesture")

        _ = try await js("outer.scrollTop=100;card.scrollTop=card.scrollHeight;wheels=[]")
        try await wheel(try await position("card"), phase: 1)
        try await wheel(try await position("card"), phase: 2)
        try await expect("outer.scrollTop===100 && !wheels.some(e=>e.prevented)",
                         "Staying at a real inner edge must retain native containment")
        try await wheel(outside, dy: 0, phase: 4)

        for id in ["short", "wide"] {
            _ = try await js("outer.scrollTop=0;outer.scrollTop=document.getElementById('\(id)').getBoundingClientRect().top-250;window.outerBefore=outer.scrollTop;wheels=[]")
            try await wheel(try await position(id))
            try await expect("outer.scrollTop>outerBefore", "\(id) must not trap vertical wheels")
            _ = try await js("outer.scrollTop=outerBefore;wheels=[]")
            let tablePoint = try await position(id)
            try await wheel(tablePoint, phase: 1)
            try await wheel(tablePoint, phase: 2)
            try await expect("outer.scrollTop>=outerBefore+190",
                             "\(id) must keep passing repeated vertical wheels to the page")
            try await wheel(tablePoint, dy: 0, phase: 4)
            _ = try await js("card.scrollTop=0;outer.scrollTop=100;wheels=[]")
            try await wheel(try await position("card"), phase: 1)
            _ = try await js("outer.scrollTop=0;outer.scrollTop=document.getElementById('\(id)').getBoundingClientRect().top-250;window.outerBefore=outer.scrollTop;window.cardBefore=card.scrollTop")
            try await wheel(try await position(id), phase: 2)
            try await expect("outer.scrollTop>outerBefore && card.scrollTop===cardBefore",
                             "\(id) must release a previous nested gesture vertically")
            try await wheel(outside, dy: 0, phase: 4)
        }
        print("PASS: inner edge containment, short tables and horizontal-only tables with ordinary and continuous wheels")

        _ = try await js("outer.scrollTop=0;outer.scrollTop=wide.getBoundingClientRect().top-250;wide.scrollLeft=0;window.outerBefore=outer.scrollTop;wheels=[]")
        try await wheel(try await position("wide"), dy: 0, dx: -120)
        try await expect("wide.scrollLeft>0 && outer.scrollTop===outerBefore && !wheels.at(-1).prevented",
                         "Horizontal table scrolling must remain native")
        _ = try await js("outer.scrollTop=100;card.scrollTop=0;other.scrollTop=0;wheels=[]")
        try await wheel(try await position("card"), phase: 1)
        _ = try await js("outer.scrollTop=0;outer.scrollTop=other.getBoundingClientRect().top-250;window.outerBefore=outer.scrollTop;window.cardBefore=card.scrollTop")
        try await wheel(try await position("other"), phase: 2)
        try await expect("other.scrollTop>0 && card.scrollTop===cardBefore && outer.scrollTop===outerBefore",
                         "Switching cards must scroll only the pointed card")
        try await wheel(outside, dy: 0, phase: 4)
        print("PASS: horizontal wheels and switching between separate scrollable cards")

        _ = try await js("outer.scrollTop=100;card.scrollTop=0;wheels=[]")
        try await wheel(try await position("card"), phase: 1)
        try await wheel(try await position("card"), dy: 0, phase: 4)
        try await wheel(try await position("card"), momentum: 1)
        _ = try await js("window.cardBefore=card.scrollTop")
        try await wheel(outside, dy: 100, momentum: 2)
        try await expect("outer.scrollTop<100 && card.scrollTop===cardBefore",
                         "Momentum must follow a pointer moved out of the original card")
        try await wheel(outside, dy: 0, momentum: 3)
        print("PASS: momentum scrolling changes to the pointed container")

        _ = try await js("outer.scrollTop=100;card.scrollTop=0;wheels=[]")
        try await wheel(try await position("card"), phase: 1)
        try await wheel(try await position("card"), dy: 0, phase: 4)
        _ = try await js("window.cardBefore=card.scrollTop")
        try await wheel(outside, dy: 100, momentum: 1)
        try await expect("outer.scrollTop<100 && card.scrollTop===cardBefore",
                         "First momentum event must follow the current pointer")
        try await wheel(outside, dy: 0, momentum: 3)
        print("PASS: pointer moves between finger-up and the first momentum event")

        try await load()
        _ = try await js("outer.scrollTop=100;card.scrollTop=0;wheels=[]")
        try await wheel(try await position("card"), phase: 1)
        try await wheel(outside, dy: 100, phase: 2, flags: .maskControl)
        try await expect("wheels.at(-1).ctrl && !wheels.at(-1).prevented", "Control-wheel zoom must not be rerouted")
        try await wheel(outside, dy: 0, phase: 4)
        _ = try await js("outer.scrollTop=100;card.scrollTop=0;wheels=[]")
        try await wheel(try await position("card"), phase: 1)
        _ = try await js("window.cardBefore=card.scrollTop")
        try await wheel(outside, dy: 100, phase: 2)
        try await expect("outer.scrollTop<100 && card.scrollTop===cardBefore",
                         "Document navigation must install routing again")
        try await wheel(outside, dy: 0, phase: 4)
        try await expect("wheels.every(e=>e.trusted)", "Regression must use native trusted wheel events")
        print("PASS: zoom modifier bypass, document reload and trusted native events")
    }

    static func hiddenChatScroll() async throws {
        let suite = "dev.perch.hidden-chat-scroll-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        guard store.ai.save(AIConfiguration(provider: .custom, baseURL: "https://scroll-fixture.invalid",
                                            model: "fixture"), key: "synthetic-key") else {
            throw PerchError("Could not configure the isolated Chat fixture")
        }
        store.ai.seedPreview(answer: (0..<50).map {
            "Paragraph \($0): retained Chat text for testing mouse wheel ownership."
        }.joined(separator: "\n\n"))
        store.openChat(owner: AIController.homeID)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1100, height: 750),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func renderers(_ view: NSView) -> [AIChatWebView] {
            (view as? AIChatWebView).map { [$0] } ?? view.subviews.flatMap(renderers)
        }
        func textPoints(_ renderer: AIChatWebView) -> [NSPoint] {
            let viewport = renderer.bounds.intersection(renderer.visibleRect)
            guard viewport.height > 40 else { return [] }
            return [0.1, 0.5, 0.9].compactMap { fraction in
                let point = NSPoint(x: viewport.midX, y: viewport.minY + viewport.height * fraction)
                return point
            }
        }
        try await AISelfCheck.wait { renderers(host).contains {
            !$0.isLoading && $0.bounds.intersection($0.visibleRect).height > 100
        } }
        let retained = renderers(host).filter { $0.visibleRect.height > 40 }
        func tabController(_ controller: NSViewController) -> TabContentsController? {
            if let tabs = controller as? TabContentsController { return tabs }
            return controller.children.compactMap(tabController).first
        }
        // The representable embeds its controller in SwiftUI's hosting hierarchy.
        func contentController(_ view: NSView) -> TabContentsController? {
            var responder: NSResponder? = view
            while let current = responder {
                if let controller = current as? NSViewController,
                   let tabs = tabController(controller) { return tabs }
                responder = current.nextResponder
            }
            return view.subviews.compactMap(contentController).first
        }
        guard let tabs = contentController(host),
              let chatController = tabs.tabViewItems.first(where: {
                  ($0.identifier as? UUID) == store.selected
              })?.viewController, !retained.isEmpty else {
            throw PerchError("Chat must have its own native tab content controller")
        }
        store.newTab(address: "https://scroll-fixture.invalid")
        let page = store.browser!.webView
        page.loadHTMLString("<!doctype html><style>body{height:6000px}</style><p>Visible webpage</p>",
                            baseURL: URL(string: "https://scroll-fixture.invalid"))
        try await AISelfCheck.wait { !page.isLoading && page.window === window }
        try await Task.sleep(nanoseconds: 250_000_000)
        guard chatController.view.window == nil, retained.allSatisfy({ $0.window == nil }),
              renderers(host).isEmpty,
              tabs.tabViewItems.contains(where: { $0.viewController === chatController }) else {
            throw PerchError("Inactive Chat must retain its controller outside the window and event chain")
        }
        let pagePoint = page.convert(NSPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil)
        let hit = host.hitTest(host.superview?.convert(pagePoint, from: nil) ?? pagePoint)
        guard hit === page || hit?.isDescendant(of: page) == true else {
            throw PerchError("The selected webpage must receive events directly")
        }
        store.activate(store.tabs.first(where: \.isChat)!.id)
        func visibleTextPoint() -> (AIChatWebView, NSPoint)? {
            for renderer in renderers(host) {
                for point in textPoints(renderer) {
                    let windowPoint = renderer.convert(point, to: nil)
                    let hit = host.hitTest(host.superview?.convert(windowPoint, from: nil) ?? windowPoint)
                    if hit === renderer || hit?.isDescendant(of: renderer) == true {
                        return (renderer, point)
                    }
                }
            }
            return nil
        }
        try await AISelfCheck.wait {
            host.layoutSubtreeIfNeeded()
            return visibleTextPoint() != nil
        }
        let (renderer, _) = visibleTextPoint()!
        guard chatController.view.window === window, retained.contains(where: { $0 === renderer }),
              page.window == nil else {
            throw PerchError("Tab switching must restore the same Chat controller and renderer")
        }
        let point = try await renderer.evaluateJavaScript("""
            (()=>{const r=document.getElementById('scroll').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()
            """) as! [Double]
        let local = renderer.convert(NSPoint(x: point[0], y: renderer.isFlipped ? point[1] : renderer.bounds.height-point[1]), to: nil)
        let before = try await renderer.evaluateJavaScript("document.getElementById('scroll').scrollTop") as! Double
        try await AIChatPageSelfCheck.wheel(120, at: local, web: renderer, window: window)
        try await AIChatPageSelfCheck.check(renderer, "document.getElementById('scroll').scrollTop<before-60",
                                           "可见 Chat 必须恢复滚轮响应", arguments: ["before": before])
        print("PASS: peer native Chat controller leaves the window when inactive, retains its renderer and resumes scrolling when selected")
    }
}
