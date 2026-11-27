import AppKit
import SwiftUI
import WebKit

@MainActor
enum AIChatPageSelfCheck {
    final class BridgeRecorder: NSObject, WKScriptMessageHandler {
        weak var target: AIChatPageController?
        var actions: [[String: Any]] = []
        init(_ web: AIChatWebView) {
            target = web.controller
            super.init()
            let content = web.configuration.userContentController
            content.removeScriptMessageHandler(forName: "perchInternal", contentWorld: .defaultClient)
            content.add(self, contentWorld: .defaultClient, name: "perchInternal")
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] {
                actions.append(body); if actions.count > 20 { actions.removeFirst() }
            }
            target?.userContentController(userContentController, didReceive: message)
        }
    }
    static func find(_ view: NSView) -> AIChatWebView? {
        if let web = view as? AIChatWebView, web.window != nil, !web.isHiddenOrHasHiddenAncestor { return web }
        return view.subviews.lazy.compactMap(find).first
    }
    static func ready(_ panel: Panel) async throws -> AIChatWebView {
        try await AISelfCheck.wait {
            panel.contentView?.layoutSubtreeIfNeeded()
            guard let web = panel.contentView.flatMap(find), web.controller?.ready == true,
                  web.bounds.width > 100, web.bounds.height > 100 else { return false }
            var ancestor = web.superview
            while let view = ancestor {
                if let container = view as? ChatContentContainer {
                    return container.tabID == container.store?.selected
                }
                ancestor = view.superview
            }
            return true
        }
        let web = find(panel.contentView!)!
        _ = try await web.callAsyncJavaScript("""
            for(let i=0;!document.querySelector('#composer');i++){
                if(i>100)throw new Error('Chat composer missing');
                await new Promise(resolve=>setTimeout(resolve,20));
            }
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        return web
    }
    static func check(_ web: WKWebView, _ expression: String, _ message: String,
                      arguments: [String: Any] = [:], line: UInt = #line) async throws {
        guard try await web.callAsyncJavaScript("return (" + expression + ");", arguments: arguments,
                                                in: nil, contentWorld: .defaultClient) as? Bool == true else {
            let focus = try? await web.evaluateJavaScript("""
                JSON.stringify({active:document.activeElement.id,focused:document.hasFocus(),
                    visible:document.activeElement.matches(':focus-visible')})
                """)
            throw PerchError("HTML Chat \(line): \(message); key=\(web.window?.isKeyWindow == true), focus=\(focus ?? "nil")")
        }
    }
    static func waitFor(_ web: WKWebView, _ expression: String, arguments: [String: Any] = [:],
                        timeout: TimeInterval = 8, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await web.callAsyncJavaScript("return (" + expression + ");", arguments: arguments,
                                                  in: nil, contentWorld: .defaultClient)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw PerchError("HTML Chat \(line): timed out waiting for \(expression)")
    }
    static func type(_ value: String, fixture: HomePageFixture, web: WKWebView) async throws {
        try await fixture.click("#composer", web: web)
        _ = try await web.evaluateJavaScript("document.getElementById('composer').select()")
        guard let input = fixture.panel.firstResponder as? NSTextInputClient else { throw PerchError("Chat input lost native focus") }
        input.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitFor(web, "document.getElementById('composer').value===value", arguments: ["value": value])
    }
    static func click(_ label: String, within selector: String, fixture: HomePageFixture, web: WKWebView) async throws {
        _ = try await web.callAsyncJavaScript("""
            document.querySelectorAll('[data-test-target]').forEach(e=>e.removeAttribute('data-test-target'));
            const button=[...document.querySelectorAll(selector+' button')].find(b=>b.textContent===label);
            if(!button)throw new Error('Missing button: '+label);
            button.dataset.testTarget='true';button.scrollIntoView({block:'center'});
            """, arguments: ["label": label, "selector": selector], in: nil, contentWorld: .defaultClient)
        try await fixture.click("[data-test-target]", web: web)
    }
    static func frame(_ label: String, web: WKWebView) async throws -> NSRect {
        let result = try await web.callAsyncJavaScript("""
            const element=[...document.querySelectorAll('[aria-label]')].find(e=>e.getAttribute('aria-label')===label && e.getClientRects().length);
            if(!element)throw new Error('Missing visible control: '+label);
            const r=element.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};
            """, arguments: ["label": label], in: nil, contentWorld: .defaultClient) as! [String: Double]
        let rect = NSRect(x: result["x"]!, y: web.isFlipped ? result["y"]! : web.bounds.height-result["y"]!-result["height"]!,
                          width: result["width"]!, height: result["height"]!)
        return web.window!.convertToScreen(web.convert(rect, to: nil))
    }
    static func wheel(_ delta: Int32, at point: NSPoint, web: WKWebView, window: NSWindow) async throws {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                            wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        // CG-created NSEvents have no NSWindow; WebKit expects window coordinates.
        event.location = CGPoint(x: point.x, y: NSScreen.screens[0].frame.height - point.y)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        web.scrollWheel(with: NSEvent(cgEvent: event)!)
        try await Task.sleep(nanoseconds: 60_000_000)
    }
    static func quoteFade(_ web: WKWebView, world: WKContentWorld? = nil) async throws {
        let valid = try await web.callAsyncJavaScript("""
            const button=document.getElementById('quote-selection'),selection=getSelection(),
                range=selection.getRangeAt(0).cloneRange(),reduced=matchMedia('(prefers-reduced-motion:reduce)').matches;
            await Promise.all(button.getAnimations().map(a=>a.finished));
            async function sample(showing){
                while(button.hidden===showing)await new Promise(requestAnimationFrame);
                await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
                const animations=button.getAnimations(),fade=animations.find(a=>a.effect.getKeyframes().some(f=>'opacity' in f));
                if(!reduced){
                    if(!fade)throw new Error('Quote opacity transition missing: '+JSON.stringify({
                        showing,hidden:button.hidden,display:getComputedStyle(button).display,
                        opacity:getComputedStyle(button).opacity,transition:getComputedStyle(button).transition,
                        animations:animations.map(a=>a.effect.getKeyframes())}));
                    fade.pause();fade.currentTime=Number(fade.effect.getComputedTiming().duration)/2;
                    const opacity=Number(getComputedStyle(button).opacity);
                    if(!(opacity>0 && opacity<1))throw new Error('Quote fade has no intermediate opacity');
                }
                if(!showing && getComputedStyle(button).pointerEvents!=='none')
                    throw new Error('Fading quote still accepts pointer events');
                animations.forEach(a=>a.finish());
                await Promise.all(animations.map(a=>a.finished));
                const style=getComputedStyle(button);
                if(style.opacity!==(showing?'1':'0') || style.visibility!==(showing?'visible':'hidden'))
                    throw new Error('Quote fade has incorrect terminal visibility');
            }
            selection.removeAllRanges();await sample(false);
            selection.addRange(range);await sample(true);
            const rect=button.getBoundingClientRect();
            return button.querySelector('svg[aria-hidden="true"]') && button.textContent==='引用到对话' &&
                selection.toString()===range.toString() &&
                [[rect.x+2,rect.y+rect.height/2],[rect.right-2,rect.y+rect.height/2],
                 [rect.x+rect.width/2,rect.y+2],[rect.x+rect.width/2,rect.bottom-2]]
                    .every(([x,y])=>document.elementFromPoint(x,y)===button);
            """, arguments: [:], in: nil, contentWorld: world ?? .defaultClient) as? Bool
        guard valid == true else { throw PerchError("Quote fade/icon lost selection or native button hit area") }
        print("PASS: quote fades through intermediate opacity, disables fading-out hits, retains selection and decorative quote icon")
    }
    static func toolbarCursor(fixture: HomePageFixture, web: WKWebView) async throws {
        // Only fixture-injected movements should participate in this asynchronous cursor check.
        let acceptsMouseMoved = fixture.panel.acceptsMouseMovedEvents
        fixture.panel.acceptsMouseMovedEvents = false
        defer { fixture.panel.acceptsMouseMovedEvents = acceptsMouseMoved }
        try await fixture.focus()
        defer { NSCursor.arrow.set() }
        var restorations = 0, restoredArrow = false
        var focusLosses = 0
        let focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: fixture.panel, queue: .main) { _ in focusLosses += 1 }
        defer { NotificationCenter.default.removeObserver(focusObserver) }
        let tracker = AIWebHoverTracker(web: web, world: .defaultClient) {
            NSCursor.arrow.set()
            restoredArrow = NSCursor.current == NSCursor.arrow
            restorations += 1
        }
        defer { withExtendedLifetime(tracker) {} }
        _ = try await web.callAsyncJavaScript("""
            if(!window.fixtureCursorHits){
                window.fixtureCursorHits=[];
                const hover=window.updateChatHover;
                window.updateChatHover=(x,y)=>{
                    const arrow=hover(x,y);
                    window.fixtureCursorHits.push({x,y,arrow});
                    if(window.fixtureCursorHits.length>12)window.fixtureCursorHits.shift();
                    return arrow;
                };
            }
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        let selectors = try await web.callAsyncJavaScript("""
            return [...document.querySelectorAll('#toolbar button,#toolbar select')]
                .filter(e=>e.getClientRects().length).map(e=>'#'+e.id);
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as! [String]
        for selector in selectors {
            let point = try await fixture.point(selector, web: web)
            for cursor in [NSCursor.pointingHand, NSCursor.iBeam] {
                var attempts = 0
                while true {
                    try await fixture.focus()
                    let focusRevision = focusLosses
                    cursor.set()
                    let before = restorations
                    fixture.mouse(.mouseMoved, at: point)
                    do {
                        try await AISelfCheck.wait { (restorations > before && restoredArrow) || focusLosses != focusRevision }
                        if focusLosses != focusRevision {
                            attempts += 1
                            guard attempts < 3 else { throw PerchError("Desktop focus repeatedly interrupted the cursor fixture") }
                            continue
                        }
                        break
                    } catch {
                        let diagnostic = try await web.callAsyncJavaScript("""
                            const r=document.querySelector(selector).getBoundingClientRect(),
                                target=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);
                            return {target:target?.tagName,id:target?.id,cursor:target && getComputedStyle(target).cursor,
                                events:window.fixtureCursorHits.slice(),
                                hover:window.updateChatHover?.(r.x+r.width/2,r.y+r.height/2)};
                            """, arguments: ["selector": selector], in: nil, contentWorld: .defaultClient)
                        let root = fixture.panel.contentView!
                        let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
                        throw PerchError("Toolbar did not restore arrow from \(cursor) over \(selector): hit=\(String(describing: hit)), key=\(fixture.panel.isKeyWindow), DOM=\(diagnostic ?? "nil"); \(error)")
                    }
                }
            }
        }
        // Hold a toolbar reply until a later native text event has been processed.
        _ = try await web.callAsyncJavaScript("""
            window.fixtureCursorHover=window.updateChatHover;
            window.fixtureCursorReplies=[];
            window.updateChatHover=(x,y)=>{
                const arrow=window.fixtureCursorHover(x,y);
                return arrow ? new Promise(resolve=>window.fixtureCursorReplies.push(resolve)) : false;
            };
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        fixture.mouse(.mouseMoved, at: try await fixture.point("#send", web: web))
        try await waitFor(web, "window.fixtureCursorReplies.length>=2")
        fixture.mouse(.mouseMoved, at: try await fixture.point("#composer", web: web))
        try await waitFor(web, "window.fixtureCursorHits.at(-1)?.arrow===false")
        let restorationsBeforeRelease = restorations
        _ = try await web.callAsyncJavaScript("""
            window.updateChatHover=window.fixtureCursorHover;
            window.fixtureCursorReplies.forEach(resolve=>resolve(true));delete window.fixtureCursorReplies;
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        _ = try await web.callAsyncJavaScript("return true;", arguments: [:], in: nil, contentWorld: .defaultClient)
        guard restorations == restorationsBeforeRelease else { throw PerchError("Toolbar hover restored a cursor after the later text event") }
        print("PASS: native toolbar mouse events restore arrow from hand/I-beam; later text events invalidate delayed restoration")
    }
    static func run(baseURL: String? = nil, styleOnly: Bool = false, quoteOnly: Bool = false) async throws {
        if let baseURL, URL(string: baseURL)?.host != "127.0.0.1" {
            throw PerchError("HTML Chat self-check requires a loopback fixture")
        }
        let suite = "dev.perch.chat-html.selftest.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let store = Store(defaults: defaults), owner = AIController.homeID
        let panel = Panel(contentRect: NSRect(x: 120, y: 100, width: 1000, height: 760),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        defer { panel.orderOut(nil); panel.contentView = nil; defaults.removePersistentDomain(forName: suite) }
        let config = AIConfiguration(provider: .custom, baseURL: (baseURL ?? "http://127.0.0.1:9") + "/v1", model: "fixture")
        precondition(store.ai.save(config, key: "synthetic-key"))
        let referenceURL = URL(string: "http://127.0.0.1:9/reference-fixture")!
        store.ai.seedPreview(answer: """
        ## HTML Chat 回归
        **中文句子。**后续中文

        | 名称 | 数值 |
        | --- | --- |
        | Beta | 2 |
        | Alpha | 1 |

        ```python
        print("fixture")
        ```

        [引用来源](https://fixture.invalid/source)

        <script>window.untrustedChatScript=true</script><button id="send">伪造发送</button>
        """, sources: [AISearchSource(title: "合成来源", url: URL(string: "https://fixture.invalid/source")!, excerpt: "合成摘要")] +
            (1...24).map { AISearchSource(title: "合成搜索结果 \($0)", url: URL(string: "https://fixture.invalid/result-\($0)")!, excerpt: "") },
        references: [
            AIPageReference(title: "热量高低判断依据", url: referenceURL),
            AIPageReference(title: "无网址的来源", url: nil)
        ])
        store.newTab()
        panel.contentView = RootHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        panel.bindTabFocus(to: store); panel.makeKeyAndOrderFront(nil)
        let fixture = HomePageFixture(store: store, panel: panel)
        let home = try await fixture.home()
        try await fixture.click("[data-action='chat']", web: home)
        let web = try await ready(panel)
        guard fixture.toolbar().currentEditor() == nil else {
            throw PerchError("Opening Chat from home automatically focused the address")
        }
        let expandedChatWidth = web.bounds.width
        let firstChat = store.selected!
        store.newTab(address: "perch://chat")
        let secondChat = store.selected!
        guard try await ready(panel) === web else { throw PerchError("Chat tabs created duplicate renderers") }
        guard fixture.toolbar().currentEditor() == nil else {
            throw PerchError("Opening a new Chat tab automatically focused the address")
        }
        NotificationCenter.default.post(name: .focusAddress, object: nil)
        guard let editor = fixture.toolbar().currentEditor() as? NSTextView,
              editor.selectedRange().length == "perch://chat".utf16.count else {
            throw PerchError("Explicit address focus must still select the Chat URL")
        }
        print("PASS: home and new-tab Chat opening leave the address unfocused; explicit address shortcut selects its URL")
        try await type("跨标签共享草稿", fixture: fixture, web: web)
        _ = try await web.evaluateJavaScript("document.getElementById('composer').setSelectionRange(1,4);document.documentElement.dataset.fixtureShared='true'")
        store.chatHistoryVisible = false
        for id in [firstChat, secondChat, firstChat, secondChat] {
            store.activate(id)
            guard try await ready(panel) === web, store.chatOwner == owner, !store.chatHistoryVisible else {
                throw PerchError("Switching Chat tabs replaced shared presentation state")
            }
            try await check(web, """
                document.documentElement.dataset.fixtureShared==='true' && document.getElementById('composer').value==='跨标签共享草稿' &&
                document.getElementById('composer').selectionStart===1 && document.getElementById('composer').selectionEnd===4
                """, "切换 Chat 标签丢失 DOM、草稿或选区", arguments: [:])
        }
        let routeBrowser = store.cachedBrowser(for: secondChat)!
        try await AISelfCheck.wait { !routeBrowser.loading && ChatPage.matches(routeBrowser.webView.url) }
        guard routeBrowser.address == "perch://chat" else { throw PerchError("Chat address bar lacks its route") }
        if let baseURL {
            _ = try await web.callAsyncJavaScript("""
                const update=window.perchUpdate;window.fixtureUpdates=0;
                window.perchUpdate=state=>{window.fixtureUpdates++;update(state)};
                """, arguments: [:], in: nil, contentWorld: .defaultClient)
            store.navigate(baseURL + "/nav/chat-route")
            try await AISelfCheck.wait { !routeBrowser.loading && routeBrowser.webView.url?.path == "/nav/chat-route" }
            guard !store.isChatPage else { throw PerchError("Chat address bar cannot leave Chat") }
            try await AISelfCheck.wait { web.window == nil }
            _ = try await web.callAsyncJavaScript("window.fixtureUpdates=0", arguments: [:], in: nil, contentWorld: .defaultClient)
            store.ai.drafts[owner] = "后台更新的共享草稿"
            web.controller?.update()
            try await check(web, "window.fixtureUpdates===0", "离窗 Chat 仍在重复渲染")
            routeBrowser.goBack()
            try await AISelfCheck.wait { store.isChatPage && !routeBrowser.loading }
            guard try await ready(panel) === web else { throw PerchError("Back navigation replaced shared Chat") }
            try await waitFor(web, "document.getElementById('composer').value==='后台更新的共享草稿'")
            try await type("跨标签共享草稿", fixture: fixture, web: web)
        }
        store.close(firstChat)
        guard try await ready(panel) === web, store.ai.drafts[owner] == "跨标签共享草稿" else {
            throw PerchError("Closing another Chat tab lost its draft")
        }
        store.chatHistoryVisible = true
        try await AISelfCheck.wait {
            panel.contentView?.layoutSubtreeIfNeeded()
            return abs(web.bounds.width - expandedChatWidth) < 1
        }
        try await type("", fixture: fixture, web: web)
        if let root = panel.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/perch-chat-tabs.png"))
        }
        print("PASS: Chat tabs share one renderer, draft, selection and history state; address navigation/back preserve Chat")
        if quoteOnly {
            try await fixture.click("#composer", web: web)
            _ = try await web.evaluateJavaScript("""
                document.querySelector('.markdown').scrollIntoView({block:'start'});
                const range=document.createRange();range.selectNodeContents(document.querySelector('.markdown strong'));
                getSelection().removeAllRanges();getSelection().addRange(range);
                """)
            try await waitFor(web, "!document.getElementById('quote-selection').hidden")
            try await quoteFade(web)
            let point = try await web.callAsyncJavaScript("""
                const r=document.getElementById('quote-selection').getBoundingClientRect();
                return {x:r.right-3,y:r.y+r.height/2};
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as! [String: Double]
            let location = web.convert(NSPoint(x: point["x"]!,
                y: web.isFlipped ? point["y"]! : web.bounds.height-point["y"]!), to: nil)
            fixture.mouse(.leftMouseDown, at: location); fixture.mouse(.leftMouseUp, at: location)
            try await AISelfCheck.wait { store.ai.draftQuotes[owner]?.text == "中文句子。" }
            try await waitFor(web, "document.querySelector('.quoted-text')?.textContent==='中文句子。'")
            guard let quote = store.ai.draftQuotes[owner], quote.sourceRange != nil,
                  try JSONDecoder().decode(AIQuote.self, from: JSONEncoder().encode(quote)) == quote else {
                throw PerchError("Quoted answer source range was not persisted")
            }
            store.ai.drafts[owner] = "保留这份问题草稿"
            web.controller?.update()
            try await waitFor(web, "document.getElementById('composer').value==='保留这份问题草稿'")
            try await fixture.click(".quoted-text", web: web)
            try await waitFor(web, "!document.getElementById('quote-selection').hidden && document.getElementById('quote-selection').textContent==='取消引用'")
            try await check(web, """
                [...document.querySelectorAll('.quoted-text')].every(m=>m.classList.contains('quoted-active') &&
                    getComputedStyle(m).backgroundColor!=='rgba(0, 0, 0, 0)')
                """, "点击引用原文没有高亮整组文字")
            let cancel = try await web.callAsyncJavaScript("""
                const r=document.getElementById('quote-selection').getBoundingClientRect();
                return {x:r.right-3,y:r.y+r.height/2};
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as! [String: Double]
            let cancelLocation = web.convert(NSPoint(x: cancel["x"]!,
                y: web.isFlipped ? cancel["y"]! : web.bounds.height-cancel["y"]!), to: nil)
            fixture.mouse(.leftMouseDown, at: cancelLocation); fixture.mouse(.leftMouseUp, at: cancelLocation)
            try await AISelfCheck.wait { store.ai.draftQuotes[owner] == nil }
            try await waitFor(web, "!document.querySelector('.quoted-text')")
            guard store.ai.drafts[owner] == "保留这份问题草稿" else { throw PerchError("Removing quote changed the draft") }
            try await check(web, """
                (()=>{
                    const root=document.createElement('div');root.innerHTML='<p>重复文字 <strong>重复文字</strong> 😀<em>跨格式</em>尾部</p>';
                    document.getElementById('messages').append(root);
                    const id='fixture', roots=[{id,root}], value=root.textContent,
                        start=value.lastIndexOf('重复文字'), sourceRange={start,end:start+4},
                        quote={messageID:id,text:'重复文字',sourceRange};
                    window.updateQuotedText(roots,quote);
                    if(root.querySelectorAll('.quoted-text').length!==1 || !root.querySelector('strong .quoted-text'))return false;
                    const marker=root.querySelector('.quoted-text');
                    const range=document.createRange();range.selectNodeContents(root.querySelector('em'));
                    getSelection().removeAllRanges();getSelection().addRange(range);
                    window.updateQuotedText(roots,quote);
                    if(root.querySelector('.quoted-text')!==marker || getSelection().toString()!=='跨格式')return false;
                    const crossStart=value.indexOf('😀'), cross={messageID:id,text:'😀跨格式尾部',sourceRange:{start:crossStart,end:value.length}};
                    window.updateQuotedText(roots,cross);
                    if([...root.querySelectorAll('.quoted-text')].map(m=>m.textContent).join('')!==cross.text ||
                       getSelection().toString()!=='跨格式' ||
                       getComputedStyle(root.querySelector('.quoted-text')).textDecorationStyle!=='dashed')return false;
                    window.highlightQuotedText();
                    if(![...root.querySelectorAll('.quoted-text')].every(m=>m.classList.contains('quoted-active')) ||
                       getSelection().toString()!=='跨格式')return false;
                    root.innerHTML='<p>重复文字 <strong>重复文字</strong> 😀<em>跨格式</em>尾部</p>';
                    window.updateQuotedText(roots,cross);
                    if([...root.querySelectorAll('.quoted-text')].map(m=>m.textContent).join('')!==cross.text ||
                       ![...root.querySelectorAll('.quoted-text')].every(m=>m.classList.contains('quoted-active')))return false;
                    window.updateQuotedText(roots,{messageID:id,text:'重复文字'});
                    if(root.querySelector('.quoted-text'))return false;
                    window.updateQuotedText(roots,{messageID:id,text:'跨格式'});
                    if(root.querySelector('.quoted-text')?.textContent!=='跨格式')return false;
                    window.updateQuotedText(roots,null);root.remove();getSelection().removeAllRanges();return true;
                })()
                """, "Quoted text lost exact range, Unicode, selection, refresh or legacy compatibility")
            store.ai.draftQuotes[owner] = quote; web.controller?.update()
            try await waitFor(web, "!!document.querySelector('.quoted-text')")
            _ = try await web.evaluateJavaScript("""
                document.querySelector('.markdown').style.paddingBottom='1000px';
                const scroll=document.getElementById('scroll');scroll.scrollTop=scroll.scrollHeight;
                """)
            try await fixture.click("#draft-quote .quote-source", web: web)
            try await waitFor(web, """
                (()=>{const marker=document.querySelector('.quoted-active'),r=marker?.getBoundingClientRect(),
                    viewport=document.getElementById('scroll').getBoundingClientRect();
                    return r && r.top>=viewport.top && r.bottom<=viewport.bottom &&
                        document.getElementById('quote-selection').hidden;})()
                """)
            guard store.ai.drafts[owner] == "保留这份问题草稿" else { throw PerchError("Locating quote changed draft") }
            web.controller?.update()
            try await waitFor(web, "!!document.querySelector('.quoted-active')")
            try await fixture.click("#composer", web: web)
            try await waitFor(web, "!document.querySelector('.quoted-active') && !!document.querySelector('.quoted-text')")
            try await fixture.click("#draft-quote .quote-source", web: web)
            try await fixture.key(53, "\u{1b}")
            try await waitFor(web, "!document.querySelector('.quoted-active')")
            try await fixture.click("#composer", web: web)
            for _ in 0..<8 {
                try await fixture.key(48, "\t", flags: [.shift, .option])
                if try await web.evaluateJavaScript("document.activeElement.classList.contains('quote-source')") as? Bool == true { break }
            }
            try await check(web, "document.activeElement.classList.contains('quote-source')",
                            "原生键盘导航未聚焦引用原文按钮")
            try await fixture.key(36, "\r")
            try await waitFor(web, "!!document.querySelector('.quoted-active')")
            try await fixture.click("#draft-items button[aria-label='移除引用']", web: web)
            try await AISelfCheck.wait { store.ai.draftQuotes[owner] == nil }
            try await waitFor(web, "!document.querySelector('.quoted-text')")
            guard store.ai.drafts[owner] == "保留这份问题草稿" else { throw PerchError("Quote highlighting or keyboard activation changed the draft") }
            print("PASS: exact quote underline, native source/cancel padding clicks, Unicode/multi-node ranges, selection, refresh, legacy quotes and composer removal")
            print("PASS: native quote-button padding click delivers the exact selected excerpt")
            print("PASS: native source/card clicks and keyboard activation highlight the full quote, reveal its source, preserve draft and clear on dismissal")
            return
        }
        let recorder = BridgeRecorder(web)
        var nativeHoverEvents: [String] = []
        let hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited, .leftMouseDragged]) {
            nativeHoverEvents.append("\($0.type.rawValue):window=\($0.windowNumber):point=\($0.locationInWindow)")
            if nativeHoverEvents.count > 12 { nativeHoverEvents.removeFirst() }
            return $0
        }
        defer { if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await check(web, "document.querySelectorAll('.message').length===2 && !!document.querySelector('.markdown table')",
                        "消息和 Markdown 表格未显示")
        try await check(web, "!window.untrustedChatScript && document.querySelectorAll('#send').length===1 && !document.querySelector('.markdown button#send')",
                        "模型 HTML 必须净化，不能创建操作控件")
        _ = try await web.callAsyncJavaScript("""
            const update=window.perchUpdate;
            window.perchUpdate=state=>{window.fixtureState=state;update(state)};
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        web.controller?.update()
        try await waitFor(web, "!!window.fixtureState")
        try await check(web, """
            (() => {
                const table=document.querySelector('.markdown table'), link=document.querySelector('.source-citation');
                const reverse=value=>Array.isArray(value) ? value.map(reverse) :
                    value && typeof value==='object' ? Object.fromEntries(Object.keys(value).reverse().map(k=>[k,reverse(value[k])])) : value;
                window.perchUpdate(reverse(window.fixtureState));
                return table===document.querySelector('.markdown table') && link===document.querySelector('.source-citation');
            })()
            """, "桥接对象字段重排重建了未变化的 Markdown")
        guard try await web.evaluateJavaScript("!!window.webkit?.messageHandlers?.perchInternal") as? Bool == false else {
            throw PerchError("Chat page world exposes the host bridge")
        }
        try await check(web, "document.getElementById('composer').getBoundingClientRect().height===64",
                        "完整聊天输入框没有收紧")
        try await check(web, """
            (()=>{const message=document.querySelector('.message.user'),body=message.querySelector('.plain-text');
                return message.querySelector('header time') && !message.querySelector(':scope>time') &&
                    Math.abs(message.getBoundingClientRect().bottom-body.getBoundingClientRect().bottom-10)<1;
            })()
            """, "消息时间应并入标题行，正文下方不应预留时间行")
        try await fixture.click("#composer", web: web)
        for _ in 0..<8 {
            try await fixture.key(48, "\t")
            if try await web.evaluateJavaScript("document.activeElement.id") as? String == "search-source" { break }
        }
        try await check(web, """
            (()=>{const control=document.getElementById('search-source-control'),select=document.getElementById('search-source'),
                r=control.getBoundingClientRect(),icon=control.querySelector('svg').getBoundingClientRect(),
                highlight=getComputedStyle(control,'::before');
                return select===document.activeElement && select.matches(':focus-visible') &&
                    Math.abs(r.x+r.width/2-icon.x-icon.width/2)<.01 &&
                    Math.abs(r.y+r.height/2-icon.y-icon.height/2)<.01 &&
                    highlight.left==='0px' && highlight.right==='0px' && highlight.top===highlight.bottom &&
                    highlight.backgroundColor!=='rgba(0, 0, 0, 0)' &&
                    document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)===select;
            })()
            """, "联网方式图标与高亮没有居中，或原生选择器丢失键盘焦点/命中范围")
        if let path = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"] {
            let image = try await web.takeSnapshot(configuration: nil)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: path).appendingPathComponent("search-source-centered.png"))
            }
        }
        print("PASS: native Tab focuses search picker; icon/highlight centers and native select hit area align")
        try await toolbarCursor(fixture: fixture, web: web)
        try await fixture.click("#model-button", web: web)
        try await fixture.key(48, "\t", flags: .shift)
        try await fixture.key(48, "\t")
        try await check(web, """
            document.activeElement.id==='model-search' && document.activeElement.matches(':focus-visible') &&
                getComputedStyle(document.activeElement).outlineStyle==='none' &&
                getComputedStyle(document.activeElement).borderTopWidth==='0px'
            """, "模型搜索框聚焦时仍显示边框或描边")
        if let path = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"] {
            let image = try await web.takeSnapshot(configuration: nil)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: path).appendingPathComponent("model-search-focused.png"))
            }
        }
        try await fixture.click("#model-list button", web: web)
        print("PASS: native keyboard focus keeps model search borderless and model selection works")
        _ = try await web.callAsyncJavaScript("""
            const scroll=document.getElementById('scroll'), body=document.querySelector('.assistant .markdown'),
                summary=document.querySelector('.assistant details:has(.sources) summary');
            body.style.maxHeight='180px';body.style.overflow='hidden';
            document.querySelector('.assistant').style.marginTop='900px';
            await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
            scroll.scrollTop=scroll.scrollHeight;
            await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
            window.fixtureSearchTop=summary.getBoundingClientRect().top;
            window.fixtureSearchBottomGap=scroll.scrollHeight-scroll.clientHeight-scroll.scrollTop;
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        try await check(web, "window.fixtureSearchBottomGap < 2", "搜索展开夹具必须从底部开始")
        try await fixture.click(".assistant details:has(.sources) summary", web: web)
        try await check(web, """
            document.querySelector('.assistant .sources').parentElement.open &&
                document.querySelector('.assistant .sources').clientHeight===220 &&
                document.querySelector('.assistant .sources').scrollHeight>220 &&
                getComputedStyle(document.querySelector('.assistant .sources').previousElementSibling).listStyleType==='none' &&
                getComputedStyle(document.querySelector('.assistant .sources').previousElementSibling,'::before').borderTopStyle==='solid'
            """, "联网搜索结果缺少高度限制或空心折叠箭头")
        try await check(web, """
            (()=>{const summary=document.querySelector('.assistant .sources').previousElementSibling,
                scroll=document.getElementById('scroll');
                return Math.abs(summary.getBoundingClientRect().top-window.fixtureSearchTop)<2 &&
                    scroll.scrollHeight-scroll.clientHeight-scroll.scrollTop>100;
            })()
            """, "从底部展开联网搜索时，标题应留在原位，结果向下展开")
        _ = try await web.evaluateJavaScript("""
            document.addEventListener('wheel',e=>window.fixtureWheel={trusted:e.isTrusted,x:e.clientX,y:e.clientY,
                target:e.target.className,delta:e.deltaY},true);
            """)
        try await wheel(-400, at: try await fixture.point(".assistant .sources", web: web), web: web, window: panel)
        do { try await waitFor(web, "document.querySelector('.assistant .sources').scrollTop>0") }
        catch {
            let diagnostic = try await web.evaluateJavaScript("""
                JSON.stringify({wheel:window.fixtureWheel,rect:document.querySelector('.assistant .sources').getBoundingClientRect(),
                    scroll:document.getElementById('scroll').scrollTop})
                """)
            throw PerchError("Native search scrolling: \(diagnostic ?? "none"); \(error)")
        }
        try await fixture.click(".assistant details:has(.sources) summary", web: web)
        try await check(web, "!document.querySelector('.assistant .sources').parentElement.open", "搜索结果无法收起")
        _ = try await web.evaluateJavaScript("""
            document.querySelector('.assistant').style.removeProperty('margin-top');
            const body=document.querySelector('.assistant .markdown');
            body.style.removeProperty('max-height');body.style.removeProperty('overflow');
            """)
        print("PASS: native search disclosure anchors its title at the bottom, bounds results, and allows inner scrolling")
        _ = try await web.evaluateJavaScript("document.querySelector('.markdown pre').scrollIntoView({block:'center'})")
        fixture.mouse(.mouseMoved, at: try await fixture.point(".markdown pre", web: web))
        do {
            try await waitFor(web, "document.querySelector('.markdown pre').classList.contains('hovered') && getComputedStyle(document.querySelector('.code-tools')).opacity==='1'")
        } catch {
            throw PerchError("Native code hover: active=\(NSApp.isActive), key=\(panel.isKeyWindow), events=\(nativeHoverEvents); \(error)")
        }
        let codeHeight = try await web.evaluateJavaScript("document.querySelector('.markdown pre').getBoundingClientRect().height") as! Double
        fixture.mouse(.mouseMoved, at: try await fixture.point("#toolbar", web: web))
        try await waitFor(web, "getComputedStyle(document.querySelector('.code-tools')).opacity==='0' && getComputedStyle(document.querySelector('.code-tools')).pointerEvents==='none'")
        try await check(web, "document.querySelector('.markdown pre').getBoundingClientRect().height===height",
                        "隐藏代码操作改变了代码框布局", arguments: ["height": codeHeight])
        try await fixture.focus()
        _ = try await web.evaluateJavaScript("document.querySelector('.code-tools button').focus()")
        try await waitFor(web, "getComputedStyle(document.querySelector('.code-tools')).opacity==='1'")
        _ = try await web.evaluateJavaScript("document.activeElement.blur()")
        try await waitFor(web, "getComputedStyle(document.querySelector('.code-tools')).opacity==='0'")
        print("PASS: native code-block hover, keyboard focus, hidden pointer boundary and unchanged layout; compact composer")
        _ = try await web.evaluateJavaScript("document.querySelector('.message.user').scrollIntoView({block:'center'})")
        let copySelector = ".message.user [aria-label='复制内容']"
        fixture.mouse(.mouseMoved, at: try await fixture.point(".message.user", web: web))
        try await waitFor(web, "document.querySelector('.message.user').classList.contains('hovered')")
        fixture.mouse(.mouseMoved, at: try await fixture.point(copySelector, web: web))
        try await waitFor(web, """
            (()=>{const b=document.querySelector(selector),rect=b.getBoundingClientRect(),style=getComputedStyle(b,'::before');
                return b.classList.contains('hovered') && rect.width===24 && rect.height===24 &&
                    style.top==='2px' && style.backgroundColor!=='rgba(0, 0, 0, 0)';})()
            """, arguments: ["selector": copySelector])
        try await fixture.click(copySelector, web: web)
        do {
            try await AISelfCheck.wait { NSPasteboard.general.string(forType: .string) == store.ai.sessions[owner]?.messages.first?.text }
        } catch {
            throw PerchError("Compact message copy missed the native bridge")
        }
        print("PASS: inset message action highlight and unchanged full button hit area")
        if styleOnly {
            try await richContent(fixture: fixture, web: web, owner: owner)
            return
        }
        try await check(web, """
            [...document.querySelectorAll('.message.user .source-chip')].every(chip=>{
                const style=getComputedStyle(chip);
                return chip.querySelector('svg') && style.textDecorationLine==='none' &&
                    style.paddingTop==='3px' && style.paddingLeft==='6px' && style.borderRadius==='5px' &&
                    chip.getBoundingClientRect().height < 24;
            }) && document.querySelectorAll('.message.user .source-chip').length===2 &&
                !document.querySelector('.message.user .source-chip:last-child').hasAttribute('href')
            """, "消息来源未恢复紧凑图标标签，或无网址来源被错误链接")
        let sourceChatTab = store.selected!
        _ = try await web.evaluateJavaScript("document.querySelector('.message.user .source-chip[href]').scrollIntoView({block:'center'})")
        try await fixture.click(".message.user .source-chip[href]", web: web)
        try await AISelfCheck.wait { store.tabs.contains(where: { $0.address == referenceURL.absoluteString }) && store.selected != sourceChatTab }
        let openedSourceTab = store.selected!
        store.activate(sourceChatTab)
        store.close(openedSourceTab)
        _ = try await ready(panel)
        print("PASS: muted source chips retain icons, compact bounds, URL-less labels and native open-page clicks")
        try await fixture.click("#composer", web: web)
        guard let client = panel.firstResponder as? NSTextInputClient else { throw PerchError("Chat lacks native text input client") }
        client.insertText("草稿 fixture", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await AISelfCheck.wait { store.ai.drafts[owner] == "草稿 fixture" }
        _ = try await web.evaluateJavaScript("""
            document.getElementById('composer').setSelectionRange(2,4);
            document.documentElement.dataset.composing='false';
            document.getElementById('composer').addEventListener('compositionstart',()=>document.documentElement.dataset.composing='true');
            document.getElementById('composer').addEventListener('compositionend',()=>document.documentElement.dataset.composing='false');
            """)
        client.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await check(web,"document.documentElement.dataset.composing==='true'","原生组合输入未开始")
        let draft = store.ai.drafts[owner]
        web.controller?.update()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await check(web,"document.documentElement.dataset.composing==='true' && document.getElementById('composer').value.includes('ni')","刷新丢失组合输入")
        guard store.ai.drafts[owner] == draft else { throw PerchError("Uncommitted composition leaked into draft") }
        let messageCount = store.ai.sessions[owner]!.messages.count
        try await fixture.key(36, "\r")
        guard store.ai.sessions[owner]!.messages.count == messageCount, store.ai.queuedMessages[owner]?.isEmpty != false else {
            throw PerchError("IME Return must not send or queue a message")
        }
        client.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 150_000_000)
        try await check(web,"document.documentElement.dataset.composing==='false'","原生组合输入未提交")
        print("PASS: HTML Chat native insertion/IME, isolated bridge, sanitized Markdown, code and table controls")

        _ = try await web.evaluateJavaScript("document.getElementById('composer').select()")
        client.insertText("换行", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.key(36, "\r", flags: .shift)
        try await AISelfCheck.wait { store.ai.drafts[owner] == "换行\n" }
        var settings = store.settings; settings.aiSendWithCommand = true; try store.saveSettings(settings)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await fixture.key(36, "\r")
        try await AISelfCheck.wait { store.ai.drafts[owner] == "换行\n\n" }
        settings.aiSendWithCommand = false; try store.saveSettings(settings)
        _ = try await web.evaluateJavaScript("document.getElementById('composer').setSelectionRange(0,2)")
        let chatTab = store.selected!
        store.newTab()
        _ = try await fixture.home()
        store.activate(chatTab)
        let returned = try await ready(panel)
        guard returned === web else { throw PerchError("Tab switch recreated Chat WebView") }
        try await check(web,"document.getElementById('composer').selectionStart===0 && document.getElementById('composer').selectionEnd===2",
                        "切页丢失输入选区")
        let originalFont = store.settings.chatFontSize
        settings = store.settings; settings.chatFontSize = 22; try store.saveSettings(settings)
        try await Task.sleep(nanoseconds: 150_000_000)
        try await check(web,"parseFloat(getComputedStyle(document.getElementById('composer')).fontSize)===22 && document.getElementById('composer').selectionEnd===2",
                        "字号变化必须保留输入选区")
        settings.chatFontSize = originalFont; try store.saveSettings(settings)
        print("PASS: native Shift/Return shortcuts, retained Chat WebView, draft selection and font changes")

        let beforeSearch = store.ai.searchEnabled(for: owner)
        try await fixture.click("#search-enabled", web: web)
        try await AISelfCheck.wait { store.ai.searchEnabled(for: owner) != beforeSearch }
        try await fixture.click("#search-enabled", web: web)
        try await AISelfCheck.wait { store.ai.searchEnabled(for: owner) == beforeSearch }
        try await fixture.click("#model-button", web: web)
        try await check(web,"!document.getElementById('models').hidden && document.activeElement.id==='model-search'","模型搜索未获得焦点")
        try await fixture.click("#model-list button", web: web)
        try await check(web,"document.getElementById('models').hidden","选择模型后弹层未关闭")
        let retainedDraft = store.ai.drafts[owner]
        _ = try await web.callAsyncJavaScript("""
            window.webkit.messageHandlers.perchInternal.postMessage({action:'draft',owner:'wrong-owner',
                conversation:document.documentElement.dataset.conversation,text:'must-not-write',revision:999});
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard store.ai.drafts[owner] == retainedDraft else { throw PerchError("Cross-owner bridge action was accepted") }
        print("PASS: native model picker/search toggle hit paths and cross-owner bridge rejection")

        let referencedPage = Tab(title: "Reference fixture", address: "http://127.0.0.1:9/reference")
        store.tabs.append(referencedPage)
        try await type("请查看@Reference", fixture: fixture, web: web)
        try await waitFor(web, "!document.getElementById('mentions').hidden && document.querySelectorAll('#mention-list button').length===1")
        try await fixture.key(36, "\r")
        try await AISelfCheck.wait { store.ai.draftReferences[owner] == [referencedPage.id] && store.ai.drafts[owner] == "请查看" }
        guard store.ai.sessions[owner]!.messages.count == messageCount else { throw PerchError("@ selection sent a message") }
        store.close(referencedPage.id)
        try await waitFor(web, "document.getElementById('draft-items').textContent.includes('发送时恢复引用')")
        _ = try await web.evaluateJavaScript("""
            document.addEventListener('click',event=>{window.lastFixtureClick={tag:event.target.outerHTML,trusted:event.isTrusted}},true);
            const hover=window.updateChatHover;
            window.updateChatHover=(x,y)=>{
                const arrow=hover(x,y);
                const target=Number.isFinite(x)&&Number.isFinite(y)?document.elementFromPoint(x,y):null;
                (window.fixtureHoverEvents ||= []).push({x,y,target:target?.tagName,cls:target?.className});
                if(window.fixtureHoverEvents.length>12)window.fixtureHoverEvents.shift();
                return arrow;
            };
            void 0;
            """)
        try await fixture.click("#draft-items [aria-label='移除引用']", web: web)
        do { try await AISelfCheck.wait { store.ai.draftClosedReferences[owner]?.isEmpty != false } }
        catch {
            let diagnostic = try await web.evaluateJavaScript("JSON.stringify({click:window.lastFixtureClick,items:document.getElementById('draft-items').innerHTML,owner:document.documentElement.dataset.owner})")
            throw PerchError("Closed-reference removal: \(diagnostic ?? "none"); remaining=\(String(describing: store.ai.draftClosedReferences[owner])), active=\(NSApp.isActive), key=\(panel.isKeyWindow)")
        }
        let draftBeforeEdit = store.ai.drafts[owner], originalMessages = store.ai.sessions[owner]!.messages
        for action in ["重新编辑这条消息", "从这轮 Fork 新对话"] {
            _ = try await web.evaluateJavaScript("document.querySelector('.message.user').scrollIntoView({block:'start'})")
            let target = ".message.user [aria-label='\(action)']"
            // Hover through the application event route so the real message action becomes hittable.
            fixture.mouse(.mouseMoved, at: try await fixture.point(".message.user", web: web))
            try await Task.sleep(nanoseconds: 150_000_000)
            try await fixture.click(target, web: web)
            do { try await AISelfCheck.wait { store.ai.pendingEdits[owner] != nil } }
            catch {
                let diagnostic = try await web.evaluateJavaScript("""
                    JSON.stringify({click:window.lastFixtureClick,classes:document.querySelector('.message.user').className,
                        actions:getComputedStyle(document.querySelector('.message-actions')).pointerEvents,
                        top:document.getElementById('scroll').scrollTop,hover:window.fixtureHoverEvents})
                    """)
                throw PerchError("Edit click \(action): \(diagnostic ?? "none"), events=\(nativeHoverEvents), bridge=\(recorder.actions)")
            }
            try await waitFor(web, "document.getElementById('composer').value===text && !!document.querySelector('.message.editing')",
                              arguments: ["text": originalMessages[0].text])
            guard store.ai.pendingEdits[owner]?.fork == action.contains("Fork") else { throw PerchError("Wrong edit mode") }
            try await fixture.click("#composer", web: web)
            try await fixture.key(53, "\u{1b}")
            try await AISelfCheck.wait { store.ai.pendingEdits[owner] == nil && store.ai.drafts[owner] == draftBeforeEdit }
            guard store.ai.sessions[owner]!.messages.map(\.id) == originalMessages.map(\.id) else {
                throw PerchError("Cancel edit changed conversation history")
            }
        }
        print("PASS: native @ filtering/Return, closed-reference removal, rewind/Fork preview and Escape preserve drafts/history")

        _ = try await web.evaluateJavaScript("""
            document.querySelector('.markdown').scrollIntoView({block:'start'});
            const range=document.createRange();range.selectNodeContents(document.querySelector('.markdown strong'));
            getSelection().removeAllRanges();getSelection().addRange(range);
            """)
        try await waitFor(web, "!document.getElementById('quote-selection').hidden")
        try await quoteFade(web)
        try await fixture.click("#quote-selection", web: web)
        try await AISelfCheck.wait { store.ai.draftQuotes[owner]?.text == "中文句子。" }
        try await fixture.click("#draft-quote [aria-label='移除引用']", web: web)
        try await AISelfCheck.wait { store.ai.draftQuotes[owner] == nil }
        print("PASS: selected Markdown quote uses the native button path and can be removed")

        let referencePages = (1...4).map { Tab(title: "引用网页 \($0)", address: "https://fixture.invalid/\($0)") }
        store.tabs.append(contentsOf: referencePages)
        store.ai.draftReferences[owner] = referencePages.map(\.id)
        try await waitFor(web, "document.getElementById('more-references')?.textContent==='+2'")
        try await fixture.click("#more-references", web: web)
        try await check(web, "!document.getElementById('references').hidden && document.querySelectorAll('#references .chip').length===4",
                        "折叠网页引用没有展开全部条目")
        try await fixture.click("#references .chip:last-child [aria-label='移除引用']", web: web)
        try await AISelfCheck.wait { store.ai.draftReferences[owner]?.count == 3 }
        try await waitFor(web, "document.querySelectorAll('#references .chip').length===3")
        try await fixture.key(53, "\u{1b}")
        try await check(web, "document.getElementById('references').hidden", "Escape 没有收起网页引用")
        store.ai.draftReferences[owner] = []
        try await waitFor(web, "document.getElementById('draft-items').children.length===0")
        print("PASS: two visible webpage chips, +N expansion, native remove/Escape and empty draft spacing")

        let board = NSPasteboard.general
        let savedClipboard = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); if !savedClipboard.isEmpty { board.writeObjects(savedClipboard) } }
        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.lockFocus(); NSColor.systemGreen.setFill(); NSRect(x: 0, y: 0, width: 40, height: 30).fill(); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        for (index, format) in [NSBitmapImageRep.FileType.png, .tiff, .jpeg].enumerated() {
            let pasteType: NSPasteboard.PasteboardType = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")][index]
            board.clearContents(); board.setData(bitmap.representation(using: format, properties: [:])!, forType: pasteType)
            try await fixture.click("#composer", web: web)
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            try await AISelfCheck.wait { store.ai.draftFiles[owner]?.count == index + 1 }
        }
        for _ in 0..<3 {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        guard store.ai.draftFiles[owner]?.count == 5 else { throw PerchError("Image paste must enforce five-file limit") }
        try await waitFor(web, "document.getElementById('file-error').textContent.includes('5 个文件')")
        try await fixture.click("#draft-items [aria-label='移除附件']", web: web)
        try await AISelfCheck.wait { store.ai.draftFiles[owner]?.count == 4 }
        store.ai.draftFiles[owner] = []
        print("PASS: native PNG/TIFF/JPEG paste, thumbnails, file limit and remove attachment")

        try await type(String(repeating: "字", count: 8001), fixture: fixture, web: web)
        try await fixture.key(36, "\r")
        try await check(web, "document.getElementById('send').disabled && document.getElementById('composer').value.length===8001",
                        "超长输入必须保留草稿并拒绝发送")
        guard store.ai.sessions[owner]!.messages.count == messageCount else { throw PerchError("Oversized draft was sent") }
        try await type("保留草稿", fixture: fixture, web: web)
        try await richContent(fixture: fixture, web: web, owner: owner)

        if let baseURL {
            _ = baseURL
            var settings = store.settings; settings.aiSendWithCommand = true; try store.saveSettings(settings)
            try await fixture.click("#composer", web: web)
            _ = try await web.evaluateJavaScript("document.getElementById('composer').select()")
            guard let input = panel.firstResponder as? NSTextInputClient else { throw PerchError("Chat input lost focus") }
            input.insertText("HTML send fixture", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await fixture.key(36, "\r", flags: .command)
            try await AISelfCheck.wait { store.ai.sessions[owner]?.messages.contains(where: { $0.role == "user" && $0.text == "HTML send fixture" }) == true }
            try await AISelfCheck.wait { store.ai.sessions[owner]?.requestID == nil }
            try await check(web,"document.getElementById('composer').value===''", "受理发送后没有清空输入")
            guard store.ai.sessions[owner]?.error == nil else { throw PerchError(store.ai.sessions[owner]!.error!) }
            print("PASS: native HTML composer Command-Return reaches synthetic API and clears only accepted drafts")
        }
        let snapshot = try await web.takeSnapshot(configuration: nil)
        if let data = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/perch-chat-html.png"))
        }
    }

    static func richContent(fixture sourceFixture: HomePageFixture, web sourceWeb: AIChatWebView, owner: UUID) async throws {
        try await click("名称", within: ".markdown table", fixture: sourceFixture, web: sourceWeb)
        try await check(sourceWeb, "document.querySelector('.markdown tbody tr td').textContent==='Alpha'", "表格排序失效")
        try await click("复制表格", within: ".markdown", fixture: sourceFixture, web: sourceWeb)
        guard NSPasteboard.general.string(forType: .string)?.contains("Alpha\t1") == true else { throw PerchError("Table copy missed bridge") }
        try await click("复制代码", within: ".markdown", fixture: sourceFixture, web: sourceWeb)
        guard NSPasteboard.general.string(forType: .string)?.contains("print(\"fixture\")") == true else { throw PerchError("Code copy missed bridge") }

        let old = AIGeneratedFile(name: "fixture.html", content: "<h1>Old fixture</h1>")
        let updated = AIGeneratedFile(name: "fixture.html", content: """
            <h1>New fixture</h1><script>
            let parentBlocked=false;try{parent.document.body.dataset.escaped='true'}catch(e){parentBlocked=true}
            parent.postMessage({fixtureSandbox:true,parentBlocked,bridge:!!window.webkit?.messageHandlers?.perchInternal},'*');
            </script>
            """)
        var first = AIMessage(role: "assistant", text: "旧文件"); first.generatedFiles = [old]
        first.reasoning = (0..<60).map { "合成思考步骤 \($0)" }.joined(separator: "\n")
        var last = AIMessage(role: "assistant", text: "```mermaid\nflowchart LR\nA --> B\n```")
        last.generatedFiles = [updated]; last.followups = ["继续解释"]
        let original = AISession(messages: [first, last], origin: .chat)
        var question = AIMessage(role: "assistant", text: "请选择输出形式")
        question.clarification = AIClarification(questions: [.init(label: "输出形式", options: ["简短", "详细"])])
        let clarification = AISession(messages: [question], origin: .chat)
        let suite = "dev.perch.chat-rich.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(AIConversationArchive(conversations: [original.id: original, clarification.id: clarification], tabs: [owner: original.id]))
            .write(to: directory.appendingPathComponent("conversations.json"))
        let ai = AIController(defaults: defaults, conversationDirectory: directory), store = Store(defaults: defaults)
        precondition(ai.save(sourceFixture.store.ai.provider(for: owner), key: "synthetic-key"))
        ai.drafts[owner] = "保留草稿"
        let panel = Panel(contentRect: NSRect(x: 140, y: 100, width: 950, height: 760),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .floating
        let host = NSHostingView(rootView: AIChatSidebar(store: store, ai: ai, fullPage: true, owner: owner, close: {}).defaultAppStorage(defaults))
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.orderOut(nil); panel.contentView = nil
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory)
        }
        let web = try await ready(panel), fixture = HomePageFixture(store: store, panel: panel)
        try await fixture.click("#composer", web: web)
        try await toolbarCursor(fixture: fixture, web: web)
        host.rootView = AIChatSidebar(store: store, ai: ai, fullPage: false, owner: owner, close: {}).defaultAppStorage(defaults)
        try await waitFor(web, "document.body.classList.contains('sidebar')")
        try await toolbarCursor(fixture: fixture, web: web)
        _ = try await web.callAsyncJavaScript("""
            const update=window.perchUpdate;
            window.perchUpdate=state=>{window.fixtureState=state;update({...state,busy:window.fixtureBusy ?? state.busy})};
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        web.controller?.update()
        try await waitFor(web, "!!window.fixtureState")
        _ = try await web.callAsyncJavaScript("window.fixtureBusy=true;window.perchUpdate(window.fixtureState);",
                                             arguments: [:], in: nil, contentWorld: .defaultClient)
        try await waitFor(web, "!document.getElementById('stop').hidden")
        try await toolbarCursor(fixture: fixture, web: web)
        _ = try await web.callAsyncJavaScript("delete window.fixtureBusy;", arguments: [:], in: nil, contentWorld: .defaultClient)
        web.controller?.update()
        host.rootView = AIChatSidebar(store: store, ai: ai, fullPage: true, owner: owner, close: {}).defaultAppStorage(defaults)
        try await waitFor(web, "!document.body.classList.contains('sidebar') && document.getElementById('stop').hidden")
        print("PASS: shared sidebar toolbar and synthetic generating-state stop control restore arrow")
        web.configuration.userContentController.addUserScript(WKUserScript(source: """
            if(window===top)window.addEventListener('message',e=>{if(e.data?.fixtureSandbox)window.fixtureSandbox=e.data});
            else window.webkit?.messageHandlers?.perchInternal?.postMessage({
                action:'draft',owner:'\(owner)',conversation:'\(original.id)',text:'child-frame-forgery',revision:999999});
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        web.controller?.webViewWebContentProcessDidTerminate(web)
        _ = try await ready(panel)
        try await waitFor(web, "document.querySelectorAll('.file').length===2 && !!document.querySelector('.mermaid-diagram')")
        try await waitFor(web, "window.fixtureSandbox?.parentBlocked===true && window.fixtureSandbox?.bridge===false")
        guard ai.drafts[owner] == "保留草稿" else { throw PerchError("Child frame changed the host draft") }
        try await check(web, "!document.body.dataset.escaped", "文件预览越过沙箱")
        try await check(web, "!document.querySelector('.reasoning-text').parentElement.open", "历史思考区应默认折叠")
        _ = try await web.evaluateJavaScript("document.querySelector('.reasoning-text').previousElementSibling.scrollIntoView({block:'center'})")
        try await fixture.click(".message:first-of-type details:has(.reasoning-text) summary", web: web)
        try await check(web, "document.querySelector('.reasoning-text').parentElement.open && document.querySelector('.reasoning-text').clientHeight<=220",
                        "原生点击未展开有界思考区")
        _ = try await web.callAsyncJavaScript("""
            window.reasoningFixture=document.querySelector('.reasoning-text');
            const range=document.createRange();range.setStart(reasoningFixture.firstChild,0);range.setEnd(reasoningFixture.firstChild,6);
            getSelection().removeAllRanges();getSelection().addRange(range);
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        ai.drafts[owner] = "保留草稿并刷新"
        try await waitFor(web, "document.getElementById('composer').value==='保留草稿并刷新'")
        try await check(web, "reasoningFixture===document.querySelector('.reasoning-text') && reasoningFixture.parentElement.open && getSelection().toString()==='合成思考步骤'",
                        "草稿刷新丢失思考展开状态或选区")
        _ = try await web.evaluateJavaScript("getSelection().removeAllRanges()")
        try await fixture.click(".message:first-of-type details:has(.reasoning-text) summary", web: web)
        try await check(web, "!document.querySelector('.reasoning-text').parentElement.open", "思考区无法再次折叠")
        print("PASS: native reasoning disclosure retains its bounded height, manual state and selected text across draft updates")
        try await click("显示变更", within: ".message:last-of-type .file", fixture: fixture, web: web)
        try await waitFor(web, "document.querySelector('.file-diff')?.textContent.includes('New fixture')")
        _ = try await web.evaluateJavaScript("""
            const select=document.querySelector('[aria-label="文件版本"]');
            select.selectedIndex=0;select.dispatchEvent(new Event('change',{bubbles:true}));
            """)
        try await check(web, "document.querySelector('.message:last-of-type .file pre')?.textContent.includes('Old fixture')",
                        "历史文件版本未切换")
        _ = try await web.evaluateJavaScript("document.querySelector('.mermaid-diagram').scrollIntoView({block:'start'})")
        try await fixture.click(".mermaid-diagram [data-action='mode']", web: web)
        try await check(web, "!document.querySelector('.diagram-source').hidden", "图表源码开关未命中")
        try await click("复制源码", within: ".diagram-source", fixture: fixture, web: web)
        guard NSPasteboard.general.string(forType: .string)?.contains("A --> B") == true else { throw PerchError("Diagram copy missed bridge") }
        _ = try await web.evaluateJavaScript("document.querySelector('.followup').scrollIntoView({block:'center'})")
        try await check(web, """
            (()=>{const row=document.querySelector('.followup'),buttons=row.querySelectorAll('button'),
                send=buttons[0].getBoundingClientRect(),add=buttons[1].getBoundingClientRect();
                return buttons.length===2 && buttons[0].querySelector('svg') && buttons[1].querySelector('svg') &&
                    send.right<=add.left && add.width===26 && add.height===26 &&
                    buttons[0].title==='直接发送' && buttons[1].title==='添加到对话';})()
            """, "推荐问题缺少独立的发送箭头和添加到对话按钮")
        for selector in [".followup-send svg", ".followup>button.icon-button"] {
            fixture.mouse(.mouseMoved, at: try await fixture.point(selector, web: web))
            try await waitFor(web, """
                (()=>{const target=document.querySelector(selector),button=target.closest('button'),
                    icon=button.querySelector('.icon-button') || button,style=getComputedStyle(icon,'::before');
                    return button.classList.contains('hovered') && style.top==='3px' &&
                        style.backgroundColor!=='rgba(0, 0, 0, 0)';})()
                """, arguments: ["selector": selector])
        }
        print("PASS: both recommendation controls show inset highlights through native pointer events")
        if let path = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"] {
            let image = try await web.takeSnapshot(configuration: nil)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: path).appendingPathComponent("followup-controls.png"))
            }
        }
        try await fixture.click("[aria-label='添加到对话：继续解释']", web: web)
        try await AISelfCheck.wait { ai.drafts[owner]?.contains("继续解释") == true }
        guard ai.sessions[owner]?.requestID == nil else { throw PerchError("Fill followup sent a request") }
        print("PASS: native table sort/copy, code/diagram copy, file versions/diff, sandbox and child-frame bridge rejection, followup fill")

        ai.archiveConversations([original.id])
        try await waitFor(web, "document.getElementById('composer').readOnly && !document.getElementById('archive').hidden")
        try await fixture.click("#restore", web: web)
        try await AISelfCheck.wait { ai.sessions[owner]?.isArchived != true }
        let draft = ai.drafts[owner]
        web.controller?.webViewWebContentProcessDidTerminate(web)
        _ = try await ready(fixture.panel)
        try await waitFor(web, "document.getElementById('composer').value===draft", arguments: ["draft": draft ?? ""])
        print("PASS: archive read-only/restore, oversized draft rejection and WebKit process recovery retain controller state")

        ai.drafts[owner] = "独立未发送草稿"
        try await waitFor(web, "document.getElementById('composer').value==='独立未发送草稿'")
        _ = try await web.evaluateJavaScript("document.querySelector('.followup').scrollIntoView({block:'center'})")
        try await fixture.click(".followup-send svg", web: web)
        try await AISelfCheck.wait { ai.sessions[owner]?.messages.contains(where: { $0.role == "user" && $0.text == "继续解释" }) == true }
        try await AISelfCheck.wait { ai.sessions[owner]?.requestID == nil }
        guard ai.drafts[owner] == "独立未发送草稿" else { throw PerchError("Direct followup send consumed independent draft") }
        print("PASS: native recommendation arrow directly sends while retaining an independent composer draft")

        let clarificationOwner = ai.resumeConversation(clarification.id, tab: owner)
        host.rootView = AIChatSidebar(store: store, ai: ai, fullPage: true, owner: clarificationOwner, close: {}).defaultAppStorage(defaults)
        try await waitFor(web, "!!document.querySelector('.clarification input[type=radio]')")
        try await check(web, "document.querySelector('.clarification>button').disabled", "未回答问题不能提交")
        try await fixture.click(".clarification input[type=radio]", web: web)
        try await check(web, "document.querySelector('.clarification input[type=text]').value==='简短' && !document.querySelector('.clarification>button').disabled",
                        "澄清选项未填入答案")
        try await fixture.click(".clarification input[type=text]", web: web)
        _ = try await web.evaluateJavaScript("document.querySelector('.clarification input[type=text]').select()")
        guard let editor = panel.firstResponder as? NSTextInputClient else { throw PerchError("Clarification input lost native focus") }
        editor.insertText("详细说明", replacementRange: NSRange(location: NSNotFound, length: 0))
        ai.drafts[clarificationOwner] = "保持独立草稿"
        try await waitFor(web, "document.getElementById('composer').value==='保持独立草稿'")
        try await check(web, "document.querySelector('.clarification input[type=text]').value==='详细说明'", "刷新丢失澄清答案")
        try await click("提交并继续", within: ".clarification", fixture: fixture, web: web)
        try await AISelfCheck.wait { ai.sessions[clarificationOwner]?.messages.first?.clarification?.answers == ["详细说明"] }
        guard ai.drafts[clarificationOwner] == "保持独立草稿" else { throw PerchError("Clarification consumed unrelated composer draft") }
        try await AISelfCheck.wait { ai.sessions[clarificationOwner]?.requestID == nil }
        print("PASS: native clarification choices/custom text/submit preserve answers across refresh and retain an unrelated draft")
    }
}
