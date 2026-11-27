import AppKit
import SwiftUI
import WebKit

@MainActor
enum HistoryPageSelfCheck {
    static func data() throws {
        precondition(URLInput.parseNavigation(" PERCH://history/ ", search: false) == HistoryPage.url)
        precondition(URLInput.parse("perch://history", search: false) == nil)
        for address in ["perch://history.evil", "perch://history/path", "perch://history?x=1",
                        "perch://history#x", "perch://user@history", "perch://history:80", "https://history"] {
            precondition(!HistoryPage.matches(URL(string: address)))
        }
        let suite = "dev.perch.history.data.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        store.recordVisit(title: "fixture", address: "https://fixture.invalid/")
        store.recordVisit(title: "internal", address: HistoryPage.url.absoluteString)
        precondition(store.history.count == 1)
        var settings = store.settings; settings.historyRecordingEnabled = false
        try store.saveSettings(settings)
        store.recordVisit(title: "paused", address: "https://fixture.invalid/paused")
        let restored = Store(defaults: defaults)
        precondition(!restored.settings.historyRecordingEnabled && restored.history.count == 1)
        store.deleteHistory(ids: [store.history[0].id, UUID()])
        precondition(Store(defaults: defaults).history.isEmpty)
        var group = TabGroup(name: "History")
        var tab = Tab(title: "历史记录", address: HistoryPage.url.absoluteString)
        tab.groupID = group.id; group.hiddenTabs = [tab]
        try TabGroup.validateStoredTabs([group])
        print("PASS: history route boundaries, persistence, pause without clearing and internal-tab compatibility")
    }

    static func ui() async throws {
        setbuf(stdout, nil)
        SelfTests.prepareAccessibility()
        let suite = "dev.perch.history.ui.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let store = Store(defaults: defaults)
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let first = Visit(title: "Needle · 页面一", address: "http://127.0.0.1:9/one", date: today.addingTimeInterval(120))
        let second = Visit(title: "页面二", address: "http://127.0.0.1:9/NEEDLE", date: yesterday)
        let third = Visit(title: "<img src=x onerror=alert(1)>", address: "http://127.0.0.1:9/three",
                          date: yesterday.addingTimeInterval(-86400))
        store.mergeHistory([second, third, first])
        let bookmarks = store.sites.map(\.id)
        store.newTab()
        store.navigate("perch://history")
        let owner = store.selected!
        let panel = Panel(contentRect: NSRect(x: 120, y: 120, width: 1040, height: 760),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close(); defaults.removePersistentDomain(forName: suite) }
        panel.contentView = RootHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        panel.bindTabFocus(to: store)
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let fixture = HomePageFixture(store: store, panel: panel)
        let web = store.browser!.webView
        func wait(_ expression: String, line: UInt = #line) async throws {
            do { try await AIChatPageSelfCheck.waitFor(web, expression, line: line) }
            catch {
                let state = try? await web.evaluateJavaScript("""
                    JSON.stringify({url:location.href,query:document.getElementById('search')?.value,
                    selected:[...document.querySelectorAll('.row.selected')].map(e=>e.dataset.id),
                    rows:document.querySelectorAll('.row').length})
                    """)
                let saved = Mirror(reflecting: store.browser!.historyPage).children.first { $0.label == "viewState" }?.value
                throw PerchError("\(error.localizedDescription); DOM=\(state ?? "nil"); saved=\(String(describing: saved))")
            }
        }
        func check(_ expression: String, _ message: String) async throws {
            try await AIChatPageSelfCheck.check(web, expression, message)
        }
        func type(_ text: String) async throws {
            try await fixture.click("#search", web: web)
            _ = try await web.evaluateJavaScript("document.getElementById('search').select()")
            guard let input = panel.firstResponder as? NSTextInputClient else { throw PerchError("History search has no native input client") }
            input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await AIChatPageSelfCheck.waitFor(web, "document.getElementById('search').value===value", arguments: ["value": text])
        }
        try await AISelfCheck.wait { web.url == HistoryPage.url && !web.isLoading && web.window === panel }
        try await wait("document.querySelectorAll('.row').length===3")
        let originalSize = panel.frame.size
        for width in [1040.0, 720.0] {
            panel.setContentSize(NSSize(width: width, height: 760))
            panel.contentView?.layoutSubtreeIfNeeded()
            try await wait("""
                (()=>{const all=document.getElementById('select-all').getBoundingClientRect();
                    return [...document.querySelectorAll('.select input')].every(input=>{
                        const row=input.getBoundingClientRect();
                        return Math.abs(all.x+all.width/2-row.x-row.width/2)<.5;
                    });})()
                """)
        }
        panel.setFrame(NSRect(origin: panel.frame.origin, size: originalSize), display: true)
        print("PASS: history selection checkboxes align at wide and narrow viewport widths")
        try await check("document.querySelectorAll('.day').length===3 && document.querySelector('.day h2').textContent.startsWith('今天')",
                        "History should group visits by local calendar date")
        try await check("document.querySelector('.row .title').textContent==='Needle · 页面一' && !document.querySelector('.row img')",
                        "History should sort visits descending and render titles as plain text")
        let pageBridge = try await web.evaluateJavaScript("!!window.webkit?.messageHandlers?.perchHistory") as? Bool
        precondition(pageBridge == false && store.history.count == 3)
        store.openHistory()
        precondition(store.tabs.count == 1 && store.selected == owner)
        let restored = Store(defaults: defaults)
        precondition(restored.tabs.contains { HistoryPage.matches(URL(string: $0.address)) })
        let image = try await web.takeSnapshot(configuration: nil)
        if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/perch-history-preview.png"))
        }
        print("PASS: history HTML timeline, local dates, escaping, tab reuse/restoration and page-world bridge isolation")

