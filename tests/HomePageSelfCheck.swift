import AppKit
import SwiftUI
import WebKit

@MainActor
struct HomePageFixture {
    let store: Store
    let panel: Panel
    func home(line: UInt = #line) async throws -> HomePageWebView {
        func find(_ view: NSView) -> HomePageWebView? {
            if let web = view as? HomePageWebView,
               web.controller?.tabID == (store.selected ?? AIController.homeID),
               web.window === panel, !web.isHiddenOrHasHiddenAncestor { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        for _ in 0..<100 {
            if let web = panel.contentView.flatMap(find), web.title == "新标签页", !web.isLoading,
               web.controller?.tabID == (store.selected ?? AIController.homeID) {
                let ready = try? await web.callAsyncJavaScript("""
                    return document.documentElement.dataset.owner===owner &&
                        JSON.stringify([...document.querySelectorAll('#shortcuts .shortcut')].map(e=>e.dataset.id))===JSON.stringify(ids);
                    """, arguments: ["owner": (store.selected ?? AIController.homeID).uuidString,
                                    "ids": store.homeShortcuts.map { $0.id.uuidString }], in: nil, contentWorld: .defaultClient)
                if ready as? Bool == true, web.window === panel, web.bounds.width > 0 { return web }
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let web = panel.contentView.flatMap(find)
        let state = try? await web?.evaluateJavaScript("""
            JSON.stringify({owner:document.documentElement.dataset.owner,ids:[...document.querySelectorAll('#shortcuts .shortcut')].map(e=>e.dataset.id)})
            """)
        throw PerchError("HTML homepage did not finish loading at \(line): selected=\(String(describing: store.selected)), web=\(String(describing: web)), state=\(String(describing: state)), expected=\(store.homeShortcuts.map(\.id))")
    }
    func point(_ selector: String, web: WKWebView) async throws -> NSPoint {
        let result = try await web.callAsyncJavaScript("""
            const element=document.querySelector(selector);
            if(!element)throw new Error('Missing target: '+selector);
            const rect=element.getBoundingClientRect();
            return {x:rect.x+rect.width/2,y:rect.y+rect.height/2};
            """, arguments: ["selector": selector], in: nil, contentWorld: .defaultClient)
        guard let value = result as? [String: Double], let x = value["x"], let y = value["y"] else {
            throw PerchError("HTML target has no coordinates")
        }
        return web.convert(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height-y), to: nil)
    }
    func mouse(_ type: NSEvent.EventType, at point: NSPoint) {
        NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
    }
    func click(_ selector: String, web: WKWebView) async throws {
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        panel.focusWindow()
        try await AISelfCheck.wait { NSApp.isActive && panel.isKeyWindow }
        let location = try await point(selector, web: web)
        let root = panel.contentView!
        let hit = root.hitTest(root.superview?.convert(location, from: nil) ?? location)
        guard hit === web || hit?.isDescendant(of: web) == true else {
            throw PerchError("Home click missed WebKit: \(selector), point=\(location), hit=\(String(describing: hit))")
        }
        mouse(.leftMouseDown, at: location)
        try await Task.sleep(nanoseconds: 40_000_000)
        mouse(.leftMouseUp, at: location)
        try await Task.sleep(nanoseconds: 120_000_000)
    }
    func type(_ text: String, web: HomePageWebView) async throws {
        try await click("#search", web: web)
        _ = try await web.evaluateJavaScript("document.getElementById('search').select()")
        guard let editor = panel.firstResponder as? NSTextInputClient else {
            throw PerchError("HTML search did not become the native text input client: \(String(describing: panel.firstResponder))")
        }
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 120_000_000)
        let value = try await web.evaluateJavaScript("document.getElementById('search').value") as? String
        guard value == text else { throw PerchError("Native WebKit insertion differs: \(value ?? "nil")") }
    }
    func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
        }
        try await Task.sleep(nanoseconds: 120_000_000)
    }
    func toolbar() -> NSTextField {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? AddressTextField.Field, field.identifier?.rawValue == "toolbarAddress",
               field.ownerTab == store.selected, field.window === panel, !field.isHiddenOrHasHiddenAncestor { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(panel.contentView!)!
    }
}

@MainActor
enum HomePageSelfCheck {
    static func state() async throws {
        let suite = "dev.perch.home-state-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = Store(defaults: defaults)
        let panel = Panel(contentRect: NSRect(x: 150, y: 150, width: 850, height: 660),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close(); defaults.removePersistentDomain(forName: suite) }
        store.sites = (0..<30).map { Site(title: "Home state \($0)", address: "http://127.0.0.1:9/home-state-\($0)") }
        store.newTab()
        panel.contentView = RootHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        panel.bindTabFocus(to: store)
        panel.orderFront(nil)
        let fixture = HomePageFixture(store: store, panel: panel)
        let empty = try await fixture.home()
        store.newTab()
        let reused = try await fixture.home()
        guard reused === empty else { throw PerchError("Pristine homepage did not reuse its WebView") }
        store.sites.append(Site(title: "Updated fixture", address: "http://127.0.0.1:9/updated"))
        _ = try await fixture.home()
        let owner = store.selected!
        // Synthetic DOM state exercises retention without claiming native keyboard or mouse coverage.
        _ = try await reused.evaluateJavaScript("""
            window.homeStateFixture='retained';
            const input=document.getElementById('search');
            input.value='首页状态 fixture';input.dispatchEvent(new Event('input',{bubbles:true}));
            input.setSelectionRange(2,4);window.scrollTo(0,180);
            """)
        try await AISelfCheck.wait {
            store.homeAddressDrafts[owner]?[false] == "首页状态 fixture" && reused.controller?.pristine == false
        }
        let scroll = try await reused.evaluateJavaScript("scrollY") as? Double ?? 0
        guard scroll > 0 else { throw PerchError("Home state fixture did not scroll") }
        store.newTab()
        let other = try await fixture.home()
        guard other !== reused else { throw PerchError("Stateful homepage was reused by another tab") }
        store.activate(owner)
        let returned = try await fixture.home()
        let retained = try await returned.callAsyncJavaScript("""
            const input=document.getElementById('search');
            return window.homeStateFixture==='retained' && input.value==='首页状态 fixture' &&
                input.selectionStart===2 && input.selectionEnd===4 && Math.abs(scrollY-scroll)<1;
            """, arguments: ["scroll": scroll], in: nil, contentWorld: .page) as? Bool
        guard returned === reused, retained == true else { throw PerchError("Homepage DOM, draft, selection or scroll did not survive switching") }
        let exposed = try await returned.evaluateJavaScript("!!window.webkit?.messageHandlers?.perchInternal") as? Bool
        guard exposed == false else { throw PerchError("Homepage page world exposes the host bridge") }
        print("PASS: pristine home reuse refreshes owner and sites; stateful homes retain DOM, draft, selection and scroll; host bridge stays isolated")
    }
    static func focus(store: Store, panel: Panel, table: NSView) async throws {
        let fixture = HomePageFixture(store: store, panel: panel)
        let selected = store.selected!
        guard let other = store.tabs.first(where: { $0.id != selected })?.id else { throw PerchError("Home focus fixture needs two tabs") }
        for throughTable in [true,false] {
            let web = try await fixture.home()
            try await fixture.type("首页草稿 fixture", web: web)
            _ = try await web.evaluateJavaScript("document.getElementById('search').setSelectionRange(2,3)")
            if throughTable { panel.makeFirstResponder(table) }
            store.activate(other)
            let otherWeb = try await fixture.home()
            let otherText = try await otherWeb.evaluateJavaScript("document.getElementById('search').value") as? String
            guard otherText != "首页草稿 fixture" else { throw PerchError("Home draft leaked across tabs") }
            if throughTable { panel.makeFirstResponder(table) }
            store.activate(selected)
            let returned = try await fixture.home()
            try await Task.sleep(nanoseconds: 200_000_000)
            let retained = try await returned.callAsyncJavaScript("""
                const input=document.getElementById('search');
                return document.activeElement===input && input.value==='首页草稿 fixture' && input.selectionStart===2 && input.selectionEnd===3;
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
            guard returned === web, retained == true else { throw PerchError("Home DOM, focus or selection did not survive tab switching") }
            let field = fixture.toolbar(); panel.makeFirstResponder(field)
            let editor = field.currentEditor() as! NSTextView
            editor.selectAll(nil); editor.insertText("地址草稿 fixture", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.setSelectedRange(NSRange(location: 2,length: 1))
            if throughTable { panel.makeFirstResponder(table) }
            store.activate(other)
            try await Task.sleep(nanoseconds: 200_000_000)
            if throughTable { panel.makeFirstResponder(table) }
            store.activate(selected)
            _ = try await fixture.home()
            try await Task.sleep(nanoseconds: 200_000_000)
            guard fixture.toolbar().currentEditor() === panel.firstResponder,
                  (panel.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 2,length: 1),
                  fixture.toolbar().stringValue == "地址草稿 fixture" else {
                throw PerchError("Native toolbar focus or selection did not survive switching: table=\(throughTable), responder=\(String(describing: panel.firstResponder)), editor=\(String(describing: fixture.toolbar().currentEditor())), text=\(fixture.toolbar().stringValue), selection=\(String(describing: (panel.firstResponder as? NSTextView)?.selectedRange()))")
            }
        }
        print("PASS: HTML search/native address drafts, focus and selection survive direct and table tab switches without leaking")
    }
    static func input(store: Store, panel: Panel) async throws {
        let savedSites = store.sites
        defer { store.sites = savedSites }
        store.newTab()
        store.sites = (0..<8).map { Site(title:"Home fixture \($0)",address:"http://127.0.0.1:9/suggestion-\($0)") }
        let fixture = HomePageFixture(store: store,panel: panel), web = try await fixture.home()
        try await fixture.type("输入法 fixture",web: web)
        guard let client = panel.firstResponder as? NSTextInputClient else { throw PerchError("Search text input client missing") }
        client.setMarkedText("ni", selectedRange: NSRange(location: 2,length: 0), replacementRange: NSRange(location: NSNotFound,length: 0))
        let sites = store.sites; store.sites = sites
        try await Task.sleep(nanoseconds: 100_000_000)
        guard client.hasMarkedText() else { throw PerchError("Store refresh discarded the native WebKit composition") }
        let before = store.homeAddressDrafts[store.selected!]?[false]
        try await fixture.key(36,"\r")
        guard store.browser == nil, store.homeAddressDrafts[store.selected!]?[false] == before else {
            throw PerchError("Composition Return submitted or published uncommitted input")
        }
        if client.hasMarkedText() { client.insertText("你",replacementRange:NSRange(location:NSNotFound,length:0)) }
        try await fixture.type("Home fixture",web: web)
        try await Task.sleep(nanoseconds: 200_000_000)
        let count = try await web.evaluateJavaScript("document.querySelectorAll('#suggestions button').length") as? Int ?? 0
        guard count > 0 else { throw PerchError("HTML search did not receive bookmark suggestions") }
        try await fixture.key(125,"\u{f701}")
        let selected = try await web.evaluateJavaScript("document.getElementById('search').getAttribute('aria-activedescendant')") as? String
        guard selected == "suggestion-0" else { throw PerchError("HTML suggestion arrow key did not select its first result") }
        try await fixture.key(53,"\u{1b}")
        let hidden = try await web.evaluateJavaScript("document.getElementById('suggestions').hidden") as? Bool
        guard hidden == true else { throw PerchError("Escape did not dismiss the HTML suggestions") }
        try await fixture.type("Home fixture",web: web)
        try await Task.sleep(nanoseconds: 200_000_000)
        try await fixture.click("#suggestion-3",web:web)
        guard store.tabs.first(where:{$0.id==store.selected})?.address.contains("/suggestion-3") == true else {
            throw PerchError("HTML suggestion did not receive its actual click above the homepage content")
        }
        store.newTab()
        print("PASS: native WebKit composition Return guard, committed drafts, shared bookmark suggestions and arrow/Escape event paths")
    }
    static func drag(store: Store, panel: Panel) async throws {
        store.library = nil; store.newTab()
        store.sites = (0..<6).map { Site(title: "Home fixture \($0)", address: "http://127.0.0.1:9/home-\($0)") }
        let data = try JSONEncoder().encode(store.sites)
        store.defaults.set(data, forKey: "sites")
        let fixture = HomePageFixture(store: store, panel: panel), web = try await fixture.home()
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        panel.focusWindow()
        try await AISelfCheck.wait { NSApp.isActive && panel.isKeyWindow }
        let ids = store.homeShortcuts.map(\.id)
        let start = try await fixture.point(".shortcut", web: web)
        let target = try await fixture.point(".shortcut:nth-child(4)", web: web)
        fixture.mouse(.leftMouseDown, at: start)
        try await Task.sleep(nanoseconds: 50_000_000)
        fixture.mouse(.leftMouseDragged, at: target)
        try await Task.sleep(nanoseconds: 250_000_000)
        let preview = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('#shortcuts .shortcut')).map(e=>e.dataset.id)") as? [String]
        let expected = [ids[1],ids[2],ids[3],ids[0],ids[4],ids[5]]
        guard preview == expected.map(\.uuidString), store.homeShortcutOrder.isEmpty else {
            throw PerchError("HTML drag did not preview across rows without saving: \(String(describing: preview))")
        }
        let ghost = try await web.evaluateJavaScript("""
            getComputedStyle(document.querySelector('.drag-ghost')).opacity==='0.88' &&
                getComputedStyle(document.querySelector('.drag-source')).opacity==='0'
            """) as? Bool
        guard ghost == true else { throw PerchError("HTML drag did not leave an empty slot and translucent card") }
        fixture.mouse(.leftMouseUp, at: target)
        try await Task.sleep(nanoseconds: 250_000_000)
        guard store.homeShortcuts.map(\.id) == expected, store.browser == nil,
              store.defaults.data(forKey: "sites") == data else { throw PerchError("HTML drop changed bookmark bytes or opened a tab") }
        let saved = store.defaults.data(forKey: "homeShortcutOrder")
        let moved = try await fixture.point(".shortcut:nth-child(4)", web: web)
        let first = try await fixture.point(".shortcut", web: web)
        fixture.mouse(.leftMouseDown, at: moved)
        try await Task.sleep(nanoseconds: 40_000_000)
        fixture.mouse(.leftMouseDragged, at: first)
        try await Task.sleep(nanoseconds: 80_000_000)
        try await fixture.key(53,"\u{1b}")
        fixture.mouse(.leftMouseUp, at: first)
        try await Task.sleep(nanoseconds: 250_000_000)
        let restored = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('#shortcuts .shortcut')).map(e=>e.dataset.id)") as? [String]
        guard restored == expected.map(\.uuidString), store.defaults.data(forKey: "homeShortcutOrder") == saved,
              store.browser == nil else { throw PerchError("Escape did not restore the HTML drag preview") }
        fixture.mouse(.leftMouseDown, at: moved)
        try await Task.sleep(nanoseconds: 40_000_000)
        fixture.mouse(.leftMouseDragged, at: first)
        try await Task.sleep(nanoseconds: 80_000_000)
        let outside = web.convert(NSPoint(x: 8, y: 8), to: nil)
        fixture.mouse(.leftMouseDragged, at: outside)
        try await Task.sleep(nanoseconds: 80_000_000)
        fixture.mouse(.leftMouseUp, at: outside)
        try await Task.sleep(nanoseconds: 250_000_000)
        guard store.defaults.data(forKey: "homeShortcutOrder") == saved, store.browser == nil else {
            throw PerchError("Outside HTML drop saved an order or opened a page")
        }
        let homeID = store.selected!
        try await fixture.click(".shortcut", web: web)
        guard store.selected == homeID, store.cachedBrowser(for: homeID) != nil else { throw PerchError("HTML shortcut click did not navigate its home tab") }
        store.newTab()
        print("PASS: actual HTML pointer drag across rows, independent order commit, bookmark preservation, Escape rollback and shortcut click")
    }
    static func navigation(store: Store, panel: Panel, baseURL: String) async throws {
        guard URL(string: baseURL)?.host == "127.0.0.1" else { throw PerchError("Home fixture must use loopback") }
        let fixture = HomePageFixture(store: store, panel: panel), id = store.selected!
        store.settings.searchEngine = "custom"; store.settings.customSearchURL = baseURL + "/nav/a?q={query}"
        let original = try await fixture.home()
        let bridge = try await original.evaluateJavaScript("!!window.webkit?.messageHandlers?.perchInternal") as? Bool
        guard bridge == false else { throw PerchError("Homepage page world exposes the host bridge") }
        for home in [true,false] {
            let draft = home ? "  " + baseURL + "/nav/a  " : "  合成 搜索词  "
            if home { try await fixture.type(draft, web: original) }
            else {
                let field = fixture.toolbar(); panel.makeFirstResponder(field)
                let editor = field.currentEditor() as! NSTextView
                editor.selectAll(nil); editor.insertText(draft, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            try await fixture.key(36,"\r")
            try await AISelfCheck.wait(timeout: 10) { store.browser?.webView.title == "a" && store.browser?.canGoBack == true }
            guard fixture.toolbar().currentEditor() == nil else { throw PerchError("Submitted home address stole focus") }
            store.browser!.goBack()
            try await AISelfCheck.wait(timeout: 10) { store.browser == nil }
            let returned = try await fixture.home()
            let text = home ? try await returned.evaluateJavaScript("document.getElementById('search').value") as? String : fixture.toolbar().stringValue
            guard returned === original, store.selected == id, text == draft else { throw PerchError("Back rebuilt the homepage or lost its input") }
            store.cachedBrowser(for: id)!.goForward()
            try await AISelfCheck.wait(timeout: 10) { store.browser?.webView.title == "a" }
            store.browser!.goBack()
            try await AISelfCheck.wait(timeout: 10) { store.browser == nil }
            _ = try await fixture.home()
        }
        store.sites = [Site(title: "首页合成书签", address: baseURL+"/nav/b")]
        _ = try await fixture.home()
        let count = store.tabs.count
        try await fixture.click(".shortcut", web: original)
        try await AISelfCheck.wait(timeout: 10) { store.browser?.webView.title == "b" }
        guard store.tabs.count == count, store.selected == id else { throw PerchError("Home bookmark created another tab") }
        store.browser!.goBack()
        try await AISelfCheck.wait(timeout: 10) { store.browser == nil }
        guard try await fixture.home() === original else { throw PerchError("Bookmark navigation rebuilt the home DOM") }
        print("PASS: HTML/native Return navigation, back/forward, retained home WebView, both drafts and actual shortcut click")
    }
}
