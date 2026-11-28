import AppKit
import SwiftUI
import WebKit

@MainActor
enum SettingsPageSelfCheck {
    static func routes() {
        for route in SettingsRoute.allCases {
            precondition(URLInput.parseNavigation(route.url.absoluteString, search: false) == route.url)
            precondition(URLInput.parse(route.url.absoluteString, search: false) == nil)
        }
        precondition(URLInput.parseNavigation(" PERCH://Settings/ ", search: false) == SettingsRoute.general.url)
        for invalid in ["https://settings/ai", "perch://settings.invalid/ai", "perch://settings/ai/extra",
                        "perch://settings/%61i", "perch://settings/ai?q=1", "perch://settings/ai#x",
                        "perch://user@settings/ai", "perch://settings:80/ai"] {
            precondition(SettingsRoute(URL(string: invalid)) == nil)
        }
        print("PASS: settings deep links are canonical and limited to bundled routes")
    }

    static func ui() async throws {
        let suite = "dev.perch.settings.ui.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let store = Store(defaults: defaults)
        let panel = Panel(contentRect: NSRect(x: 120, y: 120, width: 1040, height: 760),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close(); defaults.removePersistentDomain(forName: suite) }
        store.openSettings()
        let id = store.selected!
        let web = store.browser!.webView
        panel.contentView = RootHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        panel.bindTabFocus(to: store)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let fixture = HomePageFixture(store: store, panel: panel)
        try await AISelfCheck.wait { web.url == SettingsRoute.general.url && web.window === panel && !web.isLoading }
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('#showWindowOnLaunch')?.checked===false")
        _ = try await web.callAsyncJavaScript("window.settingsFixtureDocument = document.querySelector('#navigation')",
                                              arguments: [:], in: nil, contentWorld: .defaultClient)
        try await fixture.click("#showWindowOnLaunch", web: web)
        try await AISelfCheck.wait { store.settings.showWindowOnLaunch }
        try await fixture.click("a[href='perch://settings/ai']", web: web)
        try await AISelfCheck.wait { web.url == SettingsRoute.ai.url && !web.isLoading }
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('#aiSendWithCommand')?.value==='false'")
        try await AISelfCheck.wait { store.tabs.first?.address == SettingsRoute.ai.url.absoluteString }
        try await AIChatPageSelfCheck.check(web, """
            (() => {
                const duration=document.querySelector('#aiRevealDuration'), width=document.querySelector('#aiRevealWidth');
                return duration.min==='0' && duration.max==='1000' && duration.value==='400' &&
                    width.min==='0' && width.max==='1000' && width.value==='600';
            })()
            """, "AI animation sliders must show defaults and allow the full range")
        _ = try await web.callAsyncJavaScript("""
            for (const [id,value] of [['aiRevealDuration',0],['aiRevealWidth',1000]]) {
                const slider=document.getElementById(id);
                slider.value=value;
                slider.dispatchEvent(new Event('change'));
            }
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        try await AISelfCheck.wait { store.settings.aiRevealDuration == 0 && store.settings.aiRevealWidth == 1000 }
        let savedAnimation = Store(defaults: defaults).settings
        precondition(savedAnimation.aiRevealDuration == 0 && savedAnimation.aiRevealWidth == 1000)
        store.openSettings()
        precondition(store.selected == id && store.tabs.count == 1 && panel.attachedSheet == nil)
        // Attempt a valid bridge command from the wrong category.
        _ = try await web.callAsyncJavaScript("""
            webkit.messageHandlers.perchSettings.postMessage({action:'change',key:'showWindowOnLaunch',value:false});
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        store.browser?.goBack()
        try await AISelfCheck.wait { web.url == SettingsRoute.general.url && !web.isLoading }
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('#showWindowOnLaunch')?.checked===true")
        try await AISelfCheck.wait { store.tabs.first?.address == SettingsRoute.general.url.absoluteString }
        store.browser?.goForward()
        try await AISelfCheck.wait { store.tabs.first?.address == SettingsRoute.ai.url.absoluteString }
        store.browser?.goBack()
        try await AISelfCheck.wait { store.tabs.first?.address == SettingsRoute.general.url.absoluteString }
        precondition(Store(defaults: defaults).settings.showWindowOnLaunch && store.history.isEmpty)
        let bounds = """
            (()=>{const {left,width}=document.querySelector('#content').getBoundingClientRect();return [left,width];})()
            """
        let standardBounds = try await web.evaluateJavaScript(bounds) as? [Double]
        func script(_ source: String) async throws {
            _ = try await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .defaultClient)
        }
        func route(_ route: SettingsRoute, _ ready: String) async throws {
            store.openSettings(route)
            try await AISelfCheck.wait { web.url == route.url && !web.isLoading }
            try await AIChatPageSelfCheck.waitFor(web, ready)
            try await AIChatPageSelfCheck.check(web, """
                window.settingsFixtureDocument === document.querySelector('#navigation') &&
                getComputedStyle(document.documentElement).getPropertyValue('--settings-width').trim()==='900px' &&
                document.querySelector('style').textContent.includes('--perch-accent:'+accent) &&
                getComputedStyle(document.documentElement).backgroundColor===getComputedStyle(document.body).backgroundColor
                """, "Settings must share one themed document and a 900px maximum width (\(route.rawValue))",
                arguments: ["accent": store.settings.theme.webColors["accent"]!])
            precondition(store.selected == id && panel.attachedSheet == nil)
        }
        try await route(.appearance, "Boolean(document.querySelector('#chatFontSize'))")
        try await script("const x=document.querySelector('#chatFontSize'); x.value=18; x.dispatchEvent(new Event('change'));")
        try await AISelfCheck.wait { store.settings.chatFontSize == 18 }
        try await fixture.click("#reset-chat-font", web: web)
        try await AISelfCheck.wait { store.settings.chatFontSize == 13 }
        let preview = store.settings.theme == .pink ? ThemeColor.blue : .pink
        _ = try await web.callAsyncJavaScript("""
            webkit.messageHandlers.perchSettings.postMessage({action:'previewTheme',theme});
            """, arguments: ["theme": preview.rawValue], in: nil, contentWorld: .defaultClient)
        try await AISelfCheck.wait { PerchTheme.shared.selection == preview }
        try await route(.bookmarks, "Boolean(document.querySelector('#bookmark-list'))")
        let bookmarksBounds = try await web.evaluateJavaScript(bounds) as? [Double]
        precondition(bookmarksBounds != nil && bookmarksBounds == standardBounds)
        precondition(PerchTheme.shared.selection == store.settings.theme)
        try await script("""
            const send = body => webkit.messageHandlers.perchSettings.postMessage(body);
            send({action:'folder',title:'Fixture folder'});
            send({action:'save',title:'Fixture bookmark',address:'https://settings-fixture.invalid/'});
            """)
        try await AISelfCheck.wait { store.bookmarkFolders.contains { $0.title == "Fixture folder" } &&
            store.sites.contains { $0.title == "Fixture bookmark" } }
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('#bookmark-list')?.textContent.includes('Fixture bookmark')")
        let folder = store.bookmarkFolders.first { $0.title == "Fixture folder" }!
        precondition(store.add(title: "Nested fixture", address: "https://nested-fixture.invalid/", folderID: folder.id))
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('.bookmark-children[inert]')?.textContent.includes('Nested fixture')")
        try await AIChatPageSelfCheck.check(web, """
            document.querySelector('#bookmark-scope').getBoundingClientRect().right <
                document.querySelector('#bookmark-list').getBoundingClientRect().left
            """, "Bookmark categories must sit beside the list")
        try await script("""
            const selector='.bookmark-children';
            document.querySelector('.bookmark-disclosure').addEventListener('click',()=>{
                const branch=document.querySelector(selector), end=branch.firstElementChild.scrollHeight, start=performance.now();
                function sample(now){
                    const height=branch.getBoundingClientRect().height;
                    if(height>0 && height<end)document.body.dataset.sawFolderMotion='true';
                    if(now-start<260)requestAnimationFrame(sample);
                }
                requestAnimationFrame(sample);
            },{once:true});
            const bounds=()=>JSON.stringify([...document.querySelectorAll('#bookmark-scope,#bookmark-list,.bookmark-footer')].map(el=>{
                const r=el.getBoundingClientRect();return [r.x,r.y,r.width,r.height];
            }));
            document.body.dataset.bookmarkBounds=bounds();
            """)
        try await fixture.click(".bookmark-disclosure", web: web)
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('.bookmark-children[data-expanded]')?.textContent.includes('Nested fixture')")
        try await AIChatPageSelfCheck.waitFor(web, "matchMedia('(prefers-reduced-motion: reduce)').matches || document.body.dataset.sawFolderMotion==='true'")
        try await fixture.click(".bookmark-branch .bookmark-item-name", web: web)
        try await AIChatPageSelfCheck.waitFor(web, """
            document.querySelector('.bookmark-branch .bookmark-item-name')?.getAttribute('aria-pressed') === 'true'
            """)
        try await fixture.click(".bookmark-branch .bookmark-open", web: web)
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('.bookmark-heading').textContent.includes('Fixture folder')")
        try await AISelfCheck.wait { store.settingsBookmarkScope == "folder:" + folder.id.uuidString }
        try await fixture.click(".bookmark-on-home", web: web)
        try await AISelfCheck.wait { store.sites.first { $0.title == "Nested fixture" }?.showOnHome == false }
        try await fixture.click(".bookmark-heading button", web: web)
        try await AISelfCheck.wait { store.settingsBookmarkScope == "all" }
        try await AIChatPageSelfCheck.check(web, """
            document.body.dataset.bookmarkBounds===JSON.stringify(
                [...document.querySelectorAll('#bookmark-scope,#bookmark-list,.bookmark-footer')].map(el=>{
                    const r=el.getBoundingClientRect();return [r.x,r.y,r.width,r.height];
                })) && document.querySelector('.bookmark-footer').getBoundingClientRect().bottom > innerHeight-28
            """, "Entering and leaving a bookmark folder must keep both panes and the footer in place")
        store.importedBookmarks["Fixture Browser"] = [
            BookmarkNode(title: "Imported folder", address: nil, children: [
                BookmarkNode(title: "Imported child", address: "https://imported-fixture.invalid/", children: nil)
            ])
        ] + (1...30).map {
            BookmarkNode(title: "Imported fixture \($0)", address: "https://imported-fixture.invalid/\($0)", children: nil)
        }
        try await AIChatPageSelfCheck.waitFor(web, "Boolean(document.querySelector('[data-scope=\"imported:Fixture Browser\"]'))")
        try await fixture.click("[data-scope='imported:Fixture Browser']", web: web)
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('.bookmark-children[inert]')?.textContent.includes('Imported child')")
        try await fixture.click(".bookmark-disclosure", web: web)
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('.bookmark-children[data-expanded]')?.textContent.includes('Imported child')")
        try await script("document.querySelector('#bookmark-list').scrollTop=120;")
        try await route(.about, "!document.querySelector('#search').hidden")
        store.browser?.goBack()
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('#bookmark-list')?.scrollTop===120")
        var model = AIConfiguration()
        model.name = "Fixture model provider"
        precondition(store.ai.save(model, key: "fixture-key-not-for-html"))
        try await route(.ai, "Boolean(document.querySelector('[data-provider]'))")
        let aiBounds = try await web.evaluateJavaScript(bounds) as? [Double]
        precondition(aiBounds != nil && aiBounds == standardBounds)
        try await AIChatPageSelfCheck.check(web, "!document.querySelector('input[type=password]')",
                                             "AI overview must keep credential fields in the editor")
        try await fixture.click("[data-provider] button", web: web)
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('.ai-editor:not([hidden]) input[type=password]') !== null")
        try await AIChatPageSelfCheck.check(web, """
            !document.body.innerText.includes('fixture-key-not-for-html') &&
                [...document.querySelectorAll('input[type=password]')].every(x=>x.value==='') &&
                document.querySelector('.ai-overview').hidden
            """, "Saved API keys must stay out of the DOM")
        try await script("""
            document.querySelector('.ai-editor input[placeholder="模型供应商名称"]').value='Updated fixture provider';
            document.querySelector('.ai-editor input[type=password]').value='unsaved-fixture-key';
            """)
        try await fixture.click("a[href='perch://settings/about']", web: web)
        try await AISelfCheck.wait { store.tabs.first?.address == SettingsRoute.about.url.absoluteString }
        store.browser?.goBack()
        try await AIChatPageSelfCheck.waitFor(web, """
            document.querySelector('.ai-editor:not([hidden]) input[placeholder="模型供应商名称"]')?.value==='Updated fixture provider' &&
            document.querySelector('.ai-editor input[type=password]')?.value===''
            """)
        try await fixture.click(".ai-editor-heading button", web: web)
        try await AISelfCheck.wait { store.ai.providers.contains { $0.name == "Updated fixture provider" } }
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('.ai-overview:not([hidden])')?.innerText.includes('Updated fixture provider')")
        _ = try store.passwords.save([SavedPassword(origin: "https://settings-fixture.invalid/", username: "fixture-user", password: "fixture-secret-not-for-html")])
        try await route(.passwords, "document.querySelector('#password-list')?.textContent.includes('fixture-user')===true")
        try await AIChatPageSelfCheck.check(web, "!document.body.innerText.includes('fixture-secret-not-for-html')", "Password list must not expose saved secrets")
        try await AIChatPageSelfCheck.check(web, "!document.querySelector('.password-account details').open",
                                             "Password actions must start collapsed")
        try await fixture.click(".password-account summary", web: web)
        try await AIChatPageSelfCheck.waitFor(web, """
            [...document.querySelectorAll('.password-account details[open] button')].map(b=>b.textContent).join(',')==='查看,复制,修改,删除' &&
            Boolean(document.querySelector('.password-account .settings-menu-items[style]'))
            """)
        try await fixture.click(".password-account details[open] button:nth-child(3)", web: web)
        try await AIChatPageSelfCheck.waitFor(web, "Boolean(document.querySelector('input[autocomplete=new-password]'))")
        try await route(.importer, "document.body.innerText.includes('导出 ZIP')")
        try await route(.about, "document.body.innerText.includes('检查更新')")
        panel.setContentSize(NSSize(width: 640, height: 580))
        try await route(.bookmarks, "Boolean(document.querySelector('#bookmark-list')) && innerWidth<=780")
        try await AIChatPageSelfCheck.check(web, """
            (() => {
                const s=document.querySelector('#bookmark-scope'), l=document.querySelector('#bookmark-list');
                const sr=s.getBoundingClientRect(), lr=l.getBoundingClientRect();
                return sr.bottom<=lr.top && Math.abs(sr.width-lr.width)<1 && l.scrollWidth===l.clientWidth;
            })()
            """, "Compact bookmarks should put the categories above a full-width list")
        try await fixture.click("[data-scope='root']", web: web)
        try await AISelfCheck.wait { store.settingsBookmarkScope == "root" }
        try await AIChatPageSelfCheck.waitFor(web, "document.querySelector('.bookmark-disclosure')?.getAttribute('aria-expanded')==='true'")
        try await AIChatPageSelfCheck.waitFor(web, """
            (() => {
                const l=document.querySelector('#bookmark-list'), r=document.querySelector('.bookmark-children[data-expanded] .bookmark-open');
                return r && r.getBoundingClientRect().right<=l.getBoundingClientRect().right && l.scrollWidth===l.clientWidth;
            })()
            """)
        try await fixture.click(".bookmark-branch .bookmark-open", web: web)
        try await AISelfCheck.wait { store.settingsBookmarkScope == "folder:" + folder.id.uuidString }
        try await fixture.click(".bookmark-icon-action[aria-label^='显示在首页']", web: web)
        try await AISelfCheck.wait { store.sites.first { $0.title == "Nested fixture" }?.showOnHome == true }
        print("PASS: HTML settings routes, native clicks, preferences, bookmark trees and home actions, AI editing, credential boundaries and import controls")
    }
}