        try await type("needle")
        try await check("""
            getComputedStyle(document.querySelector('.search')).outlineStyle==='none' &&
            getComputedStyle(document.getElementById('search')).outlineStyle==='none'
            """, "Focused history search must not draw an outer focus ring")
        try await wait("document.querySelectorAll('.row').length===2")
        try await fixture.click(".row .select", web: web)
        try await wait("document.querySelectorAll('.row.selected').length===1")
        let selectedID = try await web.evaluateJavaScript("document.querySelector('.row.selected').dataset.id") as! String
        store.newTab(); store.activate(owner)
        try await check("document.getElementById('search').value==='needle' && document.querySelectorAll('.row.selected').length===1",
                        "Tab switching must retain history search and selection")
        store.navigate("perch://downloads")
        try await AISelfCheck.wait { web.url == DownloadsPage.url && !web.isLoading }
        _ = try await web.callAsyncJavaScript("""
            window.webkit.messageHandlers.perchHistory.postMessage({action:'delete',ids:[id]});
            """, arguments: ["id": selectedID], in: nil, contentWorld: .defaultClient)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(store.history.count == 3, "Other internal pages must not use the history bridge")
        store.browser!.goBack()
        try await AISelfCheck.wait { web.url == HistoryPage.url && !web.isLoading }
        try await wait("document.getElementById('search').value==='needle' && document.querySelectorAll('.row.selected').length===1")
        try await fixture.click("#select-all", web: web)
        try await wait("document.querySelectorAll('.row.selected').length===2")
        try await fixture.click("#delete", web: web)
        try await wait("document.getElementById('confirmation').open")
        try await fixture.click("#cancel-delete", web: web)
        precondition(store.history.count == 3)
        try await fixture.click("#delete", web: web)
        try await fixture.click("#confirm-delete", web: web)
        try await AISelfCheck.wait { store.history.count == 1 }
        precondition(store.history[0].id == third.id && store.sites.map(\.id) == bookmarks)
        try await wait("!document.getElementById('empty').hidden")
        print("PASS: native search input, checkbox hit areas, selection retention, back navigation, cross-page rejection and confirmed filtered deletion")

        try await fixture.click("#recording", web: web)
        try await AISelfCheck.wait { !store.settings.historyRecordingEnabled }
        store.recordVisit(title: "Should not record", address: "http://127.0.0.1:9/paused")
        precondition(store.history.count == 1 && !Store(defaults: defaults).settings.historyRecordingEnabled)
        try await wait("!document.getElementById('paused').hidden")
        try await fixture.click("#recording", web: web)
        try await AISelfCheck.wait { store.settings.historyRecordingEnabled }
        store.recordVisit(title: "Needle new", address: "http://127.0.0.1:9/new")
        try await wait("document.querySelectorAll('.row').length===1")
        try await check("document.getElementById('search').value==='needle'", "Live updates cleared the query")
        try await type("")
        store.mergeHistory((0..<105).map {
            Visit(title: "Batch \($0)", address: "http://127.0.0.1:9/batch/\($0)", date: today.addingTimeInterval(Double(-$0-864000)))
        })
        try await wait("document.querySelectorAll('.row').length===100 && !document.getElementById('more').hidden")
        try await fixture.click("#more", web: web)
        try await wait("document.querySelectorAll('.row').length===107")
        let scrolled = try await web.evaluateJavaScript("scrollY") as! Double
        precondition(scrolled > 0)
        store.newTab(); store.activate(owner)
        try await AIChatPageSelfCheck.check(web, "Math.abs(scrollY-expected)<2", "History scroll position changed",
                                           arguments: ["expected": scrolled])
        try await type("batch")
        try await fixture.click("#select-all", web: web)
        try await check("document.getElementById('count').textContent==='已选择 105 条'", "Select-all omitted unloaded results")
        try await fixture.click("#delete", web: web)
        try await fixture.click("#confirm-delete", web: web)
        try await AISelfCheck.wait { store.history.count == 2 }
        try await type("")
        try await fixture.click("#clear", web: web)
        try await fixture.click("#confirm-delete", web: web)
        try await AISelfCheck.wait { store.history.isEmpty }
        try await wait("!document.getElementById('empty').hidden && document.getElementById('clear').disabled")
        precondition(Store(defaults: defaults).history.isEmpty)
        store.applyHotkeys = { _ in throw PerchError("Synthetic settings failure") }
        try await fixture.click("#recording", web: web)
        try await wait("!document.getElementById('error').hidden && document.getElementById('recording').checked")
        precondition(store.settings.historyRecordingEnabled)
        store.applyHotkeys = nil
        store.mergeHistory([first])
        try await wait("document.querySelectorAll('.row').length===1")
        let count = store.tabs.count
        try await fixture.click(".row .visit", web: web)
        try await AISelfCheck.wait { store.tabs.count == count + 1 && store.selected != owner }
        precondition(store.tabs.first { $0.id == store.selected }?.address == first.address)
        print("PASS: native pause/resume, persisted preference, live updates, incremental rendering, scroll retention and complete-result batch deletion")
        print("PASS: failed settings restore the original toggle and record clicks open a new tab")
    }
}
