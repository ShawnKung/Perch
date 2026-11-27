import Foundation
import SQLite3
import CommonCrypto
import AppKit
import WebKit
import SwiftUI
import Security
import Carbon
import ApplicationServices

// Self-checks dispatch their own process-local events; desktop input must not race their fixtures.
final class SelfCheckApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
             .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged:
            guard event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) else { return }
        default: break
        }
        super.sendEvent(event)
    }
}

enum SelfTests {
    @MainActor
    static func prepareAccessibility() {
        // A self AX request initializes SwiftUI's accessibility tree without a screen reader.
        var role: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        precondition(result == .success, "Self accessibility initialization failed: \(result.rawValue)")
    }

    static func addressSuggestions() throws {
        let sites = (0..<1179).map { Site(title: "Bookmark \($0)", address: "https://b\($0).invalid/content") }
        let history = (0..<10000).map { Visit(title: "Content \($0)", address: "https://c\($0).invalid/content", date: Date()) }
        let index = try AddressSuggestionIndex(sites: sites, imported: [:], history: history)
        let broad = try index.suggestions(for: "c")
        precondition(broad.count == 8 && broad.allSatisfy(\.bookmark), "Bookmarks must beat title/host prefixes in history")
        let sparse = try index.suggestions(for: "1178")
        precondition(sparse.count == 2 && sparse.first?.bookmark == true)
        let none = try index.suggestions(for: "missing-query-fixture")
        precondition(none.isEmpty)
        let fixture = try AddressSuggestionIndex(sites: [
            Site(title: "中文 Swift 指南", address: "https://EXAMPLE.invalid"),
            Site(title: "duplicate", address: "https://example.invalid/"),
            Site(title: "unsafe", address: "javascript:alert(1)"),
            Site(title: "credentials", address: "https://user:pass@example.invalid")
        ], imported: [:], history: [Visit(title: "duplicate history", address: "https://example.invalid/", date: Date())])
        let unicode = try fixture.suggestions(for: " 中文 \t SWIFT ")
        let dedup = try fixture.suggestions(for: "example")
        let blank = try fixture.suggestions(for: " \n ")
        let historyTitle = try fixture.suggestions(for: "duplicate history")
        precondition(unicode.count == 1 && unicode.first?.address == "https://example.invalid/")
        precondition(dedup.count == 1 && dedup.first?.bookmark == true && blank.isEmpty)
        precondition(historyTitle.count == 1 && historyTitle.first?.bookmark == false,
                     "A different history title remains searchable when the bookmark does not match")
        for query in ["c", "content 9999", "missing-query-fixture"] {
            let result = try index.suggestions(for: query)
            precondition(result.count <= 8)
        }
        print("PASS: bounded suggestions, strict bookmark priority, sparse history fallback, Unicode multiword matching, URL deduplication and invalid URL rejection")
    }
    @MainActor static func tabContents() throws {
        let suite = "dev.perch.content-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        store.tabs = (0..<180).map { Tab(title: "内容 \($0)", address: "") }
        let first = store.tabs[0].id, second = store.tabs[100].id
        store.homeAddressDrafts[first] = [true: "保留草稿"]
        store.activate(first)
        let controller = TabContentsController()
        controller.update(store: store, controlsInset: 0)
        precondition(controller.tabViewItems.count == 1, "Unvisited tabs must not create content controllers")
        let original = controller.tabViewItems[0].viewController!
        let page = (original as! TabContentController).rootView.page
        var updates = 0
        let observation = page.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        store.activate(second)
        controller.update(store: store, controlsInset: 0)
        precondition(controller.tabViewItems.count == 2)
        let inactiveUpdates = updates
        store.tabs[0].title = "后台更新"
        store.pendingAddressFocus = second
        precondition(updates == inactiveUpdates, "Inactive page roots must not render unrelated Store changes")
        store.activate(first)
        precondition(updates > inactiveUpdates, "Returning to a retained page must refresh its current Store state")
        controller.update(store: store, controlsInset: 24)
        precondition(controller.tabViewItems[controller.selectedTabViewItemIndex].viewController === original,
                     "Returning to a visited tab must retain its controller")
        precondition((original as! TabContentController).rootView.controlsInset == 24)
        store.close(second)
        controller.update(store: store, controlsInset: 24)
        precondition(controller.tabViewItems.count == 1 && controller.tabViewItems[0].viewController === original)
        store.newTab()
        controller.update(store: store, controlsInset: 24)
        let empty = controller.tabViewItems[controller.selectedTabViewItemIndex].viewController!
        store.newTab()
        controller.update(store: store, controlsInset: 24)
        precondition(controller.tabViewItems.count == 2 &&
                     controller.tabViewItems[controller.selectedTabViewItemIndex].viewController === empty,
                     "Pristine new homes should reuse one hosting controller")
        print("PASS: lazy tab content creation, visited-controller retention, layout updates and closed-controller cleanup")
    }
    @MainActor
    static func keychainUpgrade(write: Bool) throws {
        guard let service = ProcessInfo.processInfo.environment["PERCH_KEYCHAIN_TEST_SERVICE"],
              service.hasPrefix("dev.perch.synthetic-upgrade."), service.count < 128 else {
            throw PerchError("升级检查仅允许临时合成钥匙串服务。")
        }
        let vault = PasswordVault(service: service)
        if CommandLine.arguments.contains("--keychain-upgrade-deny") {
            do { try vault.load(); preconditionFailure("A different signing identity must not read the password") }
            catch { print("PASS: a different signing identity is denied without system interaction") }
        } else if write {
            _ = try vault.save([SavedPassword(origin: "https://synthetic.invalid", username: "fixture", password: "synthetic-only")])
            print("PASS: synthetic upgrade fixture saved with the first signature")
        } else {
            defer { vault.cleanupSynthetic() }
            try vault.load()
            precondition(vault.entries.count == 1 && vault.entries[0].password == "synthetic-only")
            print("PASS: changed app signature reads the synthetic vault with system interaction forbidden")
        }
    }
    @MainActor
    static func keychain() throws {
        let service = "dev.perch.synthetic-passwords.\(UUID().uuidString)"
        let vault = PasswordVault(service: service)
        defer { vault.cleanupSynthetic() }
        _ = try vault.save([SavedPassword(origin: "https://synthetic.invalid", username: "fixture", password: "synthetic-only")])
        let restored = PasswordVault(service: service)
        try restored.load()
        precondition(restored.entries.count == 1 && restored.entries[0].password == "synthetic-only")
        _ = try restored.save([SavedPassword(origin: "https://synthetic.invalid", username: "fixture", password: "synthetic-updated")])
        let updated = PasswordVault(service: service)
        try updated.load()
        precondition(updated.entries.count == 1 && updated.entries[0].password == "synthetic-updated")
        try updated.delete(updated.entries[0].id)
        let empty = PasswordVault(service: service)
        try empty.load(); precondition(empty.entries.isEmpty)
        print("PASS: native Keychain password create/read/update/delete using only a temporary synthetic service")
    }
    @MainActor
    static func run() throws {
        try DownloadSelfCheck.data()
        try HistoryPageSelfCheck.data()
        try BackupSelfCheck.run()
        try savedTabGroups()
        tabGroupCreation()
        try AISelfCheck.conversationPreferences()
        try addressSuggestions()
        try databaseSnapshot()
        try tabContents()
        try bookmarkOrdering()
        let source = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let target = NSRect(x: -1920, y: 100, width: 1920, height: 1040)
        let original = NSRect(x: 320, y: 182.5, width: 800, height: 560)
        precondition(ScreenPlacement.screenIndex(for: NSRect(x: -1000, y: 300, width: 800, height: 600),
                                                in: [source, target]) == 1)
        precondition(ScreenPlacement.screenIndex(for: NSRect(x: -100, y: 200, width: 800, height: 600),
                                                in: [source, target]) == 0)
        precondition(ScreenPlacement.screenIndex(for: NSRect(x: 3000, y: 3000, width: 200, height: 200),
                                                in: [source, target]) == nil)
        let moved = ScreenPlacement.fit(original, from: source, to: target)
        precondition(moved == NSRect(x: -1360, y: 340, width: 800, height: 560))
        precondition(ScreenPlacement.fit(moved, from: target, to: source) == original)
        precondition(ScreenPlacement.fit(NSRect(x: 100, y: -20, width: 1500, height: 1100),
                                        from: source, to: target) == target)
        for screen in [source, target, NSRect(x: 150, y: -900, width: 600, height: 450)] {
            for frame in [original, NSRect(x: -3000, y: 3000, width: 500, height: 300)] {
                let fitted = ScreenPlacement.fit(frame, from: source, to: screen)
                precondition(screen.contains(fitted), "Window must fit within the target usable screen")
            }
        }
        print("PASS: multi-monitor relative position, negative coordinates, edge clamping and oversized screen fill")
        let iconSuite = "dev.perch.icon-tests.\(UUID().uuidString)"
        let iconDefaults = UserDefaults(suiteName: iconSuite)!
        defer { iconDefaults.removePersistentDomain(forName: iconSuite) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let icon = FaviconLoader.decode(bitmap.representation(using: .png, properties: [:])!)!
        FaviconCache.save(icon, for: "https://favicon-fixture.invalid/a", defaults: iconDefaults)
        let iconTabs = [Tab(title: "A", address: "https://favicon-fixture.invalid/a"),
                        Tab(title: "B", address: "https://favicon-fixture.invalid/b")]
        iconDefaults.set(try JSONEncoder().encode(iconTabs), forKey: "tabs")
        let restoredIcons = Store(defaults: iconDefaults)
        precondition(restoredIcons.icons.count == 2 && restoredIcons.browser == nil,
                     "Restart must restore favicons for unopened tabs without loading their pages")
        precondition(FaviconCache.image(for: "http://favicon-fixture.invalid", defaults: iconDefaults) == nil)
        iconDefaults.set([FaviconCache.key(iconTabs[0].address)!: Data("broken".utf8)], forKey: "favicons")
        precondition(FaviconCache.image(for: iconTabs[0].address, defaults: iconDefaults) == nil)
        print("PASS: persistent favicon thumbnails, unopened-tab restoration, origin isolation and corrupt cache fallback")
        let suite = "dev.perch.extended-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        store.newTab(); let a = store.selected!
        store.newTab(); let b = store.selected!
        store.newTab(); let c = store.selected!
        store.pin(b)
        precondition(store.tabs.first?.id == b)
        store.move(c, before: a)
        precondition(store.tabs.map(\.id) == [b, c, a])
        store.move(a, before: b)
        precondition(store.tabs.map(\.id) == [b, c, a], "Must not cross pinned boundary")
        store.closeOthers(c)
        precondition(store.tabs.map(\.id) == [b, c])
        store.reopen()
        precondition(store.tabs.count == 3)
        store.close(b)
        precondition(store.tabs.count == 2)
        precondition(Store(defaults: defaults).tabs.count == 2)
        let existing = store.tabs.map(\.id)
        store.activate(existing[0])
        store.newTab(); let recent = store.selected!
        store.activate(existing[1])
        store.activate(recent)
        store.close(recent)
        precondition(store.selected == existing[1], "Closing returns to the most recently active tab, independent of row order")
        store.newTab(); let inactive = store.selected!
        store.activate(existing[1])
        store.close(inactive)
        precondition(store.selected == existing[1], "Closing an inactive tab preserves selection")
        store.close(existing[1])
        precondition(store.selected == existing[0], "Closed tabs are pruned from activation history")
        print("PASS: tab closing restores activation history and preserves selection when closing inactive tabs")
        store.mergeHistory([Visit(title: "Example", address: "https://example.com", date: Date(timeIntervalSince1970: 123456))])
        store.mergeHistory(store.history)
        precondition(store.history.count == 1)
        precondition(Store(defaults: defaults).history.count == 1)
        store.deleteHistory()
        precondition(Store(defaults: defaults).history.isEmpty)
        let address = "https://perch-bookmark.invalid"
        precondition(store.bookmark(for: address) == nil)
        store.editCurrentBookmark(title: "Star test", address: address, tabID: store.selected!)
        precondition(store.bookmark(for: address + "/") != nil)
        precondition(store.bookmark(for: address + "/other") == nil)
        precondition(Store(defaults: defaults).bookmark(for: address)?.showOnHome == false)
        let star = store.bookmark(for: address)!
        store.editCurrentBookmark(title: "Ignored title", address: address + "/", tabID: store.selected!)
        precondition(store.bookmarkEditRequest?.site.id == star.id && store.bookmarkEditRequest?.isNew == false)
        let folder = BookmarkFolder(title: "Star folder")
        precondition(store.saveBookmarkFolder(folder))
        let draft = BookmarkEditorDraft(store: store, request: store.bookmarkEditRequest!)
        draft.title = "Edited star"; draft.folderID = folder.id; draft.showOnHome = true
        precondition(draft.save())
        let restoredStar = Store(defaults: defaults).bookmark(for: address)!
        precondition(restoredStar.title == "Edited star" && restoredStar.folderID == folder.id && restoredStar.showOnHome == true)
        let copyBoard = NSPasteboard.withUniqueName()
        defer { copyBoard.releaseGlobally() }
        BookmarkClipboard.copy([restoredStar], to: copyBoard)
        let copyIDs = store.pasteBookmarks(from: copyBoard, to: folder.id)
        precondition(copyIDs.count == 1)
        let copy = store.sites.first { copyIDs.contains($0.id) }!
        precondition(store.edit(copy, title: "Edited copy", address: copy.address, folderID: nil, showOnHome: false))
        let restoredCopy = Store(defaults: defaults).sites.first { $0.id == copy.id }!
        precondition(restoredCopy.title == "Edited copy" && restoredCopy.folderID == nil && restoredCopy.showOnHome == false)
        precondition(store.removeBookmarks(copyIDs))
        let bytes = defaults.data(forKey: "sites")
        precondition(!store.edit(star, title: "Duplicate", address: store.sites.first!.address, folderID: nil, showOnHome: false))
        precondition(defaults.data(forKey: "sites") == bytes)
        precondition(!store.edit(star, title: "Invalid folder", address: address, folderID: UUID(), showOnHome: false))
        precondition(defaults.data(forKey: "sites") == bytes)
        let folderBytes = defaults.data(forKey: "bookmarkFolders")
        defaults.set(Data("invalid folder data".utf8), forKey: "bookmarkFolders")
        precondition(!store.edit(star, title: "Must not move", address: address, folderID: nil, showOnHome: false))
        precondition(defaults.data(forKey: "sites") == bytes)
        defaults.set(folderBytes, forKey: "bookmarkFolders")
        let damagedSites = Data("invalid star data".utf8)
        defaults.set(damagedSites, forKey: "sites")
        precondition(!store.edit(star, title: "Must not save", address: address, folderID: nil, showOnHome: false))
        precondition(defaults.data(forKey: "sites") == damagedSites && store.bookmark(for: address)?.title == "Edited star")
        defaults.set(bytes, forKey: "sites")
        precondition(store.deleteBookmarkFolder(folder.id))
        precondition(store.bookmark(for: address) == nil && Store(defaults: defaults).bookmark(for: address) == nil)
        let importedStar = BookmarkNode(title: "Imported star", address: "https://imported-star.invalid/")
        _ = store.replaceImportedBookmarks([importedStar], source: .chrome)
        store.bookmarkEditRequest = nil
        store.editCurrentBookmark(title: "Readonly", address: importedStar.address!, tabID: store.selected!)
        precondition(store.bookmarkEditRequest == nil && !store.sites.contains { $0.id == importedStar.id })
        store.importedBookmarks = [:]
        defaults.removeObject(forKey: "importedBookmarks")
        store.notice = nil
        print("PASS: star editor URL matching, default home exclusion, metadata persistence, duplicate/invalid-folder/corrupt-data rejection and imported isolation")
        var settings = BrowserSettings()
        precondition(settings.historyRecordingEnabled && settings.toggleKey?.code == 7 &&
                     settings.toggleKey?.modifiers == UInt32(cmdKey | controlKey), "New settings must enable history and default to Control-Command-X")
        precondition(settings.theme == .blue, "New settings must default to the blue theme")
        precondition(Site.defaults.map(\.title) == ["Google", "DuckDuckGo", "GitHub", "ChatGPT", "DeepSeek", "Qwen"])
        settings.uaMode = "custom"; settings.customUA = "Example/1.0"
        try store.saveSettings(settings)
        precondition(Store(defaults: defaults).settings.userAgent == "Example/1.0")
        settings.customUA = "unsafe\r\nheader"
        expectFailure { try settings.validate() }
        settings = BrowserSettings(); settings.toggleKey = settings.openKey
        expectFailure { try settings.validate() }
        let lastValid = store.settings
        expectFailure { try store.saveSettings(settings) }
        precondition(store.settings == lastValid && Store(defaults: defaults).settings == lastValid)
        precondition(RootView.sidebarSize(212, available: 850) == 212)
        precondition(RootView.sidebarSize(212, available: 640) == 212)
        precondition(RootView.sidebarSize(999, available: 640) == 355)
        precondition(RootView.controlsInset(48) == 61 && RootView.controlsInset(109) == 0,
                     "Narrow top chrome must clear the fixed sidebar toggle")
        precondition(RootView.topBarHeight(chat: false) == 44 && RootView.topBarHeight(chat: true) == 44,
                     "Tab and content dividers must share the active top-bar height")
        let legacySettings = Data(#"{"uaMode":"custom","customUA":"Legacy/1.0","openKey":null,"closeKey":null}"#.utf8)
        let restoredSettings = try JSONDecoder().decode(BrowserSettings.self, from: legacySettings)
        precondition(restoredSettings.userAgent == "Legacy/1.0" && restoredSettings.toggleKey?.code == 7)
        var clearedShortcut = restoredSettings
        clearedShortcut.toggleKey = nil
        let clearedRoundTrip = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(clearedShortcut))
        precondition(clearedRoundTrip.toggleKey == nil, "An explicitly cleared shortcut must remain cleared")
        let conflict = Data(#"{"openKey":{"code":7,"modifiers":4352,"label":"⌃⌘X"}}"#.utf8)
        let conflictSettings = try JSONDecoder().decode(BrowserSettings.self, from: conflict)
        precondition(conflictSettings.toggleKey == nil, "Legacy shortcut migration must avoid conflicts")
        precondition(restoredSettings.searchEngine == "google" && restoredSettings.savePasswords)
        precondition(!restoredSettings.showWindowOnLaunch, "Existing settings must keep launch-window display disabled")
        precondition(restoredSettings.historyRecordingEnabled, "Existing settings must keep browser history enabled")
        precondition(restoredSettings.theme == .green, "Legacy settings must keep the original green palette")
        var launchSettings = restoredSettings
        launchSettings.showWindowOnLaunch = true
        let savedLaunchSettings = try JSONDecoder().decode(BrowserSettings.self,
                                                            from: JSONEncoder().encode(launchSettings))
        precondition(savedLaunchSettings.showWindowOnLaunch)
        var historySettings = restoredSettings
        historySettings.historyRecordingEnabled = false
        try store.saveSettings(historySettings)
        let historyBefore = store.history
        store.recordVisit(title: "Disabled history", address: "https://disabled-history.invalid/")
        precondition(store.history.map(\.id) == historyBefore.map(\.id),
                     "Disabled browser history must not add a visit")
        store.mergeHistory([Visit(title: "Imported history", address: "https://imported-history.invalid/", date: Date())])
        precondition(store.history.contains { $0.address == "https://imported-history.invalid/" },
                     "Manual history import must remain available when browser history is disabled")
        try store.saveSettings(restoredSettings)
        for color in ThemeColor.allCases {
            var themed = restoredSettings
            themed.theme = color
            try store.saveSettings(themed)
            precondition(Store(defaults: defaults).settings.theme == color && PerchTheme.shared.selection == color)
            func luminance(_ color: NSColor) -> Double {
                func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
                return linear(color.redComponent) * 0.2126 + linear(color.greenComponent) * 0.7152 + linear(color.blueComponent) * 0.0722
            }
            precondition(1.05 / (luminance(color.accent) + 0.05) >= 4.5, "Theme buttons must retain readable white symbols")
            precondition(luminance(color.sidebar) > 0.85 && luminance(color.mint) > 0.72, "Theme surfaces must stay light")
            precondition(luminance(color.sample) < luminance(color.mint),
                         "Theme swatches may be stronger than the applied surface without changing it")
        }
        let damagedTheme = Data(#"{"theme":"invalid","customUA":"preserved"}"#.utf8)
        defaults.set(damagedTheme, forKey: "settings")
        let protectedSettings = Store(defaults: defaults)
        expectFailure { try protectedSettings.saveSettings(BrowserSettings()) }
        precondition(defaults.data(forKey: "settings") == damagedTheme)
        defaults.set(try JSONEncoder().encode(restoredSettings), forKey: "settings")
        try store.saveSettings(restoredSettings)
        print("PASS: nine light palettes, readable button contrast, legacy theme migration, persistence and damaged-settings preservation")
        precondition(restoredSettings.linkPreviewEnabled && restoredSettings.linkPreviewKey.code == 58 &&
                     restoredSettings.linkPreviewDelay == 1, "Old settings must gain Alt/one-second preview defaults")
        var previewSettings = restoredSettings
        previewSettings.linkPreviewEnabled = false
        previewSettings.linkPreviewDelay = 2.5
        previewSettings.linkPreviewKey = Shortcut(code: 59, modifiers: 0, label: "Control")
        let restoredPreviewSettings = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(previewSettings))
        precondition(restoredPreviewSettings == previewSettings)
        for delay in [0.0, 0.001, 12.5, Double.greatestFiniteMagnitude] {
            previewSettings.linkPreviewDelay = delay
            try previewSettings.validate()
            let restored = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(previewSettings))
            precondition(restored.linkPreviewDelay == delay, "All finite nonnegative preview delays must persist")
        }
        previewSettings.linkPreviewDelay = -0.1
        expectFailure { try previewSettings.validate() }
        let invalidDelay = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(previewSettings))
        precondition(invalidDelay.linkPreviewDelay == 1)
        previewSettings.linkPreviewDelay = .infinity
        expectFailure { try previewSettings.validate() }
        previewSettings.linkPreviewDelay = 1
        previewSettings.linkPreviewKey.code = 53
        expectFailure { try previewSettings.validate() }
        precondition(URLInput.parse("a & b")?.host == "www.google.com")
        precondition(URLInput.parse("a & b", searchTemplate: "https://search.invalid/find?q={query}&src=perch")?.query == "q=a%20%26%20b&src=perch")
        precondition(!URLInput.validSearchTemplate("https://{query}.example.com"))
        precondition(!URLInput.validSearchTemplate("https://example.com/?a={query}&b={query}"))
        settings = BrowserSettings(); settings.searchEngine = "custom"; settings.customSearchURL = "https://search.invalid/?q={query}"
        try store.saveSettings(settings)
        precondition(Store(defaults: defaults).settings.searchURL == settings.customSearchURL)
        settings.customSearchURL = "javascript:{query}"
        expectFailure { try store.saveSettings(settings) }
        let leaf = BookmarkNode(title: "Needle bookmark", address: "https://needle.invalid/path")
        let nodes = [BookmarkNode(title: "Empty", children: []),
                     BookmarkNode(title: "Nested", children: [leaf, leaf])]
        precondition(store.replaceImportedBookmarks(nodes, source: .chrome) == 2)
        precondition(store.importedBookmarks["Chrome"]?[0].children?.isEmpty == true)
        precondition(Store(defaults: defaults).importedBookmarks["Chrome"]?[1].children?.count == 2)
        store.editCurrentBookmark(title: "", address: leaf.address!, tabID: store.selected!)
        precondition(store.importedBookmarks["Chrome"]?[1].children?.count == 2 && !store.sites.contains { $0.address == leaf.address })
        store.mergeHistory([Visit(title: "Needle from history", address: "https://needle.invalid/path", date: Date()),
                            Visit(title: "Other needle", address: "https://else.invalid/", date: Date())])
        let suggestionIndex = try AddressSuggestionIndex(sites: store.sites, imported: store.importedBookmarks, history: store.history)
        let suggestions = try suggestionIndex.suggestions(for: "needle")
        precondition(suggestions.count == 2 && suggestions.filter(\.bookmark).count == 1)
        let pathSuggestions = try suggestionIndex.suggestions(for: "needle path")
        precondition(pathSuggestions.first?.address == leaf.address)
        precondition(store.replaceImportedBookmarks([], source: .chrome) == 0)
        precondition(Store(defaults: defaults).importedBookmarks["Chrome"]?.isEmpty == true)
        precondition(SavedPassword.origin(for: "https://EXAMPLE.com:443/path?q=x") == "https://example.com")
        precondition(SavedPassword.origin(for: "http://example.com:80") == "http://example.com")
        precondition(SavedPassword.origin(for: "https://example.com:8443") == "https://example.com:8443")
        let vault = PasswordVault(memoryOnly: true)
        _ = try vault.save([SavedPassword(origin: "https://example.com/login", username: "fixture", password: "first")])
        _ = try vault.save([SavedPassword(origin: "https://example.com:443/", username: "fixture", password: "updated"),
                           SavedPassword(origin: "http://example.com", username: "fixture", password: "separate")])
        precondition(vault.entries.count == 2 && vault.entries.first?.password == "updated")
        expectFailure { _ = try vault.save([SavedPassword(origin: "https://example.com", username: "fixture", password: "")]) }
        precondition(vault.entries.count == 2 && vault.entries.first?.password == "updated")
        try vault.delete(vault.entries[0].id)
        precondition(vault.entries.count == 1 && vault.entries[0].origin == "http://example.com")
        let csv = "\u{FEFF}name,url,username,password\r\nExample,https://example.com,\"user,one\",\"secret\"\"quoted\r\nline\"\r\n"
        let parsedCSV = try PasswordCSV.read(Data(csv.utf8))
        precondition(parsedCSV.items.count == 1 && parsedCSV.items[0].username == "user,one" &&
                     parsedCSV.items[0].password == "secret\"quoted\r\nline")
        expectFailure { _ = try PasswordCSV.read(Data("url,username,password\nhttps://example.com,u,\"unclosed".utf8)) }
        expectFailure { _ = try PasswordCSV.read(Data("url,username,password\nhttps://example.com,u,p,extra".utf8)) }
        print("PASS: search settings migration/encoding, immutable bookmark trees/full replacement, title/URL suggestions, password origin isolation and CSV boundaries")
        var press = MiddlePress()
        press.begin(a)
        precondition(press.end(over: b) == nil, "Dragging the middle press must not close another tab")
        press.begin(a); press.cancel()
        precondition(press.end(over: a) == nil, "A reload or scroll must cancel the in-flight press")
        press.begin(a)
        precondition(press.end(over: a) == a && press.end(over: a) == nil, "One gesture closes exactly one ID")
        nativeMiddleClick()
        precondition(store.canMove(store.tabs.last!.id, to: store.tabs.count))
        store.move(store.tabs.last!.id, to: 0)
        settings = BrowserSettings(); settings.closeKey = settings.openKey
        expectFailure { try settings.validate() }
        print("PASS: tab persistence, fixed ordering, drag boundaries, close/reopen, history and UA validation")
        let batch = [Site(title: "批量 A", address: "http://127.0.0.1:9/a"),
                     Site(title: "批量 B", address: "http://127.0.0.1:9/b")]
        for site in batch { precondition(store.add(title: site.title, address: site.address)) }
        let ids = Set(store.sites.filter { batch.map(\.address).contains($0.address) }.map(\.id))
        let keep = store.sites.filter { !ids.contains($0.id) }
        let imported = BookmarkNode(title: "只读", address: "http://127.0.0.1:9/imported")
        _ = store.replaceImportedBookmarks([imported], source: .chrome)
        let tabCount = store.tabs.count
        store.openBookmarks(batch + [Site(title: "Invalid", address: "javascript:alert(1)")])
        precondition(store.tabs.count == tabCount + 2)
        precondition(store.selected == store.tabs[tabCount].id)
        precondition(Store(defaults: defaults).tabs.suffix(2).map(\.address) == batch.map(\.address))
        precondition(store.removeBookmarks(ids.union([imported.id])))
        precondition(store.sites.map(\.id) == keep.map(\.id))
        precondition(Store(defaults: defaults).sites.map(\.id) == keep.map(\.id))
        precondition(store.importedBookmarks["Chrome"]?.first?.id == imported.id)
        let saved = defaults.data(forKey: "sites")!
        let broken = Data("broken bookmark fixture".utf8)
        defaults.set(broken, forKey: "sites")
        precondition(!store.removeBookmarks(Set(keep.map(\.id))))
        precondition(defaults.data(forKey: "sites") == broken && store.sites.map(\.id) == keep.map(\.id))
        defaults.set(saved, forKey: "sites")
        print("PASS: batch bookmark opening/order/session persistence, deletion/read-only isolation and corrupt-data preservation")
        var parent = BookmarkFolder(title: "工作")
        precondition(store.saveBookmarkFolder(parent))
        let child = BookmarkFolder(title: "文档", parentID: parent.id)
        precondition(store.saveBookmarkFolder(child))
        precondition(store.add(title: "目录内", address: "http://127.0.0.1:9/folder", folderID: child.id))
        let nested = store.sites.last!
        precondition(store.moveBookmarks([keep[0].id, imported.id], to: parent.id))
        let folderRestore = Store(defaults: defaults)
        precondition(folderRestore.sites.first(where: { $0.id == nested.id })?.folderID == child.id)
        precondition(folderRestore.bookmarkFolderPath(child.id) == "工作 / 文档")
        precondition(folderRestore.sites.first(where: { $0.id == keep[0].id })?.folderID == parent.id)
        parent.title = "项目"
        precondition(store.saveBookmarkFolder(parent))
        precondition(store.bookmarkFolderPath(child.id) == "项目 / 文档")
        var cycle = parent; cycle.parentID = child.id
        precondition(!store.saveBookmarkFolder(cycle))
        let folderData = defaults.data(forKey: "bookmarkFolders")!
        let sitesBefore = defaults.data(forKey: "sites")!
        defaults.set(broken, forKey: "bookmarkFolders")
        precondition(!store.deleteBookmarkFolder(parent.id))
        precondition(!store.moveBookmarks([nested.id], to: nil))
        precondition(defaults.data(forKey: "sites") == sitesBefore && defaults.data(forKey: "bookmarkFolders") == broken)
        defaults.set(folderData, forKey: "bookmarkFolders")
        precondition(store.moveBookmarks([keep[0].id], to: nil))
        precondition(store.deleteBookmarkFolder(parent.id))
        precondition(Store(defaults: defaults).bookmarkFolders.isEmpty)
        precondition(!store.sites.contains(where: { $0.id == nested.id }))
        precondition(store.sites.contains(where: { $0.id == keep[0].id && $0.folderID == nil }))
        precondition(store.importedBookmarks["Chrome"]?.first?.id == imported.id)
        print("PASS: nested bookmark folders, legacy migration, rename/move persistence, cycle rejection, recursive deletion and corrupt-folder preservation")
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let destination = BookmarkFolder(title: "粘贴目标")
        precondition(store.saveBookmarkFolder(destination))
        let clipboardSites = [Site(id: imported.id, title: "只读副本", address: imported.address!)]
        BookmarkClipboard.copy(clipboardSites, to: clipboard)
        precondition(clipboard.string(forType: .string) == imported.address!)
        let pasted = store.pasteBookmarks(from: clipboard, to: destination.id)
        precondition(pasted.count == 1 && !pasted.contains(imported.id))
        precondition(store.sites.contains { pasted.contains($0.id) && $0.title == "只读副本" && $0.folderID == destination.id })
        precondition(Store(defaults: defaults).sites.contains { pasted.contains($0.id) })
        precondition(store.importedBookmarks["Chrome"]?.first?.id == imported.id)
        clipboard.clearContents()
        clipboard.setString("https://first.invalid\njavascript:alert(1)", forType: .string)
        let beforePaste = defaults.data(forKey: "sites")
        precondition(store.pasteBookmarks(from: clipboard, to: nil).isEmpty)
        precondition(defaults.data(forKey: "sites") == beforePaste)
        clipboard.setString("https://first.invalid\nhttps://second.invalid", forType: .string)
        precondition(store.pasteBookmarks(from: clipboard, to: nil).count == 2)
        precondition(store.pasteBookmarks(from: clipboard, to: UUID()).isEmpty)
        let afterPaste = defaults.data(forKey: "sites")
        defaults.set(broken, forKey: "bookmarkFolders")
        precondition(store.pasteBookmarks(from: clipboard, to: nil).isEmpty)
        precondition(defaults.data(forKey: "sites") == afterPaste)
        defaults.set(try JSONEncoder().encode(store.bookmarkFolders), forKey: "bookmarkFolders")
        defaults.set(broken, forKey: "sites")
        precondition(store.pasteBookmarks(from: clipboard, to: nil).isEmpty)
        precondition(defaults.data(forKey: "sites") == broken)
        defaults.set(afterPaste, forKey: "sites")
        clipboard.clearContents()
        clipboard.setData(Data("invalid".utf8), forType: BookmarkClipboard.type)
        clipboard.setString("https://first.invalid", forType: .string)
        precondition(store.pasteBookmarks(from: clipboard, to: nil).isEmpty)
        print("PASS: bookmark clipboard titles/new IDs/folder persistence, imported isolation, multiline URLs and atomic invalid/corrupt-data rejection")
        let moveRoot = BookmarkFolder(title: "移动目录")
        let moveChild = BookmarkFolder(title: "子目录", parentID: moveRoot.id)
        precondition(store.saveBookmarkFolder(moveRoot) && store.saveBookmarkFolder(moveChild))
        precondition(store.add(title: "目录内书签", address: "https://folder-copy.invalid", folderID: moveChild.id))
        let moveSite = store.sites.first { $0.address.contains("folder-copy.invalid") }!
        let moveIDs: Set<UUID> = [moveRoot.id, moveChild.id, moveSite.id]
        let organizationBefore = defaults.data(forKey: "bookmarkFolders")
        precondition(!store.moveBookmarkItems(moveIDs, to: moveChild.id))
        precondition(defaults.data(forKey: "bookmarkFolders") == organizationBefore)
        store.cutBookmarkItems(moveIDs, to: clipboard)
        precondition(store.pasteBookmarks(from: clipboard, to: destination.id) == moveIDs)
        precondition(store.bookmarkFolders.first { $0.id == moveRoot.id }?.parentID == destination.id)
        precondition(store.bookmarkFolders.first { $0.id == moveChild.id }?.parentID == moveRoot.id)
        precondition(store.sites.first { $0.id == moveSite.id }?.folderID == moveChild.id)
        precondition(Store(defaults: defaults).sites.first { $0.id == moveSite.id }?.folderID == moveChild.id)
        store.copyBookmarkItems(moveIDs, to: clipboard)
        let folderCopies = store.pasteBookmarks(from: clipboard, to: nil)
        precondition(folderCopies.count == 1 && !folderCopies.contains(moveRoot.id))
        let copiedRoot = folderCopies.first!
        let copiedTree = store.bookmarkFolderDescendants(copiedRoot)
        precondition(copiedTree.count == 2)
        let copiedSites = store.sites.filter { $0.folderID.map(copiedTree.contains) == true }
        precondition(copiedSites.count == 1 && copiedSites[0].id != moveSite.id)
        precondition(store.moveBookmarkItems([copiedSites[0].id], to: copiedRoot))
        precondition(Store(defaults: defaults).sites.first { $0.id == copiedSites[0].id }?.folderID == copiedRoot)
        precondition(store.deleteBookmarkItems([copiedRoot]))
        precondition(!store.bookmarkFolders.contains { copiedTree.contains($0.id) })
        precondition(!store.sites.contains { $0.id == copiedSites[0].id })
        let importFolder = BookmarkNode(title: "导入目录", children: [imported, BookmarkNode(title: "空目录", children: [])])
        _ = store.replaceImportedBookmarks([importFolder], source: .firefox)
        store.copyBookmarkItems([importFolder.id], to: clipboard)
        precondition(BookmarkClipboard.payload(clipboard)?.folders.count == 2)
        precondition(store.pasteBookmarks(from: clipboard, to: destination.id).count == 1)
        precondition(store.importedBookmarks["Firefox"]?.first?.id == importFolder.id)
        let copiedData = clipboard.data(forType: BookmarkClipboard.type)
        store.cutBookmarkItems([importFolder.id], to: clipboard)
        precondition(clipboard.data(forType: BookmarkClipboard.type) == copiedData)
        let cycleA = BookmarkFolder(title: "A")
        var cycleB = BookmarkFolder(title: "B", parentID: cycleA.id)
        var cycleRoot = cycleA; cycleRoot.parentID = cycleB.id
        cycleB.parentID = cycleRoot.id
        BookmarkClipboard.write(.init(sites: [], folders: [cycleRoot, cycleB]), to: clipboard)
        let cycleBefore = defaults.data(forKey: "bookmarkFolders")
        precondition(store.pasteBookmarks(from: clipboard, to: nil).isEmpty)
        precondition(defaults.data(forKey: "bookmarkFolders") == cycleBefore)
        print("PASS: folder clipboard hierarchy/new IDs, cut/move identity and persistence, cycle rejection, recursive deletion and imported read-only copy")
        let previewTabs = store.tabs.map(\.id)
        let previewHistory = store.history
        let previewSite = Site(title: "临时预览", address: "http://127.0.0.1:9/preview")
        let previewBrowser = store.bookmarkPreviewBrowser(for: previewSite)!
        precondition(!previewBrowser.webView.configuration.websiteDataStore.isPersistent)
        precondition(previewBrowser.onVisit == nil)
        previewBrowser.onNewTab?(URL(string: "http://127.0.0.1:9/next")!, false)
        precondition(previewBrowser.address == "http://127.0.0.1:9/next")
        precondition(store.tabs.map(\.id) == previewTabs && store.history.count == previewHistory.count)
        precondition(store.bookmarkPreviewBrowser(for: Site(title: "Invalid", address: "javascript:alert(1)")) == nil)
        previewBrowser.webView.stopLoading()
        print("PASS: temporary bookmark browser URL validation, nonpersistent test session and tab/history isolation")
        try imports()
    }
    @MainActor static func savedTabGroups() throws {
        let suite = "dev.perch.saved-groups." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        store.newTab(title: "一"); store.newTab(title: "二"); store.newTab(title: "外部")
        let ids = store.tabs.map(\.id)
        let group = store.createTabGroup(ids[0])!
        store.moveTab(ids[1], to: 1, groupID: group)
        store.editTabGroup(group, name: "资料", color: .purple)
        store.activate(ids[1])
        store.hideTabGroup(group)
        precondition(store.tabs.map(\.id) == [ids[2]] && store.selected == ids[2])
        precondition(store.tabs(inGroup: group).map(\.id) == Array(ids.prefix(2)))
        precondition(store.openTabGroups.isEmpty && store.tabRows == [.tab(ids[2])] && store.recentlyClosed.isEmpty)
        store.normalizeTabGroups()
        let restored = Store(defaults: defaults)
        precondition(restored.tabGroups.first?.hidden == true && restored.tabGroups.first?.color == .purple)
        precondition(restored.tabs(inGroup: group).map(\.title) == ["一", "二"])
        restored.openTabGroup(group, tabID: ids[1])
        precondition(restored.selected == ids[1] && restored.tabs.filter { $0.groupID == group }.map(\.id) == Array(ids.prefix(2)))
        restored.openTabGroup(group)
        precondition(restored.tabs.count == 3 && !restored.tabGroups[0].hidden)
        restored.newTab(after: ids[1])
        let added = restored.selected!
        restored.close(ids[0])
        precondition(restored.tabs(inGroup: group).map(\.id) == [ids[1], added])
        restored.hideTabGroup(group)
        restored.ungroup(group)
        precondition(restored.tabGroups.isEmpty && restored.tabs.count == 3 && restored.tabs.allSatisfy { $0.groupID == nil })
        let deleted = restored.createTabGroup(ids[1])!
        restored.moveTab(added, to: restored.tabs.count, groupID: deleted)
        restored.deleteTabGroup(deleted)
        precondition(restored.tabs.count == 1 && restored.tabGroups.isEmpty)
        precondition(Store(defaults: defaults).tabGroups.isEmpty)
        restored.openChat(owner: UUID())
        let chatID = restored.selected!
        let chatGroup = restored.createTabGroup(chatID)!
        restored.hideTabGroup(chatGroup)
        restored.openChat(owner: UUID())
        let chatOwner = restored.chatOwner
        restored.openTabGroup(chatGroup)
        precondition(restored.tabs.filter(\.isChat).count == 2 && restored.chatOwner == chatOwner)
        restored.deleteTabGroup(chatGroup)
        restored.newTab(address: "http://127.0.0.1:9/before")
        let webID = restored.selected!, webGroup = restored.createTabGroup(webID)!
        restored.cachedBrowser(for: webID)!.address = "http://127.0.0.1:9/current"
        restored.cachedBrowser(for: webID)!.title = "当前网页"
        restored.hideTabGroup(webGroup)
        precondition(restored.tabs(inGroup: webGroup).first?.address == "http://127.0.0.1:9/current" &&
                     restored.tabs(inGroup: webGroup).first?.title == "当前网页" && restored.cachedBrowser(for: webID) == nil)
        restored.deleteTabGroup(webGroup)
        // Missing hiddenTabs remains a normal open group in older installations.
        defaults.set(try JSONEncoder().encode([Tab(id: ids[0], title: "旧标签", address: "", groupID: group)]), forKey: "tabs")
        defaults.set(Data("""
            [{"id":"\(group.uuidString)","name":"旧分组","color":"blue","collapsed":true}]
            """.utf8), forKey: "tabGroups")
        let legacy = Store(defaults: defaults)
        precondition(!legacy.tabGroups[0].hidden && legacy.tabGroups[0].collapsed && legacy.tabs[0].groupID == group)
        let before = defaults.data(forKey: "tabs")
        let corrupt = Data("{broken".utf8)
        defaults.set(corrupt, forKey: "tabGroups")
        let broken = Store(defaults: defaults)
        broken.newTab(); broken.normalizeTabGroups()
        precondition(defaults.data(forKey: "tabs") == before && defaults.data(forKey: "tabGroups") == corrupt)
        let invalid = [TabGroup(id: group, hiddenTabs: [Tab(title: "损坏归属", address: "", groupID: UUID())])]
        let invalidData = try JSONEncoder().encode(invalid)
        defaults.set(invalidData, forKey: "tabGroups")
        let invalidStore = Store(defaults: defaults)
        invalidStore.newTab()
        precondition(defaults.data(forKey: "tabs") == before && defaults.data(forKey: "tabGroups") == invalidData)
        print("PASS: saved groups hide without closed-tab copies, survive restart, reopen once, sync members, dissolve/delete and preserve legacy/corrupt snapshots")
    }
    @MainActor static func tabGroupCreation() {
        func precondition(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
            if !condition() { fputs("FAIL: group creation line \(line): \(message)\n", stderr); exit(1) }
        }
        let suite = "dev.perch.group-creation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        store.newTab(title: "颜色轮询")
        let id = store.selected!
        let coordinator = NativeTabList.Coordinator(store: store)
        func groupMenu(_ store: Store, tabID: UUID) -> NSMenu {
            coordinator.store = store
            coordinator.tabs = store.tabs
            coordinator.rows = store.tabRows
            let row = coordinator.rows.firstIndex(of: .tab(tabID))!
            return coordinator.menu(row)!.items.first { $0.submenu != nil }!.submenu!
        }
        let initialMenu = groupMenu(store, tabID: id)
        precondition(initialMenu.items.map(\.title) == ["新建组"],
                     "No open groups means no trailing separator")
        initialMenu.performActionForItem(at: 0)
        precondition(store.tabGroups.first?.color == .blue, "The native new-group action must use the shared default")
        for color in Array(TabGroupColor.allCases.dropFirst()) + [.blue] {
            let group = store.createTabGroup(id)!
            precondition(store.tabGroups.first { $0.id == group }?.color == color)
        }
        let restarted = Store(defaults: defaults)
        let resumed = restarted.createTabGroup(id)!
        precondition(restarted.tabGroups.first { $0.id == resumed }?.color == .purple,
                     "The next color must survive restart and wrap around")
        restarted.editTabGroup(resumed, color: .gray)
        let next = defaults.object(forKey: "nextTabGroupColor") as! String
        restarted.pin(id)
        precondition(restarted.createTabGroup(id) == nil && restarted.createTabGroup(UUID()) == nil &&
                     defaults.object(forKey: "nextTabGroupColor") as? String == next,
                     "Failed creation must not consume a color")
        restarted.pin(id)
        let edited = restarted.createTabGroup(id)!
        precondition(restarted.tabGroups.first { $0.id == edited }?.color == .pink,
                     "Manual recoloring must not change the creation sequence")
        for invalid in ["", "unknown", "BLUE", 42, -1, 1.5, true, Data([0]),
                        ["blue"], ["color": "blue"]] as [Any] {
            defaults.set(invalid, forKey: "nextTabGroupColor")
            let group = restarted.createTabGroup(id)!
            precondition(restarted.tabGroups.first { $0.id == group }?.color == .blue &&
                         defaults.object(forKey: "nextTabGroupColor") as? String == "purple",
                         "Invalid rotation state must recover from blue")
        }
        defaults.removeObject(forKey: "nextTabGroupColor")
        let open = restarted.createTabGroup(id)!
        restarted.editTabGroup(open, name: "打开组")
        restarted.toggleTabGroup(open)
        restarted.newTab(title: "隐藏组标签")
        let hidden = restarted.createTabGroup(restarted.selected!)!
        restarted.editTabGroup(hidden, name: "隐藏组")
        restarted.hideTabGroup(hidden)
        if restarted.tabGroups.first(where: { $0.id == open })?.collapsed == false {
            restarted.toggleTabGroup(open)
        }
        let menu = groupMenu(restarted, tabID: id)
        precondition(menu.items.map(\.title) == ["新建组", "", "打开组"] && menu.items[1].isSeparatorItem,
                     "New group must precede a separator and only open groups, including collapsed ones")
        let action = menu.items[2].representedObject as! [String]
        precondition(action == [id.uuidString, "group:" + open.uuidString])
        restarted.hideTabGroup(open)
        restarted.newTab(title: "未分组标签")
        precondition(groupMenu(restarted, tabID: restarted.selected!).items.map(\.title) == ["新建组"],
                     "Hidden groups must never appear in the submenu")
        print("PASS: native new-group action, persistent color rotation/wraparound, invalid-state recovery and open-only group submenu")
    }

    static func databaseSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perch-locked-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in ["DELETE", "WAL"] {
            let url = directory.appendingPathComponent(mode + ".sqlite")
            var writer: OpaquePointer?
            precondition(sqlite3_open(url.path, &writer) == SQLITE_OK)
            defer { sqlite3_close(writer) }
            precondition(sqlite3_exec(writer, """
                PRAGMA locking_mode=EXCLUSIVE;
                PRAGMA journal_mode=\(mode);
                CREATE TABLE fixture (value TEXT);
                INSERT INTO fixture VALUES ('synthetic-committed');
                """, nil, nil, nil) == SQLITE_OK)
            precondition(sqlite3_exec(writer, "BEGIN EXCLUSIVE; UPDATE fixture SET value='synthetic-uncommitted';",
                                      nil, nil, nil) == SQLITE_OK)
            precondition(sqlite3_db_cacheflush(writer) == SQLITE_OK)
            let original = try Data(contentsOf: url)
            let wal = URL(fileURLWithPath: url.path + "-wal")
            let originalWAL = try? Data(contentsOf: wal)
            let database = try ImportDatabase(url)
            let rows = try database.rows("SELECT value FROM fixture")
            precondition(rows.count == 1 && rows[0].string("value") == "synthetic-committed",
                         "An exclusively locked source must import committed \(mode) data")
            let preserved = try Data(contentsOf: url)
            precondition(preserved == original)
            precondition((try? Data(contentsOf: wal)) == originalWAL)
        }
        print("PASS: exclusively locked rollback/WAL snapshots retain committed data, discard uncommitted writes and preserve source files")
    }

    @MainActor
    static func nativeMiddleClick() {
        final class Rows: NSObject, NSTableViewDataSource {
            var count = 3
            func numberOfRows(in tableView: NSTableView) -> Int { count }
        }
        let rows = Rows()
        let table = TabTable(frame: NSRect(x: 0, y: 0, width: 200, height: 132))
        table.addTableColumn(NSTableColumn(identifier: .init("test")))
        table.headerView = nil
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = rows
        table.ids = [UUID(), UUID(), UUID()]
        table.reloadData()
        var closed: [UUID] = []
        table.closeTab = { closed.append($0) }
        func event(_ row: Int, _ type: NSEvent.EventType) -> NSEvent {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 0)!
            let cgEvent = event.cgEvent!
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            return NSEvent(cgEvent: cgEvent)!
        }
        table.otherMouseDown(with: event(1, .otherMouseDown))
        table.otherMouseUp(with: event(2, .otherMouseUp))
        precondition(closed.isEmpty, "Pointer drift must not close the release row")
        table.otherMouseDown(with: event(1, .otherMouseDown))
        table.ids.swapAt(0, 1)
        table.reloadData()
        table.otherMouseUp(with: event(1, .otherMouseUp))
        precondition(closed.isEmpty, "Reordered rows must cancel an in-flight press")
        let target = table.ids[1]
        table.otherMouseDown(with: event(1, .otherMouseDown))
        table.otherMouseUp(with: event(1, .otherMouseUp))
        table.otherMouseUp(with: event(1, .otherMouseUp))
        precondition(closed == [target], "Native row hit-testing must close exactly the pressed ID once")
        print("PASS: native table middle-button hit-testing, pointer drift, reorder cancellation and single close")
        closed = []
        var live = Set(table.ids)
        table.isTabOpen = { live.contains($0) }
        table.closeTab = { live.remove($0); closed.append($0) }
        table.animatingRows = true
        for _ in 0..<4 {
            table.otherMouseDown(with: event(0, .otherMouseDown))
            table.otherMouseUp(with: event(0, .otherMouseUp))
        }
        precondition(closed == table.ids && live.isEmpty,
                     "Stationary middle clicks must close each live tab once while outgoing rows still animate")
        print("PASS: continuous middle clicks skip retained closing rows without waiting for animations")
        let hoverCell = TabCell(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        hoverCell.configure(Tab(title: "A long synthetic tab title", address: ""), image: nil, compact: false)
        hoverCell.layoutSubtreeIfNeeded()
        precondition(hoverCell.closeButton.isHidden && !hoverCell.closeButton.isEnabled &&
                     hoverCell.titleClip.frame.maxX > hoverCell.closeButton.frame.minX,
                     "Hidden close buttons must release their layout width to the title")
        hoverCell.setHovered(true, animated: false)
        precondition(!hoverCell.closeButton.isHidden && hoverCell.closeButton.isEnabled &&
                     hoverCell.closeButton.alphaValue == 1 && hoverCell.pin.alphaValue == 0 &&
                     hoverCell.titleClip.frame.maxX <= hoverCell.closeButton.frame.minX - 4,
                     "Only the hovered tab must reveal its close button and shorten its title")
        hoverCell.closeButton.setPointerHovered(true)
        let hoverRow = TabSelectionRow(frame: hoverCell.frame)
        hoverRow.addSubview(hoverCell)
        hoverCell.setHovered(true, animated: false)
        precondition(hoverCell.closeButton.pointerHovered && hoverCell.closeButton.layer?.backgroundColor != nil &&
                     hoverCell.closeButton.image == nil && hoverRow.pointerHovered,
                     "The row and custom round close mark must show their own hover backgrounds")
        hoverCell.setHovered(false, animated: false)
        precondition(hoverCell.closeButton.isHidden && !hoverCell.closeButton.isEnabled &&
                     hoverCell.pin.alphaValue == 1 && TabSelectionRow.horizontalInset == 0 &&
                     TabSelectionRow.verticalInset == 2 &&
                     TabSelectionRow.highlightHeight(width: 32, rowHeight: 36, compact: true) ==
                     TabSelectionRow.highlightHeight(width: 180, rowHeight: 36, compact: false),
                     "Leaving a tab must restore its title space and shorter selection highlight")
        print("PASS: tab titles fade before a round custom close mark, inactive rows hover darker and selected rows stay shorter")
        let scroll = TabScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 88))
        scroll.documentView = table; scroll.hasVerticalScroller = false
        rows.count = 30
        table.reloadData()
        scroll.layoutSubtreeIfNeeded()
        table.scrollRowToVisible(29)
        precondition(!scroll.hasVerticalScroller && scroll.contentView.bounds.minY > 100 &&
                     table.visibleRect.intersects(table.rect(ofRow: 29)),
                     "A scrollbar-free tab list must still reach its last row")
        print("PASS: long native tab list reaches its last row without a scrollbar")
        let historyRow = AIHistoryRow(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let cell = AIHistoryCell(frame: historyRow.bounds)
        let title = NSTextField(labelWithString: "Synthetic conversation")
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -38),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        let button = AIHistoryArchiveButton(frame: NSRect(x: 168, y: 9, width: 22, height: 22))
        cell.archiveButton = button; cell.addSubview(button); historyRow.addSubview(cell)
        var archives = 0
        cell.archive = { archives += 1 }
        button.target = cell; button.action = #selector(AIHistoryCell.archiveConversation)
        let point = NSPoint(x: button.frame.midX, y: button.frame.midY)
        historyRow.setHovered(true, animated: false)
        precondition(historyRow.hovered && button.isEnabled && button.alphaValue == 1 && cell.hitTest(point) === button)
        cell.layoutSubtreeIfNeeded()
        precondition(cell.subviews.compactMap { $0 as? NSTextField }.count == 1,
                     "History rows must contain only their title, including while hovered")
        button.performClick(nil)
        historyRow.setHovered(false, animated: false)
        precondition(!historyRow.hovered && !button.isEnabled && button.alphaValue == 0 && cell.hitTest(point) !== button)
        button.performClick(nil)
        precondition(archives == 1, "An invisible archive action must not receive clicks")
        print("PASS: native history hover reveals only archive, keeps title layout and disables the hidden action")
    }

    @MainActor static func bookmarkOrdering() throws {
        let suite = "dev.perch.bookmark-order-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        let folder = BookmarkFolder(title: "Unchanged folder")
        store.bookmarkFolders = [folder]
        store.sites = (0..<5).map { Site(title: "Ordering \($0)", address: "https://order-\($0).invalid",
                                        folderID: $0 == 2 ? folder.id : nil) }
        let original = store.sites, ids = original.map(\.id)
        defaults.set(try JSONEncoder().encode(original), forKey: "sites")
        defaults.set(try JSONEncoder().encode([folder]), forKey: "bookmarkFolders")
        let home = store.homeShortcuts.map(\.id), folderData = defaults.data(forKey: "bookmarkFolders")
        precondition(store.reorderBookmarkSites([ids[4], ids[0], ids[1], ids[3]]))
        precondition(store.sites.map(\.id) == [ids[4], ids[0], ids[2], ids[1], ids[3]])
        precondition(store.homeShortcuts.map(\.id) == home && defaults.data(forKey: "bookmarkFolders") == folderData)
        let restored = Store(defaults: defaults)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let restoredData = try encoder.encode(restored.sites), currentData = try encoder.encode(store.sites)
        precondition(restoredData == currentData && restored.homeShortcuts.map(\.id) == home)
        let originalMetadata = try original.map { try encoder.encode($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        let currentMetadata = try store.sites.map { try encoder.encode($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        precondition(currentMetadata == originalMetadata, "Reorder must preserve every bookmark's metadata")
        let data = defaults.data(forKey: "sites")
        precondition(!store.reorderBookmarkSites([ids[0], ids[0]]) &&
                     !store.reorderBookmarkSites([UUID()]) && defaults.data(forKey: "sites") == data)
        let uniqueSites = store.sites
        store.sites.append(uniqueSites[0])
        precondition(!store.reorderBookmarkSites(Array(ids.reversed())) && defaults.data(forKey: "sites") == data,
                     "Duplicate stored identities must reject ordering without consuming missing slots")
        store.sites = uniqueSites
        defaults.set(Data("broken".utf8), forKey: "sites")
        precondition(!store.reorderBookmarkSites(Array(ids.reversed())) &&
                     defaults.data(forKey: "sites") == Data("broken".utf8))
        defaults.set(data, forKey: "sites")
        defaults.set(Data("broken".utf8), forKey: "homeShortcutOrder")
        let protected = Store(defaults: defaults)
        precondition(!protected.reorderBookmarkSites(Array(ids.reversed())) &&
                     defaults.data(forKey: "sites") == data &&
                     defaults.data(forKey: "homeShortcutOrder") == Data("broken".utf8))
        let child = BookmarkFolder(title: "Nested folder", parentID: folder.id)
        let nested = Site(title: "Needle bookmark", address: "https://needle.invalid", folderID: child.id)
        let hierarchy = BookmarkListItem.personal(original + [nested], folders: [folder, child], parentID: nil, query: "")
        precondition(hierarchy.first?.folderID == folder.id && hierarchy.first?.children?.first?.folderID == child.id &&
                     hierarchy.first?.children?.first?.children?.first?.site?.id == nested.id)
        let filtered = BookmarkListItem.personal(original + [nested], folders: [folder, child], parentID: nil, query: "Needle")
        precondition(filtered.count == 1 && filtered.first?.children?.count == 1 &&
                     filtered.first?.children?.first?.children?.first?.site?.id == nested.id,
                     "Search must retain the matched bookmark's complete directory path")
        let scoped = BookmarkListItem.personal(original + [nested], folders: [folder, child], parentID: child.id, query: "")
        precondition(scoped.count == 1 && scoped[0].site?.id == nested.id && scoped[0].editable)
        print("PASS: bookmark subset ordering, metadata/folder preservation, independent homepage order, restart and invalid/corrupt rejection")
        print("PASS: personal bookmark tree preserves hierarchy, scoped contents, editable leaves and search ancestor paths")
    }

    static func expectFailure(_ action: () throws -> Void) {
        var failed = false
        do { try action() } catch { failed = true }
        precondition(failed, "Expected rejection")
    }

    static func imports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expiry = Date().addingTimeInterval(86400).timeIntervalSince1970
        let netscape = "# Netscape HTTP Cookie File\n#HttpOnly_.example.com\tTRUE\t/\tTRUE\t\(Int(expiry))\tsession\tfixture\n"
        let textCookies = try BrowserImporter.exportedCookies(Data(netscape.utf8))
        precondition(textCookies.cookies.count == 1)
        precondition(textCookies.cookies[0].isHTTPOnly && textCookies.cookies[0].isSecure)
        precondition(BrowserImporter.cookie(domain: ".example.com", name: "x", value: "y", path: "/", secure: false, httpOnly: false,
                                           expires: Date(timeIntervalSince1970: 1)) == nil)
        let json = """
        [{"domain":".example.com","name":"token","value":"fixture","path":"/","secure":true,"httpOnly":true},
        {"domain":".example.com","name":"partition","value":"fixture","partitionKey":"https://example.org"}]
        """
        let exported = try BrowserImporter.exportedCookies(Data(json.utf8))
        precondition(exported.cookies.count == 1 && exported.skipped == 1)
        precondition(exported.cookies[0].isHTTPOnly)

        func database(_ filename: String, sql: String) throws {
            var db: OpaquePointer?
            precondition(sqlite3_open(root.appendingPathComponent(filename).path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        try database("cookies.sqlite", sql: """
        CREATE TABLE moz_cookies(host TEXT,name TEXT,value TEXT,path TEXT,expiry INTEGER,isSecure INTEGER,isHttpOnly INTEGER,sameSite INTEGER,originAttributes TEXT);
        INSERT INTO moz_cookies VALUES('.example.com','session','fixture','/',\(Int(expiry)),1,1,2,'');
        INSERT INTO moz_cookies VALUES('.example.com','partition','fixture','/',\(Int(expiry)),1,1,2,'^userContextId=1');
        """)
        try database("places.sqlite", sql: """
        CREATE TABLE moz_places(id INTEGER,url TEXT,title TEXT,last_visit_date INTEGER);
        CREATE TABLE moz_bookmarks(id INTEGER,parent INTEGER,position INTEGER,guid TEXT,fk INTEGER,type INTEGER,title TEXT);
        INSERT INTO moz_places VALUES(1,'https://example.com/','Example',1700000000000000);
        INSERT INTO moz_bookmarks VALUES(1,0,0,'root________',NULL,2,'');
        INSERT INTO moz_bookmarks VALUES(2,1,0,'toolbar_____',NULL,2,'Toolbar');
        INSERT INTO moz_bookmarks VALUES(3,2,0,'bookmark____',1,1,'Example');
        INSERT INTO moz_bookmarks VALUES(4,2,1,'separator___',NULL,3,'');
        INSERT INTO moz_bookmarks VALUES(5,1,1,'empty_______',NULL,2,'Empty');
        """)
        let firefox = BrowserImporter.read(ImportOptions(source: .firefox, directory: root))
        precondition(firefox.messages.isEmpty && firefox.cookies.count == 1 && firefox.skipped == 1)
        precondition(firefox.cookies[0].sameSitePolicy == .sameSiteStrict)
        precondition(firefox.bookmarks.count == 1 && firefox.history.count == 1)
        precondition(firefox.bookmarkTree?.map(\.title) == ["Toolbar", "Empty"] &&
                     firefox.bookmarkTree?[0].children?.count == 2)
        precondition(firefox.history[0].date.timeIntervalSince1970 == 1700000000)
        let key = try BrowserImporter.deriveChromeKey(Data("fixture-password".utf8))
        let domain = ".example.com"
        let plaintext = BrowserImporter.sha256(Data(domain.utf8)) + Data("fixture-secret".utf8)
        let encrypted = try encrypt(plaintext, key: key)
        let decrypted = try BrowserImporter.decryptChrome(encrypted, key: key, domain: domain, version: 24)
        precondition(decrypted == "fixture-secret")
        expectFailure { _ = try BrowserImporter.decryptChrome(encrypted, key: key, domain: ".different.com", version: 24) }
        expectFailure { _ = try BrowserImporter.decryptChrome(Data("v20unsupported".utf8), key: key, domain: domain, version: 24) }
        try database("Cookies", sql: """
        CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','24');
        CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,path TEXT,expires_utc INTEGER,is_secure INTEGER,is_httponly INTEGER,samesite INTEGER,encrypted_value BLOB,top_frame_site_key TEXT);
        INSERT INTO cookies VALUES('.example.com','test','fixture','/',0,1,1,1,X'','');
        INSERT INTO cookies VALUES('.example.com','partition','fixture','/',0,1,1,1,X'','https://example.org');
        """)
        try database("History", sql: """
        CREATE TABLE urls(url TEXT,title TEXT,last_visit_time INTEGER);
        INSERT INTO urls VALUES('https://example.com/','Example',13344473600000000);
        """)
        try Data(#"{"roots":{"bookmark_bar":{"children":[{"name":"Example","url":"https://example.com/","type":"url"}]}}}"#.utf8)
            .write(to: root.appendingPathComponent("Bookmarks"))
        let chrome = BrowserImporter.read(ImportOptions(source: .chrome, directory: root))
        precondition(chrome.messages.isEmpty && chrome.cookies.count == 1 && chrome.skipped == 1)
        precondition(chrome.bookmarks.count == 1 && chrome.history.count == 1)
        precondition(chrome.bookmarkTree?.first?.children?.first?.title == "Example")
        precondition(chrome.history[0].date.timeIntervalSince1970 == 1700000000)
        precondition(ImportFileAccess.denied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        precondition(!ImportFileAccess.denied(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
        // Only revoke access to synthetic files, never the user's browser profile.
        for name in ["Bookmarks", "History", "Cookies"] {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent(name).path)
        }
        let denied = BrowserImporter.read(ImportOptions(source: .chrome, directory: root))
        for name in ["Bookmarks", "History", "Cookies"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path)
        }
        precondition(denied.requiresFileAccess && denied.messages.count == 3)
        precondition(denied.cookies.isEmpty && denied.history.isEmpty && denied.bookmarks.isEmpty)
        precondition(denied.bookmarkTree == nil)
        precondition(BrowserImporter.read(ImportOptions(source: .chrome, directory: root)).messages.isEmpty)
        print("PASS: denied Chrome files produce permission guidance and import succeeds after fixture access is restored")
        let chromeRoot = root.appendingPathComponent("Google/Chrome")
        let profile = chromeRoot.appendingPathComponent("Profile 2")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        let discovered = ImportSource.chrome.profiles(in: chromeRoot).map { $0.resolvingSymlinksInPath().path }
        precondition(discovered == [profile.resolvingSymlinksInPath().path], "Profile discovery returned \(discovered)")
        let missing = BrowserImporter.read(ImportOptions(source: .chrome, directory: root.appendingPathComponent("missing")))
        precondition(missing.messages.count == 1 && missing.messages[0].contains("资料目录不存在"))
        let safariData = binaryFixture(expiry: expiry)
        let safari = try BrowserImporter.binaryCookies(safariData)
        precondition(safari.cookies.count == 1 && safari.cookies[0].name == "session" && safari.cookies[0].isHTTPOnly)
        expectFailure { _ = try BrowserImporter.binaryCookies(Data(safariData.prefix(15))) }
        expectFailure { _ = try BrowserImporter.binaryCookies(Data("cook".utf8)) }
        let plist: [String: Any] = ["Children": [["URLString": "https://example.com/", "URIDictionary": ["title": "Example"]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: root.appendingPathComponent("Bookmarks.plist"))
        try database("History.db", sql: """
        CREATE TABLE history_items(id INTEGER,url TEXT);
        CREATE TABLE history_visits(history_item INTEGER,title TEXT,visit_time REAL);
        INSERT INTO history_items VALUES(1,'https://example.com/');
        INSERT INTO history_visits VALUES(1,'Example',721692800);
        """)
        let safariOptions = ImportOptions(source: .safari, directory: root, cookies: false)
        let safariRecords = BrowserImporter.read(safariOptions)
        precondition(safariRecords.messages.isEmpty && safariRecords.bookmarks.count == 1 && safariRecords.history.count == 1)
        precondition(safariRecords.history[0].date.timeIntervalSince1970 == 1700000000)
        let passwordFile = root.appendingPathComponent("passwords.csv")
        try Data("url,username,password\nhttps://example.com,fixture,synthetic-secret\n".utf8).write(to: passwordFile)
        let passwordOptions = ImportOptions(source: .safari, directory: root, cookies: false, bookmarks: false,
                                            history: false, passwords: true, passwordFile: passwordFile)
        let passwordImport = BrowserImporter.read(passwordOptions)
        precondition(passwordImport.messages.isEmpty && passwordImport.passwords.count == 1)
        precondition(passwordImport.passwords[0].origin == "https://example.com")
        print("PASS: synthetic Chrome / Firefox / Safari cookies, bookmarks, history, crypto, expiry, isolation and malformed files")
    }

    static func encrypt(_ input: Data, key: Data) throws -> Data {
        var out = Data(count: input.count + 16)
        let capacity = out.count
        var written = 0
        let iv = Data(repeating: 0x20, count: 16)
        let status = out.withUnsafeMutableBytes { output in
            input.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, input.count,
                                output.baseAddress, capacity, &written)
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        out.count = written
        return Data("v10".utf8) + out
    }

    static func binaryFixture(expiry: Double) -> Data {
        func word(_ number: Int, big: Bool = false) -> [UInt8] {
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }
            return big ? bytes.reversed() : bytes
        }
        var record = [UInt8](repeating: 0, count: 56)
        record.replaceSubrange(8..<12, with: word(5))
        for (offset, value) in [(16, ".example.com"), (20, "session"), (24, "/"), (28, "fixture")] {
            record.replaceSubrange(offset..<offset + 4, with: word(record.count))
            record += Array(value.utf8) + [0]
        }
        let bits = (expiry - 978307200).bitPattern
        for index in 0..<8 { record[40 + index] = UInt8(truncatingIfNeeded: bits >> (index * 8)) }
        record.replaceSubrange(0..<4, with: word(record.count))
        var page: [UInt8] = [0, 0, 1, 0]
        page += word(1) + word(16) + [0, 0, 0, 0]
        page += record + [0, 0, 0, 0]
        return Data(Array("cook".utf8) + word(1, big: true) + word(page.count, big: true) + page)
    }
}

@MainActor
enum WebTabSelfCheck {
    static func run() async throws {
        let suite = "dev.perch.web-tabs-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1100, height: 750),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        window.orderFront(nil)
        defer { window.close() }
        let html = """
        <!doctype html><style>
        html,body,#app {height:100vh;margin:0;padding:0}
        #outer {height:100%;overflow:auto}
        #grid {display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:24px}
        .card {height:500px;overflow:auto} .items {height:2500px}
        </style><div id="app"><div id="outer"><input id="field"><div id="grid"></div></div></div>
        <script>
        grid.innerHTML=Array.from({length:50},(_,i)=>'<div class="card"><div class="items">Card '+i+'</div></div>').join('');
        window.resizeCount=0; addEventListener('resize',()=>resizeCount++);
        window.fixtureIdentity=Math.random();
        </script>
        """
        store.newTab(address: "https://nested-fixture.invalid")
        let firstID = store.selected!, first = store.browser!.webView
        first.loadHTMLString(html, baseURL: URL(string: "https://nested-fixture.invalid"))
        try await AISelfCheck.wait { first.window === window && !first.isLoading }
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await first.evaluateJavaScript("""
            document.getElementById('outer').scrollTop=4200;
            document.querySelector('.card').scrollTop=350;
            field.value='unchanged input';field.setSelectionRange(2,7);
            """)
        store.newTab(address: "https://document-fixture.invalid")
        let secondID = store.selected!, second = store.browser!.webView
        second.loadHTMLString("""
            <!doctype html><style>body{height:12000px}</style><p>Document scrolling</p>
            <script>window.resizeCount=0;addEventListener('resize',()=>resizeCount++)</script>
            """, baseURL: URL(string: "https://document-fixture.invalid"))
        try await AISelfCheck.wait { second.window === window && !second.isLoading }
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await second.evaluateJavaScript("scrollTo(0,3100)")
        store.activate(firstID)
        try await Task.sleep(nanoseconds: 200_000_000)
        var parent = first.superview
        let firstFrame = first.frame, secondFrame = second.frame
        func state() async throws -> String {
            try await first.evaluateJavaScript("""
                JSON.stringify([innerWidth,innerHeight,document.getElementById('outer').scrollTop,
                document.querySelector('.card').scrollTop,field.value,field.selectionStart,
                field.selectionEnd,fixtureIdentity,resizeCount])
                """) as! String
        }
        let before = try await state()
        for color in ThemeColor.allCases {
            var settings = store.settings
            settings.theme = color
            try store.saveSettings(settings)
            try await Task.sleep(nanoseconds: 80_000_000)
            let after = try await state()
            precondition(after == before && first.superview === parent && first.frame == firstFrame,
                         "Theme changes must preserve webpage identity, input, selection, scrolling and viewport")
            let untouched = try await first.evaluateJavaScript("!document.documentElement.dataset.perchTheme")
            precondition(untouched as? Bool == true, "Application themes must not inject scripts into browsing pages")
        }
        print("PASS: all nine themes preserve loaded webpage state without script injection or resize")
        let nestedScroll = try await first.evaluateJavaScript("document.getElementById('outer').scrollTop")
        precondition(nestedScroll as? Double == 4200)
        for _ in 0..<6 {
            store.activate(secondID)
            try await Task.sleep(nanoseconds: 80_000_000)
            precondition(first.window == nil && second.window === window && first.superview === parent)
            precondition(first.frame == firstFrame && second.frame == secondFrame)
            let documentScroll = try await second.evaluateJavaScript("scrollY")
            precondition(documentScroll as? Double == 3100)
            store.activate(firstID)
            try await Task.sleep(nanoseconds: 80_000_000)
            let after = try await state()
            precondition(after == before, "Tab switching must preserve every nested scroll, viewport, input, selection and document identity without resize events")
        }
        store.newTab()
        let homeID = store.selected!
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(first.window == nil && second.window == nil && first.frame == firstFrame)
        store.close(homeID)
        store.activate(firstID)
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterHome = try await state()
        precondition(afterHome == before)
        store.openChat(owner: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(first.window == nil && first.superview === parent && first.frame == firstFrame)
        store.activate(firstID)
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterChat = try await state()
        precondition(afterChat == before, "Opening Chat must leave detached webpage state intact")
        let root = window.contentView!
        var hit = root.hitTest(root.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), from: first))
        while hit != nil && hit !== first { hit = hit?.superview }
        precondition(hit === first, "Browser status overlays must not intercept page clicks")
        let savedTabCount = store.tabs.count
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await AISelfCheck.wait { NSApp.isActive && window.isKeyWindow }
        window.makeFirstResponder(first)
        _ = try await first.evaluateJavaScript("""
        const link=document.createElement('a');link.id='backgroundLink';link.href='https://background-fixture.invalid/';
        link.textContent='Background';link.style='position:fixed;left:30px;top:30px;z-index:1000';document.body.append(link);
        """)
        let position = try await first.evaluateJavaScript("""
        (()=>{const r=backgroundLink.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()
        """) as! [String: Double]
        let location = first.convert(NSPoint(x: position["x"]!, y: first.isFlipped ? position["y"]! : first.bounds.height - position["y"]!), to: nil)
        for middle in [false, true] {
            for type in middle ? [NSEvent.EventType.otherMouseDown, .otherMouseUp] : [.leftMouseDown, .leftMouseUp] {
                let raw = NSEvent.mouseEvent(with: type, location: location, modifierFlags: middle ? [] : .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1)!
                let cg = raw.cgEvent!
                if middle { cg.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
                window.sendEvent(middle ? NSEvent(cgEvent: cg)! : raw)
            }
            try await AISelfCheck.wait {
                store.tabs.count >= savedTabCount + (middle ? 2 : 1)
            }
            precondition(store.tabs.count == savedTabCount + (middle ? 2 : 1), "A link click must create exactly one tab")
            precondition(store.selected == firstID && first.window === window, "Modified link clicks must preserve the active tab")
            let after = try await state()
            precondition(after == before, "Background navigation must preserve scroll, input and document identity")
        }
        print("PASS: native Command-click and middle-click open background tabs without changing the current page")
        window.setContentSize(NSSize(width: 950, height: 700))
        try await AISelfCheck.wait { first.frame != firstFrame }
        precondition(second.frame == secondFrame, "Actual resizing must not resize detached pages")
        store.activate(secondID)
        try await AISelfCheck.wait { second.frame != secondFrame }
        parent = nil
        store.close(firstID)
        try await AISelfCheck.wait { first.superview == nil }
        print("PASS: real RootView tab switches preserve document and nested scrolling, viewport, input, selection and JS identity with no resize events; home/Chat round trips, page click routing, actual resizing and closed-page removal")
    }
}

@MainActor
final class BookmarkTestDrag: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, table: NSView) {
        draggingPasteboard = board; draggingSource = table; draggingDestinationWindow = table.window
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
final class LayoutSelfCheck {
    private var trackedWebMenu: NSMenu?
    let suite = "dev.perch.layout-tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: Store
    let panel = Panel(contentRect: NSRect(x: 150, y: 150, width: 850, height: 660),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    init(preview: Bool) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(212.0, forKey: "sidebarWidth")
        defaults.set(CommandLine.arguments.contains("--compact"), forKey: "sidebarHidden")
        store = Store(defaults: defaults)
        store.newTab(title: "阅读"); store.newTab(title: "工作"); store.newTab()
        panel.title = "Perch Layout Check"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = RootHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        panel.bindTabFocus(to: store)
        NSApp.activate(ignoringOtherApps: true)
        panel.showAnimated()
        Task { @MainActor in
            if preview {
                await settle()
                if CommandLine.arguments.contains("--verify-bookmark-editor") {
                    await verifyBookmarkEditor()
                }
                if CommandLine.arguments.contains("--verify-web-context-menu") {
                    await verifyWebContextMenu()
                }
                if CommandLine.arguments.contains("--verify-web-selection-ai") {
                    await verifyWebSelectionAI()
                }
                if CommandLine.arguments.contains("--verify-home-shortcut-drag") {
                    await verifyHomeShortcutDrag()
                }
                if CommandLine.arguments.contains("--verify-tab-drag") {
                    await verifyTabDrag()
                }
                if CommandLine.arguments.contains("--verify-bookmark-drag") {
                    await verifyBookmarkDrag()
                }
                if CommandLine.arguments.contains("--verify-bookmark-folders") ||
                    CommandLine.arguments.contains("--verify-home-bookmarks") {
                    await verifyBookmarkFolders()
                }
                if let index = CommandLine.arguments.firstIndex(of: "--verify-home-navigation"),
                   CommandLine.arguments.count > index + 1 {
                    await verifyHomeNavigation(baseURL: CommandLine.arguments[index + 1])
                }
                if CommandLine.arguments.contains("--verify-sidebar-animation") {
                    await verifySidebarAnimation()
                    print("PASS: ordinary icons stay fixed; group icons, highlights and rendered rails animate together through reversal")
                    fflush(stdout)
                }
                if CommandLine.arguments.contains("--verify-group-transition") {
                    await verifyGroupTransition()
                }
                if CommandLine.arguments.contains("--verify-tab-closing") {
                    await verifyTabClosing()
                }
                if CommandLine.arguments.contains("--verify-tab-performance") {
                    await verifyTabPerformance()
                }
                if CommandLine.arguments.contains("--verify-internal-tab-performance") {
                    await verifyInternalTabPerformance()
                }
                if CommandLine.arguments.contains("--verify-tab-burst") {
                    await verifyTabBurst()
                }
                if CommandLine.arguments.contains("--compact") && CommandLine.arguments.contains("--verify-preview") {
                    verify(width: 32)
                    print("PASS: collapsed tab icon and highlight centers align")
                    fflush(stdout)
                }
                if CommandLine.arguments.contains("--preview-field-password") {
                    let origin = CommandLine.arguments.contains("--http") ? "http://perch-fixture.invalid" : "https://perch-fixture.invalid"
                    _ = try? store.passwords.save([
                        SavedPassword(origin: origin, username: "synthetic-user", password: "synthetic-secret"),
                        SavedPassword(origin: origin, username: "second-user", password: "synthetic-second")
                    ])
                    store.newTab(address: origin, title: "合成登录页")
                    let browser = store.browser!
                    browser.webView.loadHTMLString("""
                        <!doctype html><meta name="viewport" content="width=device-width">
                        <style>body {font:15px -apple-system;background:#fafbf9;color:#283c34;padding:70px 60px}
                        input {display:block;width:260px;padding:12px;border:1px solid #cbd6cf;border-radius:6px;margin:12px 0}
                        button {padding:10px 20px} label {display:block}</style>
                        <h2>合成登录页</h2><form onsubmit="event.preventDefault()">
                        <label>用户名<input autocomplete="username" placeholder="用户名"></label>
                        <label>密码<input type="password" autocomplete="current-password" placeholder="密码"></label>
                        <button>登录</button></form>
                        """, baseURL: URL(string: origin))
                    for _ in 0..<40 {
                        await settle()
                        if !browser.webView.isLoading { break }
                    }
                    let originalRequest = browser.passwordBridge.requested
                    var fieldRequest: (String, NSRect, String)?
                    browser.passwordBridge.requested = { origin, rect, token in
                        fieldRequest = (origin, rect, token)
                        originalRequest?(origin, rect, token)
                    }
                    _ = try? await browser.webView.evaluateJavaScript("document.querySelector('input[autocomplete=username]').focus()")
                    await settle()
                    precondition(browser.passwordBridge.popover?.isShown == true, "Field focus must show a native account picker")
                    let firstPopover = browser.passwordBridge.popover!
                    let request = fieldRequest!
                    originalRequest?(request.0, request.1, request.2)
                    originalRequest?(request.0, request.1, request.2)
                    precondition(browser.passwordBridge.popover === firstPopover,
                                 "Duplicate focus/click requests must keep the same native popup")
                    firstPopover.close()
                    await settle()
                    precondition(browser.passwordBridge.popover == nil, "External close must reset popup state")
                    originalRequest?(request.0, request.1, request.2)
                    precondition(browser.passwordBridge.popover?.isShown == true &&
                                 browser.passwordBridge.popover !== firstPopover,
                                 "A click after dismissal must reopen the same field's picker")
                    browser.passwordBridge.popover!.close()
                    precondition(browser.passwordBridge.popover == nil,
                                 "Closing during the fade animation must work immediately")
                    originalRequest?(request.0, request.1, request.2)
                    let reopened = browser.passwordBridge.popover
                    browser.passwordBridge.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: firstPopover))
                    precondition(browser.passwordBridge.popover === reopened,
                                 "A late close callback must not clear a newer popup")
                    _ = try? await browser.webView.evaluateJavaScript("document.querySelector('input[type=password]').focus()")
                    await settle()
                    precondition(browser.passwordBridge.popover?.isShown == true &&
                                 browser.passwordBridge.popover !== reopened,
                                 "Switching fields must replace the popup with the new target")
                    print("PASS: duplicate focus/click popup reuse, external dismissal/reopening, stale close callback and changed field")
                    let picker = browser.passwordBridge.popover!.contentViewController as! NSHostingController<PasswordFieldPicker>
                    picker.rootView.select(store.passwords.entries[0])
                    await settle()
                    let filled = try? await browser.webView.evaluateJavaScript("""
                        document.querySelector('input[autocomplete=username]').value === 'synthetic-user' &&
                        document.querySelector('input[type=password]').value === 'synthetic-secret'
                        """)
                    precondition(filled as? Bool == true && browser.passwordBridge.popover == nil,
                                 "Native picker selection must fill and dismiss without refocusing into a new picker")
                    _ = try? await browser.webView.evaluateJavaScript("document.querySelector('input[autocomplete=username]').focus()")
                    await settle()
                    precondition(browser.passwordBridge.popover?.isShown == true)
                    print("PASS: native field picker display, selection fills without authentication, dismissal and reopening (\(origin))")
                    fflush(stdout)
                } else if CommandLine.arguments.contains("--preview-drag") {
                    let table = table()
                    let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! TabCell
                    if let data = cell.dragImage().tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: data),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("perch-drag-card.png"))
                    }
                    table.beginDrag(at: 0)
                    table.previewDrag(to: 1)
                    await settle()
                    if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            try? png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("perch-drag-gap.png"))
                        }
                    }
                } else if CommandLine.arguments.contains("--preview-saved-groups") {
                    let group = store.createTabGroup(store.tabs[0].id)!
                    store.editTabGroup(group, name: "隐藏资料", color: .purple)
                    store.moveTab(store.tabs[1].id, to: 1, groupID: group)
                    store.hideTabGroup(group)
                    let open = store.createTabGroup(store.tabs[0].id)!
                    store.editTabGroup(open, name: "打开工作", color: .blue)
                    store.library = .bookmarks
                    await settle()
                    if CommandLine.arguments.contains("--verify-preview") { await verifySavedGroupManager(group) }
                } else if CommandLine.arguments.contains("--preview-groups") {
                    let group = store.createTabGroup(store.tabs[0].id)!
                    store.editTabGroup(group, name: "CICD")
                    store.moveTab(store.tabs[1].id, to: 1, groupID: group)
                    if CommandLine.arguments.contains("--verify-preview") { await verifyTabGroups() }
                } else if CommandLine.arguments.contains("--preview-bookmarks") {
                    let leaf = BookmarkNode(title: "示例书签", address: "https://example.com")
                    store.importedBookmarks["Chrome"] = [BookmarkNode(title: "书签栏", children: [leaf, BookmarkNode(title: "空目录", children: [])])]
                    let folder = BookmarkFolder(title: "工作")
                    _ = store.saveBookmarkFolder(folder)
                    let child = BookmarkFolder(title: "开发文档", parentID: folder.id)
                    _ = store.saveBookmarkFolder(child)
                    _ = store.moveBookmarks(Set(store.sites.filter { $0.title == "GitHub" }.map(\.id)), to: folder.id)
                    _ = store.moveBookmarks(Set(store.sites.filter { $0.title == "ChatGPT" }.map(\.id)), to: child.id)
                    store.library = .bookmarks
                    await settle()
                    if CommandLine.arguments.contains("--verify-preview") { await verifyBookmarks() }
                    if let view = panel.sheets.first?.contentView ?? panel.contentView,
                       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            try? png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("perch-bookmarks-layout.png"))
                        }
                    }
                    print("PASS: isolated bookmark folder editor renders with legacy sites, nested folders and imported tree")
                    fflush(stdout)
                } else if CommandLine.arguments.contains("--preview-settings") || CommandLine.arguments.contains("--preview-import") {
                    let page: LibraryPage = CommandLine.arguments.contains("--preview-import") ? .importer : .settings
                    var settings = store.settings
                    settings.linkPreviewDelay = 0
                    try? store.saveSettings(settings)
                    store.library = page
                    await settle()
                    if CommandLine.arguments.contains("--verify-preview") && page == .settings {
                        await verifySettingsFocus()
                        store.library = page
                        await settle()
                    }
                    if let view = panel.sheets.first?.contentView ?? panel.contentView,
                       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            try? png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
                                page == .importer ? "perch-import-layout.png" : "perch-settings-layout.png"))
                        }
                    }
                    print("PASS: isolated \(page.rawValue) page renders at the shared manager size")
                    fflush(stdout)
                } else if CommandLine.arguments.contains("--preview-passwords") {
                    _ = try? store.passwords.save([SavedPassword(origin: "https://example.com", username: "synthetic-user", password: "synthetic-secret")])
                    store.library = .passwords
                } else if CommandLine.arguments.contains("--preview-suggestions") {
                    _ = store.add(title: "示例书签", address: "http://127.0.0.1:9/fixture")
                    editAddress("示例")
                }
                if !CommandLine.arguments.contains("--verify-preview") {
                    try? await Task.sleep(nanoseconds: CommandLine.arguments.contains("--preview-bookmarks") ? 180_000_000_000 : 60_000_000_000)
                }
            }
            else {
                await run()
                await verifyHomeShortcutDrag()
                if !CommandLine.arguments.contains("--verify-address-input") { await verifyBookmarkEditor() }
            }
            defaults.removePersistentDomain(forName: suite)
            panel.orderOut(nil)
            exit(0)
        }
    }
    func table() -> TabTable {
        func find(_ view: NSView) -> TabTable? {
            if let table = view as? TabTable { return table }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(panel.contentView!)!
    }
    func settle() async { try? await Task.sleep(nanoseconds: 350_000_000) }
    func verifyBookmarkFolders() async {
        SelfTests.prepareAccessibility()
        func check(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            guard value() else { fputs("FAIL: bookmark folders \(line): \(message)\n", stderr); exit(1) }
        }
        store.library = nil
        let parent = BookmarkFolder(title: "Personal parent")
        let child = BookmarkFolder(title: "Personal child", parentID: parent.id)
        store.bookmarkFolders = [parent, child]
        store.sites = [Site(title: "Root bookmark", address: "https://root.invalid", showOnHome: false),
                       Site(title: "Nested bookmark", address: "https://nested.invalid", folderID: child.id),
                       Site(title: "Nested sibling", address: "https://sibling.invalid", folderID: child.id)]
        store.importedBookmarks = ["Chrome": [BookmarkNode(title: "Imported parent", children: [
            BookmarkNode(title: "Imported child", children: [BookmarkNode(title: "Imported bookmark", address: "https://imported.invalid")])
        ])]]
        defaults.set(try! JSONEncoder().encode(store.sites), forKey: "sites")
        defaults.set(try! JSONEncoder().encode(store.bookmarkFolders), forKey: "bookmarkFolders")
        await settle()
        var sheet: NSWindow = panel
        var visited: [ObjectIdentifier: NSObject] = [:]
        func button(_ node: Any, label: String, requireButtonRole: Bool = true) -> NSObject? {
            guard let object = node as? NSObject, visited[ObjectIdentifier(object)] == nil else { return nil }
            // Retain transient accessibility nodes so their addresses cannot be reused during traversal.
            visited[ObjectIdentifier(object)] = object
            let role = object.responds(to: NSSelectorFromString("accessibilityRole")) ? object.value(forKey: "accessibilityRole") as? String : nil
            let name = object.responds(to: NSSelectorFromString("accessibilityLabel")) ? object.value(forKey: "accessibilityLabel") as? String : nil
            if name == label && (!requireButtonRole || role == NSAccessibility.Role.button.rawValue) { return object }
            for child in (object as? NSView)?.subviews ?? [] {
                if let result = button(child, label: label, requireButtonRole: requireButtonRole) { return result }
            }
            for selector in ["accessibilityChildren", "accessibilityContents"] where object.responds(to: NSSelectorFromString(selector)) {
                for child in object.value(forKey: selector) as? [Any] ?? [] {
                    if let result = button(child, label: label, requireButtonRole: requireButtonRole) { return result }
                }
            }
            return nil
        }
        func click(_ label: String, in window: NSWindow? = nil) async {
            let window = window ?? sheet
            var target: NSObject?
            for _ in 0..<10 {
                visited.removeAll()
                target = button(window.contentView!, label: label, requireButtonRole: window !== panel)
                if target != nil { break }
                await settle()
            }
            guard let target else {
                check(false, "Missing real button \(label) in \(window === panel ? "home" : "manager"), scope \(store.libraryBookmarkScope)"); return
            }
            let frameValue = target.value(forKey: "accessibilityFrame")
            guard let frame = (frameValue as? NSValue)?.rectValue else {
                check(false, "Invalid frame for \(label): \(String(describing: frameValue)), \(target)"); return
            }
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            window.makeKeyAndOrderFront(nil)
            // SwiftUI's button gestures need AppKit to establish currentEvent through its queue.
            for type: NSEvent.EventType in [.leftMouseUp, .leftMouseDown] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!, atStart: true)
            }
            await settle()
        }
        let homeID = store.selected!
        let homeEntry = CommandLine.arguments.contains("--verify-home-bookmarks")
        if homeEntry {
            check(!store.homeShortcuts.contains { $0.title == "Root bookmark" },
                  "The home entry fixture must include a bookmark hidden from shortcuts")
            await click("全部书签", in: panel)
            check(store.library == .bookmarks && store.libraryBookmarkScope == .all,
                  "The actual home button must open the all-bookmarks scope")
        } else {
            store.openBookmarks()
            await settle()
        }
        guard let manager = panel.sheets.first else {
            check(false, "Bookmark entry must present the manager"); return
        }
        sheet = manager
        func find(_ view: NSView) -> BookmarkOutline? {
            if let table = view as? BookmarkOutline { return table }
            for subview in view.subviews { if let table = find(subview) { return table } }
            return nil
        }
        let table = find(sheet.contentView!)!
        let coordinator = table.delegate as! NativeBookmarks.Coordinator
        func events(at point: NSPoint, count: Int = 1) {
            sheet.makeKeyAndOrderFront(nil)
            for click in 1...count {
                func event(_ type: NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                        context: nil, eventNumber: click, clickCount: click, pressure: type == .leftMouseUp ? 0 : 1)!
                }
                NSApp.postEvent(event(.leftMouseUp), atStart: true)
                sheet.sendEvent(event(.leftMouseDown))
            }
        }
        func doubleClick(_ item: BookmarkListItem) async {
            let row = table.row(forItem: item)
            check(row >= 0, "Double-click target must be in the real outline")
            let rect = table.rect(ofRow: row)
            events(at: table.convert(NSPoint(x: 80, y: rect.midY), to: nil), count: 2)
            await settle()
        }
        func openFolder(_ id: UUID) async {
            guard let item = coordinator.roots.first(where: { $0.folderID == id }) else {
                check(false, "Open target must be in the current directory"); return
            }
            let row = table.row(forItem: item)
            check(row >= 0, "Open target must have a visible outline row")
            table.scrollRowToVisible(row)
            table.layoutSubtreeIfNeeded()
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as! BookmarkCell
            let point = cell.openButton.convert(NSPoint(x: cell.openButton.bounds.midX, y: cell.openButton.bounds.midY), to: nil)
            let root = sheet.contentView!
            var hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
            while let view = hit, view !== cell.openButton { hit = view.superview }
            check(hit != nil && !cell.openButton.isHidden, "The visible open button must receive the native click")
            events(at: point)
            await settle()
        }
        if homeEntry {
            check(coordinator.roots.contains { $0.key == "Chrome" } &&
                  coordinator.roots.first { $0.folderID == parent.id }?.children?.first?.folderID == child.id,
                  "Home all-bookmarks entry must include personal folder hierarchy and browser imports")
            let bookmark = coordinator.roots.first { $0.site?.title == "Root bookmark" }!
            let row = table.row(forItem: bookmark)
            table.scrollRowToVisible(row)
            table.layoutSubtreeIfNeeded()
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as! BookmarkCell
            let point = cell.openButton.convert(NSPoint(x: cell.openButton.bounds.midX,
                                                       y: cell.openButton.bounds.midY), to: nil)
            let root = sheet.contentView!
            var hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
            while let view = hit, view !== cell.openButton { hit = view.superview }
            check(hit != nil && !cell.openButton.isHidden, "The hidden-shortcut bookmark open button must receive the native click")
            events(at: point)
            await settle()
            let expectedAddress = URLInput.parse(bookmark.site!.address, search: false)!.absoluteString
            let openedAddress = store.tabs.first { $0.id == homeID }?.address
            check(store.library == nil && store.libraryBookmarkScope == .root && store.selected == homeID &&
                  openedAddress == expectedAddress,
                  "Opening a hidden-shortcut bookmark must use the current home tab and close/reset the manager (library \(String(describing: store.library)), scope \(store.libraryBookmarkScope), same tab \(store.selected == homeID), address \(String(describing: openedAddress)))")
            print("PASS: home all-bookmarks native button, complete personal/imported tree and hidden-shortcut bookmark navigation in the current home tab")
            fflush(stdout)
            return
        }
        await click("Chrome")
        let imported = coordinator.roots[0]
        check(!table.isItemExpanded(imported), "Import directory starts collapsed")
        await doubleClick(imported)
        check(table.isItemExpanded(imported), "First double-click must expand the imported directory")
        await doubleClick(imported)
        check(!table.isItemExpanded(imported), "Second double-click must collapse the imported directory")
        await click("个人书签")
        guard var personal = coordinator.roots.first(where: { $0.folderID == parent.id }) else {
            check(false, "Personal sidebar button must navigate to the personal tree"); return
        }
        check(personal.children?.first?.folderID == child.id &&
              personal.children?.first?.children?.count == 2, "Personal view must project the complete folder hierarchy")
        visited.removeAll()
        check(button(sheet.contentView!, label: parent.title) == nil, "Personal folders must not be repeated in the sidebar")
        await doubleClick(personal)
        check(table.isItemExpanded(personal), "Personal folders must expand on double-click")
        let nested = personal.children!.first!
        await doubleClick(nested)
        let first = nested.children![0], second = nested.children![1]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        check(board.writeObjects([coordinator.outlineView(table, pasteboardWriterForItem: first)!]) &&
              coordinator.beginDragPreview([first.site!.id]), "Expanded nested bookmarks must start sibling sorting")
        let drag = BookmarkTestDrag(board: board, table: table)
        let destination = table.rect(ofRow: table.row(forItem: second))
        drag.draggingLocation = table.convert(NSPoint(x: 100, y: destination.midY), to: nil)
        check(coordinator.outlineView(table, validateDrop: drag, proposedItem: nested, proposedChildIndex: 1) == .move,
              "Nested sibling drop must preview the reorder")
        await settle()
        check(nested.children!.map(\.site?.id) == [second.site!.id, first.site!.id],
              "Expanded child rows must reorder in their own directory")
        store.sites[1].title = "Nested metadata during drag"
        await settle()
        check(table.row(forItem: first) > table.row(forItem: second),
              "Nested metadata refresh must retain item identity and preview order")
        check(coordinator.outlineView(table, acceptDrop: drag, item: nested, childIndex: 1),
              "Nested reorder must persist without changing folder membership")
        await settle()
        check(store.sites.filter { $0.folderID == child.id }.map(\.id) == [second.site!.id, first.site!.id],
              "Nested sibling order must reach the shared bookmark model")
        personal = coordinator.roots.first { $0.folderID == parent.id }!
        await doubleClick(personal)
        check(!table.isItemExpanded(personal), "Personal folders must collapse on the next double-click")
        await click("全部书签")
        check(coordinator.roots.first { $0.folderID == parent.id }?.children?.first?.folderID == child.id,
              "All bookmarks must retain the personal directory hierarchy")
        check(coordinator.roots.contains { $0.key == "Chrome" }, "All bookmarks must retain the imported tree")
        await click("个人书签")
        check(!coordinator.roots.contains { $0.key == "Chrome" }, "Personal view must exclude imported roots")
        await openFolder(parent.id)
        check(coordinator.roots.first?.folderID == child.id && coordinator.roots.count == 1,
              "The folder's open button must navigate into that directory")
        await openFolder(child.id)
        check(coordinator.roots.map(\.site?.title) == ["Nested sibling", "Nested metadata during drag"],
              "Opening a nested folder must show only its contents")
        await click("返回上一级")
        check(coordinator.roots.first?.folderID == child.id, "Back must return to the parent directory")
        await click("返回上一级")
        check(coordinator.roots.contains { $0.folderID == parent.id }, "Back from a root folder must return to personal bookmarks")
        visited.removeAll()
        check(button(sheet.contentView!, label: "返回上一级") == nil, "Root view must not offer a dead back action")
        store.library = nil
        await settle()
        print("PASS: real directory double-click expand/collapse, matching personal/all folder hierarchy, nested sibling drag/metadata/drop, sidebar without duplicate folders, open-button navigation and two-level back-button hit paths")
        fflush(stdout)
    }
    func verifyBookmarkDrag() async {
        func check(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            guard value() else { fputs("FAIL: bookmark drag \(line): \(message)\n", stderr); exit(1) }
        }
        store.library = nil
        await settle()
        let folder = BookmarkFolder(title: "Drag folder")
        store.bookmarkFolders = [folder]
        store.sites = (0..<6).map { Site(title: "Bookmark drag \($0)", address: "https://drag-\($0).invalid",
                                        folderID: $0 == 5 ? folder.id : nil) }
        let ids = store.sites.map(\.id), home = store.homeShortcuts.map(\.id)
        defaults.set(try! JSONEncoder().encode(store.sites), forKey: "sites")
        defaults.set(try! JSONEncoder().encode(store.bookmarkFolders), forKey: "bookmarkFolders")
        let originalData = defaults.data(forKey: "sites")
        store.library = .bookmarks
        await settle()
        func find(_ view: NSView) -> BookmarkOutline? {
            if let table = view as? BookmarkOutline { return table }
            for child in view.subviews { if let table = find(child) { return table } }
            return nil
        }
        let sheet = panel.sheets.first!, table = find(sheet.contentView!)!
        let coordinator = table.delegate as! NativeBookmarks.Coordinator
        check(coordinator.responds(to: NSSelectorFromString("outlineView:draggingSession:willBeginAtPoint:forItems:")),
              "AppKit must recognize the custom drag-image source callback")
        let source = coordinator.roots.first { $0.id == ids[1] }!
        let cell = table.view(atColumn: 0, row: table.row(forItem: source), makeIfNecessary: true) as! BookmarkCell
        for point in [NSPoint(x: 7, y: 18), NSPoint(x: 45, y: 10), NSPoint(x: cell.bounds.midX, y: 28)] {
            let location = cell.convert(point, to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            NSApp.postEvent(event(.leftMouseUp), atStart: true)
            NSApp.sendEvent(event(.leftMouseDown))
            check(sheet.firstResponder === table && coordinator.parent.selection == [ids[1]],
                  "Icon, title and address presses must reach the native list")
        }
        let image = cell.dragPreview(radius: 9, background: NSColor(Style.paper))!
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let alpha = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.alphaComponent
        check((0.85...0.91).contains(alpha), "Bookmark floating row must have opacity 0.88")
        try? bitmap.representation(using: .png, properties: [:])?.write(to:
            FileManager.default.temporaryDirectory.appendingPathComponent("perch-bookmark-drag-card.png"))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let drag = BookmarkTestDrag(board: board, table: table)
        func begin(_ selected: Set<UUID>) {
            table.selectRowIndexes(IndexSet((0..<table.numberOfRows).filter {
                (table.item(atRow: $0) as? BookmarkListItem)?.id.map(selected.contains) == true
            }), byExtendingSelection: false)
            board.clearContents()
            check(board.writeObjects(coordinator.roots.filter { $0.id.map(selected.contains) == true }.map {
                coordinator.outlineView(table, pasteboardWriterForItem: $0)!
            }), "Native writer must write every moving bookmark")
            check(coordinator.beginDragPreview(selected), "Editable rows must begin a local preview")
        }
        func move(to id: UUID) -> NSDragOperation {
            let target = coordinator.roots.first { $0.id == id }!
            let rect = table.rect(ofRow: table.row(forItem: target))
            drag.draggingLocation = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            return coordinator.outlineView(table, validateDrop: drag, proposedItem: nil, proposedChildIndex: 0)
        }
        func visible() -> [UUID] { coordinator.roots.filter { $0.site != nil }.compactMap(\.id) }
        begin([ids[1]])
        check(move(to: ids[3]) == .move && visible() == [ids[0], ids[2], ids[3], ids[1], ids[4]],
              "Dragging down must reorder the visible bookmark rows")
        await settle()
        check(table.row(for: cell) == 4 && cell.isHidden && defaults.data(forKey: "sites") == originalData,
              "Native outline rows must move while source is hidden and persistence is unchanged")
        check(coordinator.parent.selection == [ids[1]], "Preview must retain selection")
        store.sites[1].title = "Metadata refreshed during drag"
        await settle()
        check(visible().suffix(2) == [ids[1], ids[4]] && cell.isHidden,
              "Metadata refresh must preserve preview order and placeholder")
        check(table.row(forItem: source) == 4 && cell.name.stringValue == "Metadata refreshed during drag",
              "Metadata must refresh the actual row while retaining its native item identity")
        table.draggingExited(drag)
        await settle()
        check(visible() == Array(ids.prefix(5)), "Leaving the list must restore the original order")
        coordinator.endDragPreview()
        check(!cell.isHidden, "Cancellation must show the original row")
        begin([ids[1]])
        check(move(to: ids[3]) == .move && visible() == [ids[0], ids[2], ids[3], ids[1], ids[4]],
              "Dragging after a metadata refresh must still find the native destination rows")
        let foreign = BookmarkTestDrag(board: board, table: sheet.contentView!)
        check(!coordinator.outlineView(table, acceptDrop: foreign, item: nil, childIndex: 0),
              "Another drag source must not commit this preview")
        check(coordinator.outlineView(table, acceptDrop: drag, item: nil, childIndex: 0), "Local drop must save")
        await settle()
        let accepted = [ids[0], ids[2], ids[3], ids[1], ids[4], ids[5]]
        check(store.sites.map(\.id) == accepted && store.homeShortcuts.map(\.id) == home &&
              Store(defaults: defaults).sites.map(\.id) == accepted, "Drop must persist bookmarks independently of home order")
        begin([ids[0], ids[2]]); _ = move(to: ids[4])
        check(Array(visible().suffix(2)) == [ids[0], ids[2]], "Multiple dragged rows must retain relative order")
        coordinator.endDragPreview()
        begin([ids[1]]); _ = move(to: ids[0])
        let reorder = coordinator.parent.reorder
        coordinator.parent.reorder = { _ in false }
        check(!coordinator.outlineView(table, acceptDrop: drag, item: nil, childIndex: 0) &&
              visible() == Array(accepted.prefix(5)), "A rejected save must restore the visible order")
        coordinator.parent.reorder = reorder
        begin([ids[1]])
        check(move(to: folder.id) == .move, "Folder drops must retain their existing behavior")
        let destination = coordinator.roots.first { $0.folderID == folder.id }!
        check(coordinator.outlineView(table, acceptDrop: drag, item: destination, childIndex: -1),
              "Dropping onto a folder must move membership")
        coordinator.endDragPreview()
        await settle()
        check(store.sites.first { $0.id == ids[1] }?.folderID == folder.id && store.homeShortcuts.map(\.id) == home,
              "Folder move must keep the independent homepage order")
        begin([ids[0]]); _ = move(to: ids[4])
        store.sites.append(Site(title: "New during drag", address: "https://new-during-drag.invalid"))
        await settle()
        check(coordinator.dragIDs.isEmpty, "External structure changes must cancel the preview")
        let imported = BookmarkListItem(key: "readonly-fixture", site: Site(title: "Readonly", address: "https://readonly.invalid"))
        check(coordinator.outlineView(table, pasteboardWriterForItem: imported) == nil &&
              !coordinator.beginDragPreview([imported.site!.id]), "Imported rows must remain read-only")
        store.library = nil
        await settle()
        print("PASS: bookmark icon/title/address native press path, translucent floating row, live outline moves, selection and metadata retention, cancel/exit, local drop/restart, independent home order, multiple rows, rejected save, folder move and read-only boundary; drag source capture and destination use synthetic local fixtures")
        fflush(stdout)
    }
    func verifyTabDrag() async {
        func check(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            guard value() else { fputs("FAIL: tab drag \(line): \(message)\n", stderr); exit(1) }
        }
        let savedTabs = store.tabs, savedGroups = store.tabGroups, savedSelection = store.selected
        let savedCompact = defaults.bool(forKey: "sidebarHidden")
        store.library = nil
        store.tabGroups = []
        store.tabs = (0..<5).map { Tab(title: "Drag fixture \($0)", address: "", pinned: $0 == 0) }
        let ids = store.tabs.map(\.id)
        store.activate(ids[1])
        await settle()
        let table = table()
        let coordinator = table.delegate as! NativeTabList.Coordinator
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let drag = BookmarkTestDrag(board: board, table: table)
        func begin(_ id: UUID) {
            let row = table.ids.firstIndex(of: id)!
            board.clearContents()
            check(board.writeObjects([coordinator.tableView(table, pasteboardWriterForRow: row)!]),
                  "Native source must write its row identity")
            table.beginDrag(at: row)
            table.refreshDragPlaceholder()
        }
        func move(_ row: Int) -> NSDragOperation {
            drag.draggingLocation = table.convert(NSPoint(x: 20, y: CGFloat(row) * table.rowHeight + 18), to: nil)
            return coordinator.tableView(table, validateDrop: drag, proposedRow: row, proposedDropOperation: .above)
        }
        func click(_ point: NSPoint) {
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            NSApp.postEvent(event(.leftMouseUp), atStart: true)
            NSApp.sendEvent(event(.leftMouseDown))
        }
        for compact in [false, true] {
            defaults.set(compact, forKey: "sidebarHidden")
            await settle()
            check(!table.animatingRows && !table.animatingGroups, "Pointer checks require settled rows")
            let row = table.ids.firstIndex(of: ids[1])!
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as! TabCell
            let prepare = table.prepareSelection
            var presses = 0
            table.prepareSelection = { presses += 1; prepare?() }
            let points = compact ? [NSPoint(x: cell.bounds.midX, y: cell.bounds.midY)] :
                [NSPoint(x: 15, y: cell.bounds.midY), NSPoint(x: 60, y: cell.bounds.midY),
                 NSPoint(x: cell.bounds.maxX - 3, y: cell.bounds.midY)]
            for point in points { click(cell.convert(point, to: nil)) }
            table.prepareSelection = prepare
            check(presses == points.count && store.selected == ids[1],
                  "Icon, title and whitespace presses must reach the native table's drag entry")
            let image = cell.dragImage()
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let alpha = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.alphaComponent
            check((0.85...0.91).contains(alpha), "Complete floating tab must have opacity 0.88")
            try? bitmap.representation(using: .png, properties: [:])?.write(to:
                FileManager.default.temporaryDirectory.appendingPathComponent("perch-tab-drag-\(compact).png"))
            begin(ids[1])
            check(move(4) == .move && table.ids == [ids[0], ids[2], ids[3], ids[4], ids[1]],
                  "Dragging down must reorder the displayed rows")
            await settle()
            check(store.tabs.map(\.id) == ids && cell.content.isHidden,
                  "Live reflow must preserve committed order and hide the source")
            check(table.row(for: cell) == 4, "Actual source cell must move to the preview slot")
            store.tabs[1].title = "Metadata during drag"
            await settle()
            check(table.ids.last == ids[1] && cell.content.isHidden, "Metadata refresh must retain preview")
            table.endDragPreview()
            await settle()
            check(table.ids == ids && !cell.content.isHidden, "Cancel must restore rows and source")
            begin(ids[0]); _ = move(4)
            check(table.ids.first == ids[0], "Pinned source cannot leave the pinned section")
            table.endDragPreview()
            begin(ids[1]); _ = move(0)
            check(table.ids.first == ids[0], "Ordinary source cannot enter the pinned section")
            table.endDragPreview()
        }
        begin(ids[1]); _ = move(4)
        let foreign = BookmarkTestDrag(board: board, table: panel.contentView!)
        check(!coordinator.tableView(table, acceptDrop: foreign, row: 4, dropOperation: .above),
              "Foreign source must be rejected")
        check(coordinator.tableView(table, acceptDrop: drag, row: 4, dropOperation: .above),
              "Accepted local drop must commit")
        await settle()
        check(store.tabs.map(\.id) == [ids[0], ids[2], ids[3], ids[4], ids[1]] && table.dragID == nil,
              "Drop must commit order and clear preview")
        let group = store.createTabGroup(ids[2])!
        await settle()
        let groupCell = table.view(atColumn: 0, row: table.ids.firstIndex(of: group)!, makeIfNecessary: true)!
        let groupImage = groupCell.dragPreview(radius: 9)!
        let groupBitmap = NSBitmapImageRep(data: groupImage.tiffRepresentation!)!
        let groupAlpha = groupBitmap.colorAt(x: groupBitmap.pixelsWide / 2, y: groupBitmap.pixelsHigh / 2)!.alphaComponent
        check((0.85...0.91).contains(groupAlpha), "Group preview must share tab transparency")
        begin(ids[3])
        drag.draggingLocation = table.convert(NSPoint(x: 20, y: CGFloat(table.ids.firstIndex(of: group)!) * 36 + 18), to: nil)
        check(coordinator.tableView(table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .above) == .move,
              "Group body must accept a tab preview")
        check(coordinator.tabs.first { $0.id == ids[3] }?.groupID == group &&
              store.tabs.first { $0.id == ids[3] }?.groupID == nil, "Group preview must not persist membership")
        table.endDragPreview()
        store.tabs = savedTabs; store.tabGroups = savedGroups; store.selected = savedSelection
        defaults.set(savedCompact, forKey: "sidebarHidden")
        await settle()
        print("PASS: tab icon/title/edge native press routing, compact/expanded translucent previews, live row reflow, metadata refresh, pinned boundaries, cancellation, local commit and group preview; source session and destination callbacks use synthetic local drag info")
        fflush(stdout)
    }
    func verifyHomeShortcutDrag() async {
        do { try await HomePageSelfCheck.drag(store: store, panel: panel) }
        catch { fputs("FAIL: HTML home drag: \(error)\n", stderr); exit(1) }
    }
    private func clickInPanel(_ point: NSPoint) async {
        NSApp.activate(ignoringOtherApps: true)
        panel.focusWindow()
        for _ in 0..<60 where !NSApp.isActive || !panel.isKeyWindow {
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        guard NSApp.isActive && panel.isKeyWindow else {
            fputs("FAIL: native click checks require an active isolated window: active=\(NSApp.isActive), key=\(panel.isKeyWindow)\n", stderr)
            exit(1)
        }
        // Queue the release for AppKit's tracking loop, then dispatch the press before sampling.
        NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!, atStart: true)
        NSApp.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
    }
    func verifyTabGroups() async {
        // Keep assertion locations available in the stripped release executable used by UI checks.
        func precondition(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
            if !condition() { fputs("FAIL: tab groups line \(line): \(message)\n", stderr); exit(1) }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.focusWindow()
        await settle()
        let savedTabs = store.tabs, savedGroups = store.tabGroups, savedSelection = store.selected
        let savedClosed = store.recentlyClosed
        store.tabs = (0..<4).map { Tab(title: "分组合成标签 \($0 + 1)", address: "") }
        store.tabGroups = []
        let ids = store.tabs.map(\.id)
        let group = store.createTabGroup(ids[0])!
        store.editTabGroup(group, name: "CICD", color: .blue)
        store.moveTab(ids[1], to: 1, groupID: group)
        store.activate(ids[1])
        await settle()
        let table = table()
        let coordinator = table.delegate as! NativeTabList.Coordinator
        precondition(table.ids == [group, ids[0], ids[1], ids[2], ids[3]])
        let groupCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! TabGroupCell
        let groupedRow = table.rowView(atRow: 1, makeIfNecessary: true) as! TabSelectionRow
        precondition(groupedRow.groupColor != nil && groupedRow.extraLeadingInset == 7)
        let point = groupCell.convert(NSPoint(x: groupCell.bounds.midX, y: groupCell.bounds.midY), to: nil)
        func click(_ location: NSPoint) async {
            await clickInPanel(location)
        }
        func clickHeader() async { await click(point) }
        panel.focusWindow()
        await clickHeader()
        await settle()
        precondition(store.tabGroups[0].collapsed && table.ids == [group, ids[1], ids[2], ids[3]] &&
                     store.selected == ids[1] && store.tabs.filter { $0.groupID == group }.map(\.id) == [ids[0], ids[1]],
                     "Collapse must display the active tab below its group without changing selection or membership: collapsed=\(store.tabGroups[0].collapsed), actual=\(table.ids), selected=\(String(describing: store.selected)), progress=\((table.enclosingScrollView!.superview as! TabListContainer).railViews[group]?.progress ?? -1)")
        precondition((table.rowView(atRow: 1, makeIfNecessary: true) as? TabSelectionRow)?.groupColor == nil,
                     "The temporary active tab must appear outside the group rail")
        await click(table.convert(NSPoint(x: 20, y: table.rect(ofRow: 1).midY), to: nil))
        await settle()
        precondition(store.tabGroups[0].collapsed, "Clicking the already active outside row must not expand its group")
        let restored = Store(defaults: defaults)
        precondition(restored.tabGroups.first?.name == "CICD" && restored.tabGroups.first?.color == .blue &&
                     restored.tabGroups.first?.collapsed == true && restored.tabs.filter { $0.groupID == group }.count == 2)
        await settle()
        let otherPoint = table.convert(NSPoint(x: 20, y: table.rect(ofRow: 2).midY), to: nil)
        await click(otherPoint)
        await settle()
        precondition(store.selected == ids[2] && table.ids == [group, ids[2], ids[3]] &&
                     store.tabs.first { $0.id == ids[1] }?.groupID == group,
                     "Switching away must remove only the temporary row")
        await clickHeader()
        await settle()
        precondition(!store.tabGroups[0].collapsed && table.ids.count == 5)
        NSApp.sendEvent(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!)
        await settle()
        precondition(coordinator.editor?.isShown == true, "Right-click must open the native group editor")
        if let view = coordinator.editor?.contentViewController?.view,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: FileManager.default.temporaryDirectory.appendingPathComponent("perch-group-editor.png"))
        }
        if let editor = coordinator.editor?.contentViewController?.view.window?.firstResponder as? NSTextView {
            editor.insertText("发布", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            await settle()
            precondition(store.tabGroups[0].name == "发布", "Native text editing must save the group name")
        } else { preconditionFailure("Group editor must focus its name field") }
        coordinator.editor?.close()
        await settle()
        store.toggleTabGroup(group)
        store.activate(ids[1])
        await settle()
        precondition(!store.tabGroups[0].collapsed && store.selected == ids[1])

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let drag = BookmarkTestDrag(board: board, table: table)
        func begin(_ id: UUID) {
            board.clearContents(); board.setString(id.uuidString, forType: .string)
            table.beginDrag(at: table.ids.firstIndex(of: id)!)
        }
        func move(_ point: NSPoint) -> NSDragOperation {
            drag.draggingLocation = table.convert(point, to: nil)
            return coordinator.tableView(table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .above)
        }
        func drop() -> Bool { coordinator.tableView(table, acceptDrop: drag, row: 0, dropOperation: .above) }
        begin(ids[2])
        precondition(move(NSPoint(x: 20, y: 18)) == .move)
        await settle()
        precondition(store.tabs.first { $0.id == ids[2] }?.groupID == nil &&
                     coordinator.tabs.first { $0.id == ids[2] }?.groupID == group,
                     "Drag preview must join the target without writing persisted membership")
        store.tabs[2].title = "拖动时标题更新"
        await settle()
        precondition(coordinator.tabs.first { $0.id == ids[2] }?.groupID == group)
        table.endDragPreview()
        await settle()
        precondition(table.ids == [group, ids[0], ids[1], ids[2], ids[3]])
        begin(ids[2]); _ = move(NSPoint(x: 20, y: 18))
        precondition(drop())
        await settle()
        precondition(store.tabs.first { $0.id == ids[2] }?.groupID == group)
        begin(ids[2]); _ = move(NSPoint(x: 20, y: CGFloat(table.ids.count) * 36 + 4))
        precondition(drop())
        await settle()
        precondition(store.tabs.last?.id == ids[2] && store.tabs.last?.groupID == nil)
        begin(ids[0])
        let ownRowY = CGFloat(table.ids.firstIndex(of: ids[0])!) * 36 + 18
        _ = move(NSPoint(x: 3, y: ownRowY))
        precondition(coordinator.tabs.first { $0.id == ids[0] }?.groupID == nil,
                     "Horizontal dragging into the gutter must leave the group even from the source row")
        table.endDragPreview()
        await settle()
        let second = store.createTabGroup(ids[3])!
        store.editTabGroup(second, name: "资料", color: .purple)
        await settle()
        begin(ids[1])
        let secondY = CGFloat(table.ids.firstIndex(of: second)!) * 36 + 18
        _ = move(NSPoint(x: 20, y: secondY))
        precondition(drop())
        await settle()
        precondition(store.tabs.first { $0.id == ids[1] }?.groupID == second)
        store.toggleTabGroup(group)
        await settle()
        begin(ids[2]); _ = move(NSPoint(x: 20, y: 18))
        precondition(drop())
        await settle()
        precondition(store.tabGroups.first { $0.id == group }!.collapsed &&
                     !table.ids.contains(ids[2]), "Dropping into a collapsed header preserves its collapsed state")
        store.toggleTabGroup(group)
        await settle()
        begin(group)
        _ = move(NSPoint(x: 20, y: CGFloat(table.ids.count) * 36 + 4))
        await settle()
        precondition(!table.ids.contains(ids[0]) && !store.tabGroups.first { $0.id == group }!.collapsed,
                     "Whole-group drag collapse is only a presentation state")
        table.endDragPreview()
        await settle()
        precondition(table.ids.contains(ids[0]) && table.ids.first == group)
        begin(group); _ = move(NSPoint(x: 20, y: CGFloat(table.ids.count) * 36 + 4))
        precondition(drop())
        await settle()
        precondition(store.tabs.suffix(2).allSatisfy { $0.groupID == group } && table.ids.contains(ids[0]))
        store.pin(ids[0])
        await settle()
        begin(ids[0])
        precondition(move(NSPoint(x: 20, y: CGFloat(table.ids.count) * 36)) == [])
        table.endDragPreview()
        precondition(store.tabs[0].groupID == nil && store.tabs[0].pinned)
        store.newTab(inGroup: second)
        let added = store.selected!
        precondition(store.tabs.first { $0.id == added }?.groupID == second)
        store.close(added); store.reopen()
        precondition(store.tabs.first { $0.id == store.selected }?.groupID == second)
        await settle()
        for compact in [false, true] {
            defaults.set(compact, forKey: "sidebarHidden")
            await settle()
            for row in table.ids.indices {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabCell {
                    precondition(table.convert(cell.icon.bounds, from: cell.icon).maxX <= table.bounds.maxX + 1)
                    if compact, let selection = table.rowView(atRow: row, makeIfNecessary: true) as? TabSelectionRow {
                        precondition(selection.extraLeadingInset == 0 &&
                                     abs(cell.icon.frame.midX - cell.bounds.midX) < 0.5,
                                     "Compact grouped icons and selection backgrounds must share the rail center")
                        if store.tabs.first(where: { $0.id == table.ids[row] })?.groupID != nil {
                            let container = table.enclosingScrollView!.superview as! TabListContainer
                            let highlightLeft = container.convert(selection.bounds, from: selection).minX + selection.horizontalInset
                            precondition(highlightLeft - TabListContainer.railGutter >= 2,
                                         "A 2pt rail in the left gutter must retain a gap before the highlight")
                        }
                    }
                }
            }
            if let root = panel.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: FileManager.default.temporaryDirectory.appendingPathComponent(compact ? "perch-groups-compact.png" : "perch-groups-expanded.png"))
                for row in table.ids.indices {
                    guard let header = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabGroupCell else { continue }
                    func color(_ x: CGFloat) -> NSColor {
                        let point = header.convert(NSPoint(x: x, y: header.bounds.midY), to: root)
                        return bitmap.colorAt(x: Int(point.x * CGFloat(bitmap.pixelsWide) / root.bounds.width),
                            y: Int((root.isFlipped ? point.y : root.bounds.height - point.y) *
                                   CGFloat(bitmap.pixelsHigh) / root.bounds.height))!.usingColorSpace(.deviceRGB)!
                    }
                    for (outside, inside) in [(CGFloat(1), CGFloat(3)), (header.bounds.width - 1, header.bounds.width - 3)] {
                        let a = color(outside), b = color(inside)
                        precondition(abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) +
                                     abs(a.blueComponent - b.blueComponent) > 0.2,
                                     "Group button edges must match the tab highlight's 2pt horizontal inset: compact=\(compact), row=\(row), bounds=\(header.bounds), outside=\(outside):\(a), inside=\(inside):\(b)")
                    }
                }
                for row in 1..<coordinator.rows.count {
                    guard case .tab(let current) = coordinator.rows[row],
                          case .tab(let previous) = coordinator.rows[row - 1],
                          let groupID = store.tabs.first(where: { $0.id == current })?.groupID,
                          store.tabs.first(where: { $0.id == previous })?.groupID == groupID else { continue }
                    let lineX: CGFloat = compact ? -2 : 3
                    let samples: [CGFloat] = [0.25, 0.75, 1.25, 1.75]
                    for x in samples.map({ lineX + $0 }) {
                        for offset: CGFloat in [-0.75, -0.25, 0.25, 0.75] {
                            let point = table.convert(NSPoint(x: x, y: table.rect(ofRow: row).minY + offset), to: root)
                            let pixelX = Int(point.x * CGFloat(bitmap.pixelsWide) / root.bounds.width)
                            let pixelY = Int((root.isFlipped ? point.y : root.bounds.height - point.y) *
                                             CGFloat(bitmap.pixelsHigh) / root.bounds.height)
                            let actual = bitmap.colorAt(x: pixelX, y: pixelY)!.usingColorSpace(.deviceRGB)!
                            // Compare in the captured display color space, not against the model's sRGB value.
                            let color = bitmap.colorAt(x: pixelX, y: pixelY - 8)!.usingColorSpace(.deviceRGB)!
                            let background = bitmap.colorAt(x: pixelX + 5, y: pixelY - 8)!.usingColorSpace(.deviceRGB)!
                            precondition(abs(color.redComponent - background.redComponent) +
                                         abs(color.greenComponent - background.greenComponent) > 0.2,
                                         "The sampled column must contain the group line, not sidebar whitespace")
                            precondition(abs(actual.redComponent - color.redComponent) < 0.025 &&
                                         abs(actual.greenComponent - color.greenComponent) < 0.025 &&
                                         abs(actual.blueComponent - color.blueComponent) < 0.025,
                                         "Group line join: compact=\(compact), row=\(row), pixel=(\(pixelX),\(pixelY)), actual=\(actual), expected=\(color)")
                        }
                    }
                }
            }
            let active = store.selected!
            let membership = store.tabs.map(\.groupID)
            store.toggleTabGroup(second)
            await settle()
            let headerRow = table.ids.firstIndex(of: second)!
            precondition(table.ids[headerRow + 1] == active &&
                         (table.rowView(atRow: headerRow + 1, makeIfNecessary: true) as? TabSelectionRow)?.groupColor == nil &&
                         store.tabs.map(\.groupID) == membership && store.tabGroups.first { $0.id == second }!.collapsed,
                         "Both sidebar widths must show the active tab outside its collapsed group")
            store.selected = nil
            await settle()
            precondition(!table.ids.contains(active) && store.tabs.map(\.groupID) == membership,
                         "Returning home must remove the temporary row without moving the tab")
            store.activate(active)
            await settle()
            precondition(!store.tabGroups.first { $0.id == second }!.collapsed &&
                         table.ids.filter { $0 == active }.count == 1,
                         "Reactivating a hidden grouped tab must restore one regular grouped row")
        }
        defaults.set(false, forKey: "sidebarHidden")
        store.ungroup(second)
        store.deleteTabGroup(group)
        await settle()
        precondition(!store.tabGroups.contains { $0.id == group || $0.id == second })
        store.tabs = savedTabs; store.tabGroups = savedGroups; store.selected = savedSelection
        store.recentlyClosed = savedClosed
        await settle()
        print("PASS: group header event path, colors, persistence, collapse/select, native drag validation/acceptance into/out/across groups, cancellation, whole-group moves, pin boundary, reopen and compact layout")
    }
    func verifySavedGroupManager(_ group: UUID) async {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fputs("FAIL: saved group manager: \(message)\n", stderr); exit(1) }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.sheets.first?.makeKeyAndOrderFront(nil)
        SelfTests.prepareAccessibility()
        await settle()
        var visited = Set<ObjectIdentifier>()
        func children(_ object: NSObject) -> [Any] {
            let views: [Any] = (object as? NSView)?.subviews ?? []
            for key in ["accessibilityChildren", "accessibilityRows", "accessibilityVisibleRows"] {
                if object.responds(to: NSSelectorFromString(key)),
                   let values = object.value(forKey: key) as? [Any], !values.isEmpty { return views + values }
            }
            return views
        }
        func element(_ node: Any, label: String) -> NSObject? {
            guard let object = node as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityLabel")),
               object.responds(to: NSSelectorFromString("accessibilityPerformPress")),
               object.value(forKey: "accessibilityLabel") as? String == label { return object }
            for child in children(object) {
                if let button = element(child, label: label) { return button }
            }
            return nil
        }
        func press(_ root: NSView, _ label: String) async {
            visited.removeAll()
            guard let button = element(root, label: label) else {
                visited.removeAll()
                func labels(_ node: Any) -> [String] {
                    guard let object = node as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
                    let own = object.responds(to: NSSelectorFromString("accessibilityLabel")) ?
                        (object.value(forKey: "accessibilityLabel") as? String).map { [$0] } ?? [] : []
                    return own + children(object).flatMap(labels)
                }
                fputs("Visible labels: \(labels(root))\n", stderr)
                if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to:
                        FileManager.default.temporaryDirectory.appendingPathComponent("perch-saved-group-failure.png"))
                }
                fputs("FAIL: saved group button missing: \(label)\n", stderr); exit(1)
            }
            _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
            await settle()
        }
        func find(_ root: NSView) -> BookmarkOutline? {
            (root as? BookmarkOutline) ?? root.subviews.lazy.compactMap(find).first
        }
        func clickScope(_ root: NSView, _ label: String, trailing: Bool) async {
            visited.removeAll()
            guard let button = element(root, label: label),
                  let frame = (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
                  let window = root.window else {
                fputs("FAIL: saved group sidebar geometry: \(label)\n", stderr); exit(1)
            }
            check(frame.width > 100, "Sidebar buttons must span the row")
            let point = window.convertPoint(fromScreen: NSPoint(x: trailing ? frame.maxX - 2 : frame.minX + 2, y: frame.midY))
            NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!, atStart: true)
            NSApp.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            await settle()
        }
        func clickOpen(_ table: BookmarkOutline, row: Int) async {
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as! BookmarkCell
            let window = table.window!
            window.makeKeyAndOrderFront(nil)
            let point = cell.openButton.convert(NSPoint(x: cell.openButton.bounds.midX, y: cell.openButton.bounds.midY), to: nil)
            let hit = window.contentView?.hitTest(window.contentView!.superview?.convert(point, from: nil) ?? point)
            var ancestor = hit
            while let view = ancestor, view !== cell.openButton { ancestor = view.superview }
            check(ancestor != nil, "Open button must receive the event across its visible bounds")
            NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!, atStart: true)
            window.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            await settle()
        }
        let sheet = panel.sheets.first!, root = sheet.contentView!
        visited.removeAll()
        check(element(root, label: "全部标签组") == nil, "The redundant all-groups entry must be absent")
        await clickScope(root, "隐藏资料", trailing: true)
        let list = find(root)!
        let coordinator = list.dataSource as! NativeBookmarks.Coordinator
        check(list.numberOfRows == 2 && coordinator.roots.allSatisfy { $0.groupID == group && $0.site != nil },
              "Clicking the trailing blank area must open the saved group's tabs")
        await clickScope(root, "个人书签", trailing: true)
        check(coordinator.roots.allSatisfy { $0.groupID == nil }, "Other sidebar rows must also accept trailing clicks")
        await clickScope(root, "隐藏资料", trailing: false)
        check(list.numberOfRows == 2 && coordinator.roots.allSatisfy { $0.groupID == group },
              "The leading edge must also open the saved group's tabs")
        let menu = coordinator.menu(0)!
        check(menu.items.map(\.title) == ["打开标签页", "复制网址"],
              "Saved tab menus must expose their own tab actions")
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to:
                FileManager.default.temporaryDirectory.appendingPathComponent("perch-saved-groups.png"))
        }
        let members = store.tabs(inGroup: group).map(\.id)
        await clickOpen(list, row: 1)
        check(store.library == nil && store.selected == members[1], "A saved tab click must restore and select that tab")
        check(store.tabs.filter { $0.groupID == group }.map(\.id) == members, "Restoring a saved tab must reopen its group once")
        let tabCoordinator = table().delegate as! NativeTabList.Coordinator
        tabCoordinator.editGroup(group)
        await settle()
        let editor = tabCoordinator.editor!.contentViewController!.view
        check(editor.bounds.width <= 250, "The group menu must keep its compact width")
        check(editor.bounds.height < 235, "The group menu must reduce vertical whitespace")
        visited.removeAll()
        let hoverButton = element(editor, label: "隐藏分组")!
        let hoverFrame = (hoverButton.value(forKey: "accessibilityFrame") as! NSValue).rectValue
        let hoverWindow = editor.window!
        let hoverPoint = hoverWindow.convertPoint(fromScreen: NSPoint(x: hoverFrame.maxX - 12, y: hoverFrame.midY))
        func backgroundSample(at location: NSPoint) -> NSColor {
            let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds)!
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            let point = editor.convert(location, from: nil)
            let x = Int(point.x / editor.bounds.width * CGFloat(bitmap.pixelsWide))
            let y = Int((editor.isFlipped ? point.y : editor.bounds.height - point.y) / editor.bounds.height * CGFloat(bitmap.pixelsHigh))
            return bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        }
        func move(_ point: NSPoint, in window: NSWindow) async {
            NSApp.sendEvent(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!)
            await settle()
        }
        func hoverRegions(_ view: NSView) -> [TabGroupMenuHoverView] {
            (view as? TabGroupMenuHoverView).map { [$0] } ?? view.subviews.flatMap(hoverRegions)
        }
        let regions = hoverRegions(editor)
        check(regions.count == TabGroupColor.allCases.count + 4 && hoverWindow.acceptsMouseMovedEvents,
              "Every menu button must have a native hover region and the popover must accept mouse moves")
        check(regions.allSatisfy { region in
            region.trackingAreas.contains { $0.options.contains(.activeAlways) &&
                $0.rect == region.bounds.intersection(region.visibleRect) }
        }, "Popover tracking must stay within each button's bounds and work independently of key-window status")
        await move(.zero, in: panel)
        let idleBackground = backgroundSample(at: hoverPoint)
        await move(hoverPoint, in: hoverWindow)
        let hoveredBackground = backgroundSample(at: hoverPoint)
        check(abs(hoveredBackground.alphaComponent - idleBackground.alphaComponent) +
              abs(hoveredBackground.redComponent - idleBackground.redComponent) > 0.04,
              "A mouse move over the menu's blank area must visibly paint its hover background")
        check(regions.filter(\.hovered).count == 1, "Only the button under the pointer may be highlighted")
        for region in regions {
            let point = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
            await move(point, in: hoverWindow)
            check(region.hovered && regions.filter(\.hovered).count == 1,
                  "Moving between action rows and colors must transfer the hover state")
            check(region.hitTest(.zero) == nil, "Decorative hover tracking must not intercept clicks")
        }
        store.editTabGroup(group, name: "悬停时更新名称")
        await settle()
        check(hoverRegions(editor).filter(\.hovered).count == 1, "An editor redraw must preserve its hover state")
        await move(.zero, in: panel)
        let restoredBackground = backgroundSample(at: hoverPoint)
        check(hoverRegions(editor).allSatisfy { !$0.hovered } &&
              abs(restoredBackground.alphaComponent - idleBackground.alphaComponent) < 0.01 &&
              abs(restoredBackground.redComponent - idleBackground.redComponent) < 0.01,
              "Leaving the popover must clear both hover state and rendered highlight")
        store.editTabGroup(group, name: "隐藏资料")
        await clickScope(editor, "隐藏分组", trailing: true)
        check(!table().ids.contains(group) && store.tabGroups.first { $0.id == group }?.hidden == true,
              "The native editor hide action must remove the whole group from the sidebar")
        store.library = .bookmarks
        await settle()
        await press(panel.sheets.first!.contentView!, "隐藏资料")
        check(find(panel.sheets.first!.contentView!)!.numberOfRows == members.count,
              "The hidden group must remain accessible in the manager")
        await press(panel.sheets.first!.contentView!, "打开分组")
        check(store.library == nil && store.tabs.filter { $0.groupID == group }.count == members.count,
              "The manager reopen button must restore one group without duplicate tabs")
        print("PASS: saved group directories, whole-row clicks, native menu hover event/pixel checks, color/row transitions, redraw/exit cleanup, editor hide and manager reopen")
    }
    func verifyBookmarks() async {
        let initialSites = store.sites
        let initialFolders = store.bookmarkFolders
        func find<T: NSView>(_ root: NSView, _ type: T.Type) -> T? {
            if let result = root as? T { return result }
            return root.subviews.lazy.compactMap { find($0, type) }.first
        }
        let sheet = panel.sheets.first!
        let table = find(sheet.contentView!, BookmarkOutline.self)!
        precondition(sheet.firstResponder === table, "Opening bookmark management must focus the bookmark list")
        let folderFixture = BookmarkListItem(key: "folder-icon-fixture", title: "目录", children: [])
        let folderCell = BookmarkCell()
        folderCell.configure(folderFixture)
        let closedFolder = folderCell.icon.image?.tiffRepresentation
        folderCell.configure(folderFixture, expanded: true)
        precondition(closedFolder != folderCell.icon.image?.tiffRepresentation,
                     "Collapsed and expanded folders must use different icons")
        let folderDelegate = table.delegate as! NativeBookmarks.Coordinator
        precondition(folderDelegate.outlineView(table, shouldShowOutlineCellForItem: folderFixture) &&
                     table.frameOfOutlineCell(atRow: 0) == .zero,
                     "Bookmark folders must hide disclosure arrows while retaining native collapse")
        print("PASS: bookmark folders use closed/open icons without disclosure arrows"); fflush(stdout)
        print("PASS: bookmark manager opens with native list focus"); fflush(stdout)
        let menuDelegate = AppDelegate(store: store)
        menuDelegate.panel = panel
        menuDelegate.installMenu()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        table.clipboard = board
        sheet.makeFirstResponder(table)
        func key(_ text: String, code: UInt16) {
            sheet.makeFirstResponder(table)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            precondition(table.performKeyEquivalent(with: event))
        }
        func escape(_ window: NSWindow) {
            NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)!)
        }
        if !CommandLine.arguments.contains("--preview-size-only") {
        let reloads = table.reloadCount
        func checkSelection(_ expected: IndexSet) {
            guard table.selectedRowIndexes == expected else {
                fputs("FAIL: bookmark selection \(Array(table.selectedRowIndexes)), expected \(Array(expected))\n", stderr)
                exit(1)
            }
        }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await settle()
        checkSelection(IndexSet(integer: 0))
        // AppKit reads physical modifier state during tracking; use native selection APIs in this isolated harness.
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: true)
        await settle()
        checkSelection(IndexSet([0, 2]))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await settle()
        table.selectRowIndexes(IndexSet(integersIn: 0...2), byExtendingSelection: false)
        await settle()
        checkSelection(IndexSet(integersIn: 0...2))
        print("PASS: native bookmark single/multiple/range selection synchronization"); fflush(stdout)
        await settle()
        precondition(table.reloadCount == reloads, "Selecting rows must not rebuild bookmark contents")
        key("a", code: 0)
        await settle()
        precondition(table.selectedRowIndexes.count == 3)
        precondition((table.item(atRow: 0) as? BookmarkListItem)?.folderID != nil,
                     "Personal folders must be visible and selectable on opening management")
        let delegate = table.dataSource as! NativeBookmarks.Coordinator
        let writer = delegate.outlineView(table, pasteboardWriterForItem: table.item(atRow: 0)!)!
        board.clearContents()
        precondition(board.writeObjects([writer]))
        precondition(BookmarkDrag.ids(board) == [initialFolders[0].id],
                     "Native folder dragging must preserve the source item identity")
        print("PASS: bookmark select-all"); fflush(stdout)
        key("c", code: 8)
        precondition(BookmarkClipboard.read(board)?.count == store.sites.count)
        precondition(sheet.firstResponder?.tryToPerform(NSSelectorFromString("copy:"), with: nil) == true,
                     "The native sheet responder must handle bookmark copy even in an inactive test application")
        print("PASS: bookmark copy responder"); fflush(stdout)
        let original = store.sites.count
        key("v", code: 9)
        await settle()
        precondition(store.sites.count == original * 2)
        precondition(store.bookmarkFolders.count == 4, "Folder copies must retain their nested hierarchy")
        print("PASS: bookmark paste"); fflush(stdout)
        // Make the list long enough to detect selection-induced scrolling and resizing.
        for i in 0..<25 { _ = store.add(title: "滚动检查 \(i)", address: "https://scroll-\(i).invalid") }
        await settle()
        table.scrollRowToVisible(18)
        await settle()
        let origin = table.enclosingScrollView!.contentView.bounds.origin
        let frame = table.enclosingScrollView!.frame
        let row = table.row(at: NSPoint(x: 30, y: origin.y + 70))
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as! BookmarkCell
        let stableReloads = table.reloadCount
        let openRect = table.convert(cell.openButton.bounds, from: cell.openButton)
        precondition(openRect.maxX <= table.visibleRect.maxX && openRect.minX >= table.visibleRect.minX,
                     "Bookmark row actions must fit inside the viewport")
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await settle()
        precondition((table.dataSource as? NativeBookmarks.Coordinator)?.parent.selection.count == 1,
                     "A plain click must replace selections hidden inside collapsed folders")
        precondition(table.reloadCount == stableReloads)
        precondition(table.enclosingScrollView!.contentView.bounds.origin == origin)
        precondition(table.enclosingScrollView!.frame == frame)
        let field = find(sheet.contentView!, NSTextField.self)!
        sheet.makeFirstResponder(field)
        let textEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        precondition(!table.performKeyEquivalent(with: textEvent), "Bookmark shortcuts must yield to text editing")
        print("PASS: native bookmark multiple/range selection, Cmd-A/C/V, row selection scroll/frame stability and text-edit focus isolation")
        store.sites = initialSites; store.bookmarkFolders = initialFolders
        await settle()
        table.scrollRowToVisible(0)
        sheet.makeFirstResponder(table)
        await settle()
        let dragDelegate = table.dataSource as! NativeBookmarks.Coordinator
        let destination = dragDelegate.roots[0]
        let source = dragDelegate.roots[1]
        board.clearContents()
        let sourceWriter = dragDelegate.outlineView(table, pasteboardWriterForItem: source)!
        precondition(board.writeObjects([sourceWriter]))
        let drag = BookmarkTestDrag(board: board, table: table)
        precondition(dragDelegate.outlineView(table, validateDrop: drag, proposedItem: destination,
                                             proposedChildIndex: -1) == .move)
        precondition(dragDelegate.outlineView(table, acceptDrop: drag, item: destination, childIndex: -1))
        precondition(store.sites.first { $0.id == source.id }?.folderID == destination.folderID)
        precondition(Store(defaults: defaults).sites.first { $0.id == source.id }?.folderID == destination.folderID)
        await settle()
        precondition(dragDelegate.outlineView(table, acceptDrop: drag, item: nil, childIndex: -1))
        precondition(store.sites.first { $0.id == source.id }?.folderID == nil)
        board.clearContents()
        precondition(board.writeObjects([dragDelegate.outlineView(table, pasteboardWriterForItem: destination)!]))
        precondition(!dragDelegate.outlineView(table, acceptDrop: drag, item: destination, childIndex: -1))
        print("PASS: native bookmark drag writer, folder/root drop persistence and self-drop rejection")
        store.notice = nil
        await settle()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        sheet.makeFirstResponder(table)
        await settle()
        let savedSites = defaults.data(forKey: "sites")
        key("\u{7f}", code: 51)
        await settle()
        guard let deleteAlert = sheet.attachedSheet else {
            fputs("FAIL: Command-Backspace must open the existing deletion confirmation\n", stderr); exit(1)
        }
        precondition(defaults.data(forKey: "sites") == savedSites)
        escape(deleteAlert)
        await settle()
        precondition(sheet.attachedSheet == nil && defaults.data(forKey: "sites") == savedSites)
        }
        let field = find(sheet.contentView!, NSTextField.self)!
        precondition(store.edit(initialSites[0], title: initialSites[0].title, address: "http://127.0.0.1:9/bookmark-preview"))
        await settle()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        sheet.makeFirstResponder(table)
        await settle()
        let savedTabs = defaults.data(forKey: "tabs")
        let historyCount = store.history.count
        let previewOrigin = table.enclosingScrollView!.contentView.bounds.origin
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        var presentedSizes: [NSSize] = []
        let presentationObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
                                     NSWindow.didUpdateNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let window = notification.object as? NSWindow, window.parent === sheet, window.isVisible,
                      let content = window.contentView else { return }
                presentedSizes.append(content.bounds.size)
            }
        }
        table.keyDown(with: space)
        await settle()
        presentationObservers.forEach(NotificationCenter.default.removeObserver)
        guard let previewWindow = sheet.childWindows?.first,
              let webView = find(previewWindow.contentView!, WKWebView.self) else {
            fputs("FAIL: Space must open a temporary bookmark web view\n", stderr); exit(1)
        }
        precondition(!webView.configuration.websiteDataStore.isPersistent)
        precondition(previewWindow.styleMask.contains(.resizable), "Web previews must allow edge/corner resizing")
        let defaultPreviewSize = previewWindow.contentView!.bounds.size
        precondition(defaultPreviewSize.width > 740 && defaultPreviewSize.height > 500)
        precondition(!presentedSizes.isEmpty && presentedSizes.allSatisfy {
            abs($0.width - defaultPreviewSize.width) < 2 && abs($0.height - defaultPreviewSize.height) < 2
        }, "Visible preview presentation must keep its initial size")
        print("PASS: preview opens at \(defaultPreviewSize) with stable visible dimensions"); fflush(stdout)
        let initialWebSize = webView.bounds.size
        previewWindow.setContentSize(NSSize(width: defaultPreviewSize.width + 100, height: defaultPreviewSize.height + 60))
        await settle()
        precondition(webView.bounds.width > initialWebSize.width && webView.bounds.height > initialWebSize.height)
        previewWindow.setContentSize(NSSize(width: 800, height: 540))
        await settle()
        precondition(abs(previewWindow.contentView!.bounds.width - 800) < 2)
        precondition(abs(webView.bounds.width - 800) < 2)
        webView.loadHTMLString("<html><title>Temporary preview fixture</title><body><input id='text'></body></html>",
                               baseURL: URL(string: "http://127.0.0.1:9/"))
        await settle()
        precondition(abs(previewWindow.contentView!.bounds.width - 800) < 2 &&
                     abs(previewWindow.contentView!.bounds.height - 540) < 2,
                     "Page loading and title changes must preserve the resized window")
        precondition(defaults.data(forKey: "tabs") == savedTabs && store.history.count == historyCount)
        escape(previewWindow)
        await settle()
        precondition(sheet.childWindows?.isEmpty != false && sheet.firstResponder === table)
        precondition(table.enclosingScrollView!.contentView.bounds.origin == previewOrigin)
        precondition(table.selectedRowIndexes == IndexSet(integer: 1))
        sheet.makeFirstResponder(field)
        let deleteEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        precondition(!table.performKeyEquivalent(with: deleteEvent))
        let previewAction = table.previewItem
        var stolenSpace = false
        table.previewItem = { stolenSpace = true }
        table.keyDown(with: space)
        precondition(!stolenSpace, "Space must remain text input when editing")
        table.previewItem = previewAction
        store.sites = initialSites
        await settle()
        sheet.makeFirstResponder(table)
        print("PASS: stable resizable Space preview, page-update dimensions, Escape focus/selection/scroll restoration and text-edit shortcut isolation")
    }
    func addressField() -> NSTextField {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
               let delegate = field.delegate as? AddressTextField.Coordinator, delegate.observer != nil { return field }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(panel.contentView!)!
    }
    func verifyBookmarkEditor() async {
        SelfTests.prepareAccessibility()
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: bookmark editor: \(message)\n", stderr); exit(1) }
        }
        func element(_ root: NSObject, label: String) -> NSObject? {
            var visited = Set<ObjectIdentifier>()
            func find(_ node: NSObject) -> NSObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                let matchesLabel = node.responds(to: NSSelectorFromString("accessibilityLabel")) &&
                    (node.value(forKey: "accessibilityLabel") as? String)?.contains(label) == true
                let matchesID = node.responds(to: NSSelectorFromString("accessibilityIdentifier")) &&
                    node.value(forKey: "accessibilityIdentifier") as? String == label
                if matchesLabel || matchesID,
                   node.responds(to: NSSelectorFromString("accessibilityRole")),
                   ["AXButton", "AXCheckBox", "AXPopUpButton"].contains(node.value(forKey: "accessibilityRole") as? String ?? ""),
                   node.responds(to: NSSelectorFromString("accessibilityPerformPress")),
                   node.responds(to: NSSelectorFromString("accessibilityFrame")) { return node }
                var children: [NSObject] = (node as? NSView)?.subviews ?? []
                if node.responds(to: NSSelectorFromString("accessibilityChildren")),
                   let accessible = node.value(forKey: "accessibilityChildren") as? [NSObject] { children += accessible }
                for child in children { if let result = find(child) { return result } }
                return nil
            }
            return find(root)
        }
        func clickAt(_ point: NSPoint, window: NSWindow) async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            do { try await AISelfCheck.wait { NSApp.isActive && window.isKeyWindow } }
            catch { check(false, "Bookmark input window did not acquire focus: \(error)"); return }
            NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!, atStart: true)
            NSApp.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            await settle()
        }
        func click(_ label: String, window: NSWindow) async {
            guard let node = element(window.contentView!, label: label),
                  let rect = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
                check(false, "Missing button \(label)"); return
            }
            await clickAt(window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY)), window: window)
        }
        store.sites = []
        let editorFolder = BookmarkFolder(title: "合成书签目录")
        check(store.saveBookmarkFolder(editorFolder), "Synthetic editor folder must be saved")
        store.newTab(address: "http://127.0.0.1:9/star-editor")
        let browser = store.browser!
        browser.webView.loadHTMLString("<title>合成星标页面</title><p>Bookmark fixture</p>",
                                      baseURL: URL(string: "http://127.0.0.1:9/star-editor"))
        for _ in 0..<40 where browser.loading || browser.title != "合成星标页面" { await settle() }
        await settle()
        let address = browser.address
        check(URLInput.parse(address, search: false) != nil, "Synthetic page must have a valid address")
        await click("收藏当前网页", window: panel)
        check(store.bookmarkEditor.window?.isVisible == true, "Actual star click must present the editor")
        check(store.bookmark(for: address)?.showOnHome == false, "New stars must default to hidden on home")
        guard let popup = store.bookmarkEditor.window else {
            check(false, "Missing editor window"); return
        }
        func verifyPlacement(_ label: String, rect suppliedRect: NSRect? = nil) {
            let nativeRect = element(panel.contentView!, label: label)
                .flatMap { ($0.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
            guard let rect = suppliedRect ?? nativeRect,
                  let editor = store.bookmarkEditor.window else { check(false, "Missing placement fixture"); return }
            check(editor.styleMask.contains(.borderless) && editor.parent === panel, "Editor must be a plain child window")
            let gap = rect.minY - editor.frame.maxY
            let aboveGap = editor.frame.minY - rect.maxY
            let visibleBounds = panel.screen!.visibleFrame
            let fitsBelow = rect.minY - editor.frame.height - 16 >= visibleBounds.minY
            check(editor.frame.width == 340 && editor.frame.height > 150 &&
                  ((4...16).contains(gap) || (!fitsBelow && (4...16).contains(aboveGap))),
                  "Editor must sit next to the actual button, flipping only at the screen edge: button=\(rect), editor=\(editor.frame)")
            check(abs(editor.frame.maxX - rect.maxX) <= 8,
                  "Editor must align with the actual button's right edge")
        }
        verifyPlacement("编辑当前网页书签")
        check(element(popup.contentView!, label: "展示在首页") != nil, "Editor must offer a native home checkbox")
        if let text = popup.firstResponder as? NSTextView {
            text.insertText("首页菜单合成书签", replacementRange: NSRange(location: 0, length: text.string.utf16.count))
        } else { check(false, "Name must receive native editing focus") }
        await click("展示在首页", window: popup)
        trackedWebMenu = nil
        let folderObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                self?.trackedWebMenu = menu
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in menu.cancelTrackingWithoutAnimation() }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        await click("bookmark-editor-folder", window: popup)
        NotificationCenter.default.removeObserver(folderObserver)
        check(store.bookmarkEditor.window === popup && popup.isVisible, "Native folder menu must not dismiss the editor")
        guard let folderMenu = trackedWebMenu, let folderIndex = folderMenu.items.firstIndex(where: { $0.title == editorFolder.title }) else {
            check(false, "Native folder picker must offer the synthetic folder"); return
        }
        folderMenu.performActionForItem(at: folderIndex)
        await settle()
        await click("完成", window: popup)
        for _ in 0..<10 where store.bookmarkEditor.window != nil { await settle() }
        check(store.bookmarkEditor.window == nil,
              "Done must dismiss: shown=\(store.bookmarkEditor.window?.isVisible == true), finished=\(store.bookmarkEditor.draft?.finished == true), error=\(store.bookmarkEditor.draft?.error ?? "none")")
        check(store.bookmark(for: address)?.title == "首页菜单合成书签" && store.bookmark(for: address)?.showOnHome == true &&
              store.bookmark(for: address)?.folderID == editorFolder.id,
              "Native text and checkbox events must save together")
        await click("编辑当前网页书签", window: panel)
        check(store.bookmarkEditor.window?.isVisible == true && store.bookmark(for: address) != nil,
              "A saved star must edit instead of deleting")
        verifyPlacement("编辑当前网页书签")
        let originalFrame = panel.frame
        panel.setFrameOrigin(NSPoint(x: originalFrame.minX + 24, y: originalFrame.minY + 20))
        await settle()
        verifyPlacement("编辑当前网页书签")
        panel.setFrame(originalFrame, display: true)
        await settle()
        if let editor = store.bookmarkEditor.window?.firstResponder as? NSTextView {
            editor.insertText("首页菜单合成书签·外部保存", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        } else { check(false, "Existing star must focus its name") }
        await Task.yield()
        let outside = NSPoint(x: 10, y: 180)
        check(store.bookmarkEditor.window?.frame.contains(panel.convertPoint(toScreen: outside)) == false,
              "The dismissal event must be outside the actual editor frame")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: outside, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 3, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
        }
        await settle()
        for _ in 0..<10 where store.bookmarkEditor.window != nil { await settle() }
        check(store.bookmarkEditor.window == nil && store.bookmark(for: address)?.title == "首页菜单合成书签·外部保存",
              "Actual outside click must dismiss and save: shown=\(store.bookmarkEditor.window?.isVisible == true), stored=\(store.bookmark(for: address)?.title ?? ""), draft=\(store.bookmarkEditor.draft?.title ?? ""), keyOnly=\(panel.becomesKeyOnlyIfNeeded)")
        print("PASS: native star editor name, home checkbox, Done, existing bookmark editing and outside-click save")
        fflush(stdout)
        store.newTab()
        await settle()
        let fixture = HomePageFixture(store: store, panel: panel)
        guard let home = try? await fixture.home(), let site = store.bookmark(for: address) else {
            check(false, "Missing HTML home fixture"); return
        }
        let shortcut = ".shortcut[data-id='\(site.id.uuidString)']"
        func shortcutRect() async -> NSRect {
            let result = try? await home.callAsyncJavaScript("""
                const rect=document.querySelector(selector).getBoundingClientRect();
                return {x:rect.x,y:rect.y,width:rect.width,height:rect.height};
                """, arguments: ["selector": shortcut], in: nil, contentWorld: .defaultClient)
            guard let rect = result as? [String: Double],
                  let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"] else {
                check(false, "Missing HTML home shortcut"); return .zero
            }
            return panel.convertToScreen(home.convert(NSRect(x: x, y: home.isFlipped ? y : home.bounds.height-y-height,
                                                               width: width, height: height), to: nil))
        }
        trackedWebMenu = nil
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                self?.trackedWebMenu = menu
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in menu.cancelTrackingWithoutAnimation() }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        func menu() async -> NSMenu {
            trackedWebMenu = nil
            panel.focusWindow()
            let rect = await shortcutRect()
            let point = panel.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            DispatchQueue.main.async {
                NSApp.sendEvent(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.panel.windowNumber,
                    context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!)
            }
            for _ in 0..<20 where trackedWebMenu == nil { await settle() }
            guard let menu = trackedWebMenu else { check(false, "Actual right click must open a native shortcut menu"); return NSMenu() }
            return menu
        }
        func perform(_ title: String, in menu: NSMenu) async {
            guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
                check(false, "Missing menu action \(title)"); return
            }
            check(NSApp.sendAction(action, to: item.target, from: item), "Menu action must dispatch")
            await settle()
        }
        let firstMenu = await menu()
        check(firstMenu.items.filter { !$0.isSeparatorItem }.map(\.title) ==
              ["在新标签页打开", "临时浏览", "编辑书签…", "复制网址", "从首页移除", "删除书签"], "Home menu must offer the common actions")
        await perform("编辑书签…", in: firstMenu)
        check(store.bookmarkEditor.window?.isVisible == true && store.bookmarkEditor.draft?.request.showAddress == true,
              "Home menu editing must include the address")
        verifyPlacement("首页菜单合成书签", rect: await shortcutRect())
        browser.webView.loadHTMLString("<title>Background bookmark fixture</title>",
                                      baseURL: URL(string: "http://127.0.0.1:9/background-bookmark"))
        for _ in 0..<20 where browser.address == address { await settle() }
        check(browser.address != address && store.bookmarkEditor.window?.isVisible == true,
              "Background navigation must not close another page's bookmark draft")
        let forcedTitle = "首页菜单合成书签·窗口关闭保存"
        if let editor = store.bookmarkEditor.window?.firstResponder as? NSTextView {
            editor.insertText(forcedTitle, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            await settle()
        } else { check(false, "Home editor must focus its name") }
        if let root = store.bookmarkEditor.window?.contentView,
           let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to:
                FileManager.default.temporaryDirectory.appendingPathComponent("perch-bookmark-editor.png"))
        }
        store.bookmarkEditor.window?.close()
        await settle()
        check(store.bookmark(for: address)?.title == forcedTitle, "Forced AppKit dismissal must save the draft before clearing it")
        let hideMenu = await menu()
        await perform("从首页移除", in: hideMenu)
        let removed = try? await home.callAsyncJavaScript("return !document.querySelector(selector);",
            arguments: ["selector": shortcut], in: nil, contentWorld: .defaultClient)
        check(store.bookmark(for: address)?.showOnHome == false && removed as? Bool == true,
              "Removing a shortcut must keep the bookmark and remove its actual home target")
        print("PASS: plain editor sits next to actual star/home buttons and follows parent movement; native editing, outside/forced dismissal and home menu actions")
        fflush(stdout)
    }
    func verifyHomeNavigation(baseURL: String) async {
        do { try await HomePageSelfCheck.navigation(store: store, panel: panel, baseURL: baseURL) }
        catch { fputs("FAIL: HTML home navigation: \(error)\n", stderr); exit(1) }
    }
    func editAddress(_ text: String) {
        let field = addressField()
        panel.makeFirstResponder(field)
        field.stringValue = text
        let coordinator = field.delegate as! AddressTextField.Coordinator
        coordinator.controlTextDidBeginEditing(Notification(name: NSTextField.textDidBeginEditingNotification, object: field))
        coordinator.controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification, object: field))
    }
    func verifyHomeFocusRestoration() async {
        NSApp.activate(ignoringOtherApps: true)
        panel.focusWindow()
        await settle()
        let focusDeadline = Date().addingTimeInterval(3)
        while !NSApp.isActive || !panel.isKeyWindow {
            guard Date() < focusDeadline else {
                fputs("FAIL: focus restoration fixture could not activate its isolated window\n", stderr); exit(1)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let selected = store.selected, store.tabs.contains(where: { $0.id != selected }) else {
            preconditionFailure("Homepage focus fixture requires two tabs")
        }
        do { try await HomePageSelfCheck.focus(store: store, panel: panel, table: table()) }
        catch { fputs("FAIL: HTML home focus: \(error)\n", stderr); exit(1) }
        let url = URL(string: "https://perch-reference.invalid/page?fixture=1")!
        let count = store.tabs.count
        store.openReferencedPage(url)
        let opened = store.selected!
        precondition(store.tabs.count == count + 1 && store.tabs.last?.address == url.absoluteString)
        store.activate(selected)
        store.openReferencedPage(url)
        precondition(store.selected == opened && store.tabs.count == count + 1)
        store.close(opened)
        store.activate(selected)
        await settle()
        print("PASS: page reference opens within Perch and reuses an existing tab")
    }
    func verifyAddressComposition() async {
        do { try await HomePageSelfCheck.input(store: store, panel: panel) }
        catch { fputs("FAIL: HTML home input: \(error)\n", stderr); exit(1) }
    }
    func verify(width: CGFloat) {
        func check(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
            guard condition() else {
                fputs("FAIL: sidebar layout at line \(line): \(message)\n", stderr); exit(1)
            }
        }
        let table = table()
        check(table.ids == store.tabs.map(\.id) && table.numberOfRows == store.tabs.count, "Native tab rows must match the store")
        let actual = table.enclosingScrollView!.frame.width
        // NativeTabList extends 2pt into each side of the sidebar's 8pt padding.
        let expectedWidth = width + 4
        check(abs(actual - expectedWidth) < 2, "Expected sidebar content \(expectedWidth), got \(actual)")
        if !store.tabs.isEmpty {
            if store.tabs.count <= 4 {
                check(!table.enclosingScrollView!.hasVerticalScroller,
                             "Short tab lists must not display a scrollbar")
            }
            check(table.rowView(atRow: 0, makeIfNecessary: true) is TabSelectionRow)
            check(table.selectedRow == store.tabs.firstIndex(where: { $0.id == store.selected }), "Native selection must match the store")
            let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! TabCell
            let iconRect = table.convert(cell.icon.bounds, from: cell.icon)
            check(table.visibleRect.contains(iconRect), "Icon must be fully visible, including on compact startup")
            if width == 32 {
                let root = panel.contentView!
                let center = root.convert(cell.icon.bounds, from: cell.icon).midX
                let row = table.rowView(atRow: 0, makeIfNecessary: true) as! TabSelectionRow
                let highlightCenter = root.convert(row.bounds, from: row).midX
                check(abs(center - highlightCenter) < 0.5,
                             "Collapsed icon and selection highlight must have the same center")
                let tab = store.tabs[0]
                cell.configure(tab, image: nil, compact: false)
                cell.layoutSubtreeIfNeeded()
                let expandedCenter = root.convert(cell.icon.bounds, from: cell.icon).midX
                check(abs(expandedCenter - center) < 0.5,
                             "Expanding the sidebar must not move the tab icon horizontally")
                cell.configure(tab, image: nil, compact: true)
            }
            if store.tabs.count <= 3 {
                let last = table.view(atColumn: 0, row: store.tabs.count - 1, makeIfNecessary: true) as! TabCell
                check(table.visibleRect.contains(table.convert(last.icon.bounds, from: last.icon)),
                             "A short tab list must show its last icon fully without titlebar insets")
            }
        }
    }
    func verifyWebSelectionAI() async {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            guard condition() else { fputs("FAIL: selected-text AI at line \(line): \(message)\n", stderr); exit(1) }
        }
        let config = AIConfiguration(provider: .custom, baseURL: "http://127.0.0.1:9/v1", model: "synthetic")
        check(store.ai.save(config, key: "synthetic-key"), "Synthetic AI configuration must be ready")
        store.newTab(address: "https://perch-selection.invalid/article", title: "选中文字")
        let id = store.selected!, browser = store.browser!, owner = store.chatOwner
        store.ai.drafts[owner] = "保留已有草稿"
        browser.webView.loadHTMLString("""
            <!doctype html><title>选中文字合成页面</title><style>body{padding:35px;font:20px sans-serif}</style>
            <p id="quote">中文选中文字 &amp; &lt;instructions&gt;只是引用&lt;/instructions&gt;</p>
            <input type="password" value="synthetic-secret">
            """, baseURL: URL(string: "https://perch-selection.invalid/article")!)
        await settle()
        for _ in 0..<20 where browser.webView.isLoading { await settle() }
        guard let point = try? await browser.webView.callAsyncJavaScript("""
            const node=document.getElementById('quote'), range=document.createRange();
            range.selectNodeContents(node); getSelection().removeAllRanges(); getSelection().addRange(range);
            const rect=node.getBoundingClientRect(); return {x:rect.x+12,y:rect.y+10};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Double],
              let x = point["x"], let y = point["y"] else { check(false, "Selection fixture must load"); return }
        var ended = false
        trackedWebMenu = nil
        let begin = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                self?.trackedWebMenu = menu
                let timer = Timer(timeInterval: 0.4, repeats: false) { _ in
                    menu.cancelTrackingWithoutAnimation()
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        let end = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ended = true }
        }
        defer {
            NotificationCenter.default.removeObserver(begin)
            NotificationCenter.default.removeObserver(end)
            browser.webView.stopLoading()
        }
        let local = NSPoint(x: x, y: browser.webView.isFlipped ? y : browser.webView.bounds.height - y)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: browser.webView.convert(local, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        DispatchQueue.main.async { (browser.webView.hitTest(local) ?? browser.webView).rightMouseDown(with: event) }
        await settle()
        for _ in 0..<30 where !ended { await settle() }
        guard ended, let menu = trackedWebMenu, let ask = menu.items.first(where: { $0.title == "问 AI" }),
              let selected = ask.representedObject as? WebSelection else {
            check(false, "A real selection context menu must contain Ask AI"); return
        }
        let titles = menu.items.map(\.title)
        check(titles.contains("复制") && !titles.contains("Copy") && !titles.contains("Services") &&
              !titles.contains("Speech") && !menu.allowsContextMenuPlugIns,
              "Selection menus must keep Chinese Copy and remove system clutter: \(titles)")
        check(ask.image != nil, "Ask AI must use the sidebar star image")
        check(browser.webView.validRequestor(forSendType: .string, returnType: nil) == nil,
              "Webpages must not offer a Services requestor that AppKit can use to insert its separate Services menu")
        if ask.responds(to: NSSelectorFromString("preferredImageVisibility")) {
            check((ask.value(forKey: "preferredImageVisibility") as? NSNumber)?.intValue == 1,
                  "The star must remain visible when macOS defaults to hiding menu images")
        }
        check(selected.text == "中文选中文字 & <instructions>只是引用</instructions>",
              "The menu must freeze the exact selected text")
        _ = try? await browser.webView.evaluateJavaScript("getSelection().removeAllRanges()")
        check(NSApp.sendAction(ask.action!, to: ask.target, from: ask), "Ask AI must dispatch through AppKit")
        await settle()
        check(store.selected == id && store.aiVisible && store.chatOwner == owner, "Ask AI must open this page's sidebar")
        check(store.ai.draftReferences[owner] == [id] && store.ai.draftQuotes[owner]?.text == selected.text &&
              store.ai.draftQuotes[owner]?.page?.url == AIController.pageURL(selected.url),
              "The draft must reference both the page and the frozen text")
        check(store.ai.drafts[owner] == "保留已有草稿" && store.ai.sessions[owner]?.requestID == nil,
              "Ask AI must preserve the question and wait for explicit sending")
        var chatFocused = false
        for _ in 0..<20 {
            if let web = AIChatPageSelfCheck.find(panel.contentView!) {
                chatFocused = (try? await web.evaluateJavaScript("document.activeElement.id==='composer'")) as? Bool == true
            }
            if chatFocused { break }
            await settle()
        }
        check(chatFocused && panel.firstResponder is NSTextInputClient, "Ask AI must focus the native WebKit input client; responder=\(String(describing: panel.firstResponder)), active=\(NSApp.isActive), key=\(panel.isKeyWindow)")
        check(store.ai.composerFocusRequests[owner] == nil, "Focus requests must be consumed instead of replaying on later tab switches")
        let snapshot = store.ai.draftQuotes[owner]!
        let restored = try? JSONDecoder().decode(AIQuote.self, from: JSONEncoder().encode(snapshot))
        check(restored == snapshot && snapshot.content(question: "解释一下").contains("&lt;instructions&gt;"),
              "Page quotes must persist and escape quoted markup")
        store.askAI(selected, tabID: id)
        check(store.ai.draftReferences[owner] == [id], "Repeated Ask AI must not duplicate the page reference")
        let repeatedSnapshot = store.ai.draftQuotes[owner]!
        check(repeatedSnapshot.text == snapshot.text && repeatedSnapshot.page?.url == snapshot.page?.url,
              "Repeated Ask AI must preserve the selected text and source")
        let bridge = (try? await browser.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.perchSelection")) as? String
        check(bridge == "undefined", "The selection bridge must remain isolated from page scripts")
        check(store.ai.send("已发送的合成消息", tab: owner, browser: nil, usePage: false),
              "The source conversation must have an existing message")
        for _ in 0..<20 where store.ai.sessions[owner]?.requestID != nil { await settle() }
        let oldMessages = store.ai.sessions[owner]!.messages.map(\.id)
        store.ai.drafts[owner] = "保留文字和引用，开始新会话 🙂"
        let attachment = AIAttachment(name: "draft.txt", data: Data("fixture".utf8), text: "fixture", mime: nil)
        store.ai.draftFiles[owner] = [attachment]
        SelfTests.prepareAccessibility()
        await settle()
        var visited = Set<ObjectIdentifier>()
        func newChatButton(_ node: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.responds(to: NSSelectorFromString("accessibilityLabel")),
               node.value(forKey: "accessibilityLabel") as? String == "新对话",
               node.responds(to: NSSelectorFromString("accessibilityFrame")) { return node }
            var children: [NSObject] = (node as? NSView)?.subviews ?? []
            if node.responds(to: NSSelectorFromString("accessibilityChildren")) {
                children += node.value(forKey: "accessibilityChildren") as? [NSObject] ?? []
            }
            // A lazy compactMap can evaluate the transform twice; this search mutates visited.
            for child in children { if let found = newChatButton(child) { return found } }
            return nil
        }
        guard let button = newChatButton(panel.contentView!),
              let frame = (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
            check(false, "The native sidebar new-chat button must be accessible"); return
        }
        await clickInPanel(panel.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)))
        await settle()
        let newOwner = store.chatOwner
        check(newOwner != owner && store.ai.sessions[newOwner]?.messages.isEmpty == true,
              "The actual sidebar button must start a separate empty conversation")
        check(store.ai.drafts[newOwner] == "保留文字和引用，开始新会话 🙂" &&
              store.ai.draftFiles[newOwner]?.map(\.id) == [attachment.id] &&
              store.ai.draftFiles[newOwner]?.first?.data == attachment.data && store.ai.draftReferences[newOwner] == [id] &&
              store.ai.draftQuotes[newOwner] == repeatedSnapshot,
              "The new conversation must retain the visible text, attachment, webpage and selection references")
        let chatInput = try? await AIChatPageSelfCheck.find(panel.contentView!)?.evaluateJavaScript("document.getElementById('composer').value")
        check(chatInput as? String == store.ai.drafts[newOwner],
              "The new native composer must display the preserved input")
        check(store.ai.sessions[owner]?.messages.map(\.id) == oldMessages &&
              store.ai.sessions[newOwner]?.requestID == nil,
              "Starting a conversation must preserve old history and wait for explicit sending")
        store.newChat()
        check(store.chatOwner == newOwner && store.ai.draftReferences[newOwner] == [id] &&
              store.ai.draftQuotes[newOwner] == repeatedSnapshot, "Repeated new-chat clicks must retain the same draft and deduplicate references")
        print("PASS: actual sidebar new-chat click preserves native composer text, attachments, webpage/selection references and old history without sending")
        print("PASS: actual selected-text context menu, Chinese cleanup, frozen webpage/text references, preserved drafts, composer focus and isolated selection bridge")
    }

    func verifyWebContextMenu() async {
        func precondition(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
            guard condition() else { fputs("FAIL: page context menu at line \(line): \(message)\n", stderr); exit(1) }
        }
        let browser = Browser(url: URL(string: "https://perch-context.invalid/")!, dataStore: .nonPersistent())
        browser.webView.stopLoading()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = browser.webView
        window.makeKeyAndOrderFront(nil)
        defer { browser.webView.stopLoading(); window.close(); panel.makeKeyAndOrderFront(nil) }
        browser.webView.loadHTMLString("""
            <!doctype html><html><head><meta charset="windows-1252"><title>中文网页</title></head>
            <body><p>Native context menu fixture 中文</p><a href='relative'>Link</a></body></html>
            """,
                                      baseURL: URL(string: "https://perch-context.invalid/")!)
        await settle()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                              object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                self?.trackedWebMenu = menu
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in menu.cancelTrackingWithoutAnimation() }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var menuEnded = false
        let endObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                                 object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { menuEnded = true }
        }
        defer { NotificationCenter.default.removeObserver(endObserver) }
        let point = NSPoint(x: 300, y: 200)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: browser.webView.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        DispatchQueue.main.async {
            let hit = browser.webView.hitTest(point) ?? browser.webView
            hit.rightMouseDown(with: event)
        }
        await settle()
        for _ in 0..<30 where !menuEnded { await settle() }
        precondition(menuEnded, "The native context menu must finish tracking before dispatching fixture actions")
        guard let menu = trackedWebMenu else { preconditionFailure("A real WebKit right click must open a native menu") }
        precondition(menu.items.contains { $0.title == "复制当前网址" },
                     "WebKit's native context menu must include Perch actions")
        for title in ["后退", "前进", "重新加载", "存储为…"] {
            precondition(menu.items.filter { $0.title == title }.count == 1,
                         "Each page action must appear once: \(title), actual \(menu.items.map(\.title))")
        }
        precondition(!menu.items.contains { $0.title == "在 Perch 中打开" ||
            ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierReload"]
                .contains($0.identifier?.rawValue ?? "") }, "Native navigation must be replaced with Chinese actions")
        let sentinel = NSMenuItem(title: "Native link action fixture", action: nil, keyEquivalent: "")
        let retained = NSMenu()
        retained.addItem(.separator())
        for identifier in ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierReload"] {
            let native = NSMenuItem(title: "Localized native action", action: nil, keyEquivalent: "")
            native.identifier = NSUserInterfaceItemIdentifier(identifier)
            retained.addItem(native)
        }
        let stop = NSMenuItem(title: "Localized native stop", action: NSSelectorFromString("forwardContextMenuAction:"), keyEquivalent: "")
        stop.tag = 11
        retained.addItem(stop)
        retained.addItem(.separator())
        retained.addItem(sentinel)
        retained.addItem(.separator())
        browser.extendContextMenu(retained)
        let count = retained.items.count
        browser.extendContextMenu(retained)
        precondition(retained.items.first === sentinel && retained.items.count == count,
                     "Menu extension must preserve native items and be idempotent")
        precondition(!retained.items.contains { $0 === stop }, "Loading-page native Stop must also be removed")
        precondition(retained.items.first { $0.title == "后退" }?.isEnabled == false)
        precondition(retained.items.first { $0.title == "前进" }?.isEnabled == false)
        let board = NSPasteboard.withUniqueName()
        browser.clipboard = board
        defer { board.releaseGlobally() }
        let copy = retained.items.first { $0.title == "复制当前网址" }!
        precondition(NSApp.sendAction(copy.action!, to: copy.target, from: copy))
        precondition(board.string(forType: .string) == "https://perch-context.invalid/")
        let find = retained.items.first { $0.title == "在页面中查找…" }!
        precondition(NSApp.sendAction(find.action!, to: find.target, from: find) && browser.finding)
        var saved = false
        browser.onBookmark = { saved.toggle() }
        browser.isBookmarked = { saved }
        let bookmarkMenu = NSMenu(); browser.extendContextMenu(bookmarkMenu)
        let bookmark = bookmarkMenu.items.first { $0.title == "加入书签" }!
        precondition(NSApp.sendAction(bookmark.action!, to: bookmark.target, from: bookmark) && saved)
        let savedMenu = NSMenu(); browser.extendContextMenu(savedMenu)
        precondition(savedMenu.items.contains { $0.title == "编辑书签…" })
        browser.address = "javascript:alert(1)"
        precondition(browser.validateMenuItem(copy), "Copy keeps the menu-opening URL snapshot")
        let invalid = NSMenu(); browser.extendContextMenu(invalid)
        precondition(invalid.items.first { $0.title == "复制当前网址" }?.isEnabled == false)
        do {
            let originalHTML = try await browser.webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
            let snapshot = try await browser.htmlSnapshot()
            precondition(snapshot.title == "中文网页" && snapshot.html.hasPrefix("<!DOCTYPE html>"),
                         "HTML snapshots must preserve title and doctype")
            precondition(snapshot.html.contains("charset=\"utf-8\"") && !snapshot.html.contains("windows-1252") &&
                         snapshot.html.contains("href=\"https://perch-context.invalid/\"") &&
                         snapshot.html.contains("中文"), "Export must include UTF-8 and an absolute resource base")
            let liveHTML = try await browser.webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
            precondition(originalHTML != nil && liveHTML == originalHTML, "Export must not mutate the live page")
            let save = retained.items.first { $0.title == "存储为…" }!
            precondition(NSApp.sendAction(save.action!, to: save.target, from: save), "Save must dispatch through AppKit")
            await settle()
            for _ in 0..<20 where window.attachedSheet == nil { await settle() }
            guard let savePanel = window.attachedSheet as? NSSavePanel else {
                precondition(false, "Save must open a native save panel"); return
            }
            precondition(savePanel.allowedContentTypes == [.html] && savePanel.nameFieldStringValue == "中文网页.html",
                         "The save panel must offer HTML with the page title")
            savePanel.cancel(nil)
            await settle()
            for _ in 0..<20 where window.attachedSheet != nil { await settle() }
            precondition(window.attachedSheet == nil, "Cancel must dismiss the save panel without an error")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perch-html-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("中文网页.html")
            try snapshot.html.write(to: file, atomically: true, encoding: .utf8)
            let saved = try String(contentsOf: file, encoding: .utf8)
            precondition(saved == snapshot.html, "The HTML file must preserve Unicode")
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let restoredView = WKWebView(frame: .zero, configuration: configuration)
            defer { restoredView.stopLoading() }
            restoredView.loadFileURL(file, allowingReadAccessTo: directory)
            await settle()
            for _ in 0..<20 where restoredView.isLoading { await settle() }
            let restored = try await restoredView.evaluateJavaScript("""
                document.characterSet === 'UTF-8' && document.querySelector('a').href === 'https://perch-context.invalid/relative'
                  && document.body.textContent.includes('中文') && document.compatMode === 'CSS1Compat'
                """) as? Bool
            precondition(restored == true, "Saved HTML must reopen with its encoding, doctype and relative links")
        } catch { precondition(false, "HTML export fixture failed: \(error)") }
        print("PASS: actual WebKit right-click menu, Chinese navigation deduplication, native item preservation, isolated clipboard, find, native HTML save panel/cancel and HTML snapshot/file round trip")
    }
    func verifyLinkPreview() async {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        let initialSelected = store.selected
        let initialClosed = store.recentlyClosed
        let initialSettings = store.settings
        store.newTab(address: "https://perch-hover.invalid/", title: "Hover fixture")
        let tab = store.selected!
        let browser = store.browser!
        // Inject event coordinates into a separate controller so physical mouse movement cannot race the fixture.
        let trigger = LinkPreviewController(store: store)
        browser.hoverLinks?.changed = { [weak trigger] in trigger?.hoverChanged() }
        browser.webView.stopLoading()
        browser.webView.loadHTMLString("""
            <html><title>Hover fixture</title><body style="min-height:1000vh">
            <script>
            // This fixture injects its own pointer events; actual cursor movement must not erase them.
            for (const type of ['pointermove', 'pointerover', 'pointerout']) {
              window.addEventListener(type, event => {
                if (event.isTrusted) event.stopImmediatePropagation();
              }, true);
            }
            </script>
            <a id="link" style="position:fixed;left:8px;top:8px" href="https://perch-preview.invalid/target">Preview target</a>
            <a id="unsafe" href="javascript:alert(1)">Unsafe target</a><input id="text">
            <iframe id="frame" srcdoc="<a id='inner' href='https://perch-frame.invalid/target'>Inner link</a>"></iframe>
            </body></html>
            """, baseURL: URL(string: "https://perch-hover.invalid/")!)
        NSApp.activate(ignoringOtherApps: true)
        panel.focusWindow()
        await settle()
        defer {
            trigger.preview?.close()
            store.close(tab); store.recentlyClosed = initialClosed
            if let initialSelected { store.activate(initialSelected) }
            try? store.saveSettings(initialSettings)
        }
        func hover(_ selector: String) async {
            let raw = try? await browser.webView.evaluateJavaScript("document.querySelector('\(selector)').href")
            let expected = (raw as? String).flatMap { URLInput.parse($0, search: false)?.absoluteString }
            for _ in 0..<10 {
                _ = try? await browser.webView.evaluateJavaScript("""
                    (() => {
                      const link = document.querySelector('\(selector)');
                      link.dispatchEvent(new PointerEvent('pointerout', {bubbles:true}));
                      link.dispatchEvent(new PointerEvent('pointerover', {bubbles:true}));
                    })()
                    """)
                try? await Task.sleep(nanoseconds: 80_000_000)
                if browser.hoverLinks?.site?.address == expected { await focus(); return }
            }
            check(false, "Link preview fixture did not track \(selector)")
        }
        func flags(_ value: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: value,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
            let point = browser.webView.convert(NSPoint(x: 80, y: 80), to: nil)
            trigger.handle(event, pointer: panel.convertPoint(toScreen: point))
        }
        func letter(_ type: NSEvent.EventType) {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            let point = browser.webView.convert(NSPoint(x: 80, y: 80), to: nil)
            trigger.handle(event, pointer: panel.convertPoint(toScreen: point))
        }
        func apply(_ settings: BrowserSettings) {
            try! store.saveSettings(settings)
            trigger.settingsChanged()
        }
        func focus() async {
            do { try await HomePageFixture(store: store, panel: panel).focus() }
            catch { check(false, "Link preview fixture could not activate its isolated window: \(error)") }
            panel.makeFirstResponder(browser.webView)
        }
        let isolated = try? await browser.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.perchHoverLink")
        check(isolated as? String == "undefined", "Page scripts must not access the hover bridge")
        await hover("#unsafe")
        check(browser.hoverLinks?.site == nil, "Unsafe links must not be tracked")
        _ = try? await browser.webView.evaluateJavaScript("""
            document.querySelector('#frame').contentDocument.querySelector('#inner')
              .dispatchEvent(new PointerEvent('pointerover', {bubbles:true}))
            """)
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(browser.hoverLinks?.site?.address == "https://perch-frame.invalid/target",
                     "Links inside frames must be tracked")
        await hover("#link")
        check(browser.hoverLinks?.site?.address == "https://perch-preview.invalid/target", "Main-frame link must be tracked")
        flags(.option)
        await settle()
        check(trigger.preview == nil, "Default Alt hold must wait a full second")
        flags([])
        try? await Task.sleep(nanoseconds: 850_000_000)
        check(trigger.preview == nil, "Releasing Alt must cancel the pending preview")
        var settings = store.settings
        settings.linkPreviewDelay = 0.2
        apply(settings)
        flags(.option)
        _ = try? await browser.webView.evaluateJavaScript(
            "document.querySelector('#link').dispatchEvent(new PointerEvent('pointerout', {bubbles:true}))")
        await settle()
        check(trigger.preview == nil, "Leaving the link cancels the hold")
        flags([])
        await hover("#link")
        _ = try? await browser.webView.evaluateJavaScript("document.querySelector('#text').focus()")
        try? await Task.sleep(nanoseconds: 80_000_000)
        settings.linkPreviewKey = Shortcut(code: 0, modifiers: 0, label: "A")
        apply(settings)
        letter(.keyDown)
        await settle()
        check(trigger.preview == nil, "A letter trigger must not interfere with typing in page fields")
        letter(.keyUp)
        settings.linkPreviewKey = Shortcut(code: 58, modifiers: 0, label: "Alt")
        apply(settings)
        _ = try? await browser.webView.evaluateJavaScript("document.querySelector('#text').blur()")
        await focus()
        await hover("#link")
        let tabs = store.tabs.map(\.id), visits = store.history.count
        flags(.option)
        await settle()
        guard let preview = trigger.preview else {
            let point = browser.webView.convert(NSPoint(x: 80, y: 80), to: nil)
            fputs("FAIL: holding Alt on a link must present a preview; active=\(NSApp.isActive), key=\(panel.isKeyWindow), attached=\(browser.webView.window === panel), visible=\(browser.webView.visibleRect), point=\(point), site=\(browser.hoverLinks?.site?.address ?? "nil"), selected=\(store.selected == tab), enabled=\(store.settings.linkPreviewEnabled), delay=\(store.settings.linkPreviewDelay)\n", stderr); exit(1)
        }
        check(preview.window.parent === panel && preview.browser.hoverLinks == nil &&
              preview.browser.onVisit == nil && !preview.browser.webView.configuration.websiteDataStore.isPersistent,
              "Preview must be an isolated nonpersistent child window without a hover tracker or history callback")
        flags(.option)
        await settle()
        check(trigger.preview === preview, "A preview must never open a nested preview")
        preview.window.setContentSize(NSSize(width: 800, height: 540))
        await settle()
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: preview.window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        preview.window.makeFirstResponder(preview.browser.webView)
        NSApp.sendEvent(escape)
        await settle()
        check(trigger.preview == nil && panel.childWindows?.isEmpty != false, "Esc closes the preview with web content focused")
        check(defaults.string(forKey: "previewContentSize").map(NSSizeFromString) == NSSize(width: 800, height: 540),
              "Preview size must be saved as 800x540")
        flags([])
        await hover("#link")
        settings.linkPreviewEnabled = false; apply(settings)
        flags(.option)
        await settle()
        check(trigger.preview == nil, "The global preview switch must disable triggering")
        settings.linkPreviewEnabled = true
        settings.linkPreviewKey = Shortcut(code: 59, modifiers: 0, label: "Control")
        apply(settings)
        flags(.option)
        await settle()
        check(trigger.preview == nil, "Configured trigger must replace Alt")
        await focus()
        await hover("#link")
        _ = try? await browser.webView.evaluateJavaScript("window.scrollTo(0,900)")
        await settle()
        let sourceScrollY = (try? await browser.webView.evaluateJavaScript("window.scrollY")) as? Double ?? -1
        check(sourceScrollY > 800, "Long source page must be scrolled before preview")
        await focus()
        await hover("#link")
        flags(.control)
        await settle()
        guard let restored = trigger.preview else {
            fputs("FAIL: custom Control trigger (active=\(NSApp.isActive), key=\(panel.isKeyWindow), link=\(browser.hoverLinks?.site != nil))\n", stderr)
            exit(1)
        }
        check(restored.window.contentView!.bounds.size == NSSize(width: 800, height: 540),
                     "Preview window must restore the user's content size")
        check(restored.window.styleMask.contains(.miniaturizable), "Preview must support minimizing")
        func windowControls(_ view: NSView) -> WindowControls.ControlsView? {
            if let controls = view as? WindowControls.ControlsView { return controls }
            return view.subviews.compactMap(windowControls).first
        }
        let controls = windowControls(restored.window.contentView!)!
        check(controls.buttons.count == 3 && controls.buttons.allSatisfy { !$0.isHidden },
              "Preview must expose three native window buttons")
        restored.browser.address = "http://127.0.0.1:9/preview-current"
        restored.browser.title = "Current preview"
        restored.openInTab()
        let opened = store.selected!
        check(store.tabs.count == tabs.count + 1 &&
              store.tabs.last?.address == "http://127.0.0.1:9/preview-current",
              "Open in new tab must use the current preview URL exactly once")
        restored.openInTab()
        restored.browser.onOpenInPerch?(URL(string: "http://127.0.0.1:9/duplicate")!)
        check(store.tabs.count == tabs.count + 1, "A closed preview must not open duplicate tabs")
        await settle()
        store.activate(tab)
        await settle()
        let returnedScrollY = (try? await browser.webView.evaluateJavaScript("window.scrollY")) as? Double ?? -1
        check(abs(returnedScrollY - sourceScrollY) < 2, "Returning from preview-opened tab must preserve the source page scroll position")
        store.close(opened)
        store.recentlyClosed = initialClosed
        settings.linkPreviewKey = Shortcut(code: 0, modifiers: 0, label: "A")
        apply(settings)
        await focus()
        await hover("#link")
        letter(.keyDown)
        letter(.keyUp)
        await settle()
        check(trigger.preview == nil, "Releasing a custom letter cancels its pending preview")
        await focus()
        await hover("#link")
        letter(.keyDown)
        await settle()
        check(trigger.preview != nil, "Single letter keys must support a held preview trigger")
        trigger.preview?.close()
        await settle()
        settings.linkPreviewKey = Shortcut(code: 58, modifiers: 0, label: "Alt")
        settings.linkPreviewDelay = Double.greatestFiniteMagnitude
        apply(settings)
        await focus()
        await hover("#link")
        flags(.option)
        await settle()
        check(trigger.preview == nil, "Very large finite delays must wait without overflowing")
        flags([])
        settings.linkPreviewDelay = 0
        apply(settings)
        await focus()
        await hover("#link")
        flags(.option)
        check(trigger.preview != nil, "Zero seconds must present immediately in the triggering event; active=\(NSApp.isActive), key=\(panel.isKeyWindow), link=\(browser.hoverLinks?.site?.address ?? "none")")
        let fading = trigger.preview!
        check(fading.window.animationBehavior == .none, "Preview opacity transition must own window presentation")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(fading.window.alphaValue < 1, "Preview must start transparent")
            var intermediateOpacity = false
            let deadline = ProcessInfo.processInfo.systemUptime + 0.6
            while ProcessInfo.processInfo.systemUptime < deadline {
                let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(fading.window.windowNumber)) as? [[String: Any]]
                if let alpha = entries?.first?[kCGWindowAlpha as String] as? Double,
                   alpha > 0, alpha < 1 { intermediateOpacity = true; break }
                if fading.window.alphaValue == 1 { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            check(intermediateOpacity, "Window server must display intermediate preview opacity")
        }
        await settle()
        check(fading.window.alphaValue == 1 && fading.window.isVisible, "Preview must finish fading in")
        fading.close()
        check(fading.window.ignoresMouseEvents, "Fading-out preview must stop accepting clicks immediately")
        await settle()
        check(trigger.preview == nil && !fading.window.isVisible && fading.window.contentView == nil,
              "Fade-out must release preview content and detach the child window")
        flags([])
        await focus()
        await hover("#link")
        flags(.option)
        let interrupted = trigger.preview!
        interrupted.close()
        await settle()
        check(trigger.preview == nil && !interrupted.window.isVisible, "Closing during fade-in must stay closed")
        check(store.tabs.map(\.id) == tabs && store.history.count == visits, "Preview must not add tabs or history")
        print("PASS: hover/frame link tracking, isolated bridge, invalid URL rejection, zero-delay immediate trigger, huge-delay cancellation, hold/release/leave/edit cancellation, custom trigger, global switch, Esc, no nesting, remembered size and tab/history isolation")
    }
    func verifySettingsFocus() async {
        let initial = store.settings
        var settings = initial
        settings.linkPreviewDelay = 0
        try! store.saveSettings(settings)
        store.library = .settings
        await settle()
        guard let sheet = panel.sheets.first, let root = sheet.contentView else {
            preconditionFailure("Settings sheet must appear")
        }
        precondition(root.bounds.size == NSSize(width: 780, height: 580),
                     "Settings must open at the shared bookmark manager size")
        precondition(LibraryPage.allCases.map(\.rawValue) == ["常规", "AI", "书签与分组", "密码", "导入导出"],
                     "Manager tabs must keep the requested labels and order")
        precondition(!(sheet.firstResponder is NSTextView), "Opening settings must not auto-focus numeric input")
        SelfTests.prepareAccessibility()
        func themeButton(_ node: Any, label: String) -> NSObject? {
            guard let object = node as? NSObject else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityLabel")),
               object.value(forKey: "accessibilityLabel") as? String == label { return object }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            return (object.value(forKey: "accessibilityChildren") as? [Any] ?? []).lazy.compactMap {
                themeButton($0, label: label)
            }.first
        }
        for color in ThemeColor.allCases {
            guard let button = themeButton(root, label: "\(color.name)色主题"),
                  button.responds(to: NSSelectorFromString("accessibilityPerformPress")) else {
                preconditionFailure("Each theme needs an accessible settings button")
            }
            _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
            await settle()
            precondition(store.settings.theme == color && PerchTheme.shared.selection == color,
                         "Pressing a theme swatch must immediately save and apply its palette")
            precondition(table().theme == color, "Native tabs must receive theme changes without collapsing the sidebar")
            if let row = table().rowView(atRow: 0, makeIfNecessary: true) as? TabSelectionRow {
                precondition(row.theme == color, "Visible native tab rows must redraw with the current theme")
            }
            precondition(root.bounds.size == NSSize(width: 780, height: 580), "Theme changes must not resize the settings window")
        }
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to:
                FileManager.default.temporaryDirectory.appendingPathComponent("perch-theme-settings.png"))
        }
        _ = themeButton(root, label: "\(initial.theme.name)色主题")?.perform(NSSelectorFromString("accessibilityPerformPress"))
        await settle()
        print("PASS: eight accessible settings swatches apply and save without resizing the manager")
        func numberField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, Double(field.stringValue) != nil { return field }
            return view.subviews.lazy.compactMap { numberField($0) }.first
        }
        let field = numberField(root)!
        NSApp.activate(ignoringOtherApps: true)
        sheet.makeKeyAndOrderFront(nil)
        sheet.makeFirstResponder(field)
        await settle()
        guard let editor = sheet.firstResponder as? NSTextView else {
            fputs("FAIL: the settings numeric field must install its native field editor\n", stderr)
            exit(1)
        }
        editor.insertText("0.25", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                NSApp.sendEvent(event)
            }
        }
        let fieldRect = field.convert(field.bounds, to: nil)
        click(NSPoint(x: fieldRect.minX + 10, y: fieldRect.midY))
        await settle()
        precondition(sheet.firstResponder === editor, "Clicking inside the numeric field must retain editing")
        click(NSPoint(x: fieldRect.maxX + 150, y: fieldRect.midY))
        await settle()
        precondition(!(sheet.firstResponder is NSTextView), "Clicking settings whitespace must end numeric editing")
        precondition(store.settings.linkPreviewDelay == 0.25, "Ending numeric editing must save the entered decimal")
        func pagePicker(_ view: NSView) -> NSSegmentedControl? {
            if let picker = view as? NSSegmentedControl, picker.segmentCount == LibraryPage.allCases.count { return picker }
            return view.subviews.lazy.compactMap { pagePicker($0) }.first
        }
        let picker = pagePicker(root)!
        let frame = sheet.frame
        for page in LibraryPage.allCases.filter({ $0 != .settings }) + [.settings] {
            let index = LibraryPage.allCases.firstIndex(of: page)!
            picker.selectedSegment = index
            _ = picker.sendAction(picker.action!, to: picker.target)
            precondition(sheet.frame == frame, "Changing library pages must not immediately resize the window")
            await settle()
            precondition(panel.sheets.first === sheet && sheet.frame == frame &&
                         root.bounds.size == NSSize(width: 780, height: 580),
                         "All library pages must preserve the same sheet and content size")
            if page == .importer {
                for label in ["导出 ZIP…", "导入 ZIP…"] {
                    guard let button = themeButton(root, label: label),
                          let frame = (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
                        preconditionFailure("Backup actions must be accessible")
                    }
                    precondition(frame.width > 40 && frame.height > 10 && sheet.frame.contains(frame),
                                 "Backup actions must be visible in the fixed-size manager")
                }
            }
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let color = bitmap.colorAt(x: Int(10 * CGFloat(bitmap.pixelsWide) / root.bounds.width),
                                       y: Int(150 * CGFloat(bitmap.pixelsHigh) / root.bounds.height))!
                .usingColorSpace(.deviceRGB)!
            precondition(abs(color.redComponent - 0.98) < 0.015 && abs(color.greenComponent - 0.98) < 0.015 &&
                         abs(color.blueComponent - 0.96) < 0.015, "All library pages must share the warm paper background")
        }
        precondition(!(sheet.firstResponder is NSTextView), "Returning to settings must not auto-focus numeric input")
        print("PASS: native library picker preserves the same 780x580 window and paper background through all \(LibraryPage.allCases.count) pages")
        store.library = nil
        await settle()
        let originalFrame = panel.frame
        func closeSettings() {
            guard let current = panel.attachedSheet, let content = current.contentView,
                  let done = themeButton(content, label: "完成"),
                  let buttonFrame = (done.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
                preconditionFailure("Settings must expose its Done button")
            }
            current.makeKeyAndOrderFront(nil)
            let point = current.convertPoint(fromScreen: NSPoint(x: buttonFrame.midX, y: buttonFrame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: current.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            }
        }
        let screens = NSScreen.screens.map(\.visibleFrame)
        for (index, bounds) in screens.enumerated() {
            let small = NSRect(x: bounds.minX + 90, y: bounds.minY + 1, width: 700, height: 552)
            panel.setFrame(small, display: true)
            await settle()
            let beforeSheet = panel.frame
            store.library = .settings
            await settle()
            closeSettings()
            await settle()
            precondition(panel.attachedSheet == nil && panel.frame == beforeSheet,
                         "An unmoved tall sheet must retain AppKit's ordinary parent restoration")
            store.library = .settings
            await settle()
            let destination = screens[(index + 1) % screens.count]
            panel.setPlacement(NSRect(origin: NSPoint(x: destination.minX + 120, y: destination.minY + 160),
                                      size: panel.frame.size), display: true)
            await settle()
            let moved = panel.frame
            var dismissalFrames: [NSRect] = []
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                object: panel, queue: nil) { notification in
                    dismissalFrames.append((notification.object as! NSWindow).frame)
                }
            closeSettings()
            await settle()
            NotificationCenter.default.removeObserver(observer)
            precondition(panel.attachedSheet == nil && panel.frame == moved,
                         "Closing a tall sheet must preserve the latest explicit window placement")
            precondition(dismissalFrames.allSatisfy { $0 == moved },
                         "The entire sheet dismissal must stay on the destination, without moving back first")
        }
        panel.setFrame(originalFrame, display: true)
        print("PASS: actual Done clicks restore unmoved parents and keep relocated parents stationary throughout dismissal across \(screens.count) screens")
        try! store.saveSettings(initial)
        print("PASS: settings open without numeric focus; actual clicks retain input focus inside the field, blur on whitespace and save the decimal")
    }
    func run() async {
        setbuf(stdout, nil)
        func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            guard condition() else {
                fputs("FAIL: UI interaction at line \(line): \(message)\n", stderr); exit(1)
            }
        }
        func precondition(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
            check(condition(), message, line: line)
        }
        if !CommandLine.arguments.contains("--verify-address-input") {
        await settle()
        if defaults.bool(forKey: "sidebarHidden") { verify(width: 32) }
        await verifySidebarAnimation()
        await verifyHomeFocusRestoration()
        await verifyAddressComposition()
        await verifyWebContextMenu()
        precondition(RootView.sidebarDragSize(100, available: 850) == 100,
                     "Dragging must retain intermediate widths below the expanded minimum")
        precondition(RootView.sidebarDragSize(-20, available: 850) == 48)
        precondition(RootView.sidebarDragSize(500, available: 850) == 360)
        await settle()
        func resizeHandle(_ view: NSView) -> SidebarResizeHandle.ResizeView? {
            if let handle = view as? SidebarResizeHandle.ResizeView { return handle }
            return view.subviews.compactMap { resizeHandle($0) }.min {
                $0.convert($0.bounds, to: panel.contentView).minX < $1.convert($1.bounds, to: panel.contentView).minX
            }
        }
        let root = panel.contentView!
        let handle = resizeHandle(root)!
        precondition(abs(handle.bounds.width - 7) < 0.5, "Thin divider must retain its 7pt drag target")
        precondition(abs(handle.bounds.height - root.bounds.height +
                         RootView.topBarHeight(chat: store.isChatPage) + Style.chromeRadius) < 1,
                     "Native resize view must start below the toolbar and its rounded corner")
        for y in [CGFloat(10), handle.bounds.midY, handle.bounds.height - 10] {
            let point = handle.convert(NSPoint(x: handle.bounds.maxX - 1, y: y), to: root)
            precondition(root.hitTest(point) === handle, "Visible divider must receive resizing events")
        }
        for y in [CGFloat(-10), -RootView.topBarHeight(chat: store.isChatPage) - Style.chromeRadius + 10] {
            let point = handle.convert(NSPoint(x: handle.bounds.maxX - 1, y: y), to: root)
            guard root.hitTest(point) !== handle else {
                fputs("FAIL: toolbar above the visible divider must not resize: local y=\(y), root point=\(point), handle=\(handle.bounds)\n", stderr)
                exit(1)
            }
        }
        print("PASS: left divider receives resizing below the visible toolbar boundary only")
        let sidebarWidth = defaults.bool(forKey: "sidebarHidden") ? 48 : defaults.double(forKey: "sidebarWidth")
        precondition(abs(root.convert(handle.bounds, from: handle).midX - sidebarWidth - 0.5) < 0.5,
                     "Sidebar divider must occupy only 1pt in layout")
        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let point = handle.convert(NSPoint(x: 1, y: handle.bounds.midY), to: root)
        let color = bitmap.colorAt(x: Int(point.x * CGFloat(bitmap.pixelsWide) / root.bounds.width),
                                   y: Int((root.bounds.height - point.y) * CGFloat(bitmap.pixelsHigh) / root.bounds.height))!
            .usingColorSpace(.deviceRGB)!
        let sidebar = store.settings.theme.sidebar.usingColorSpace(.deviceRGB)!
        precondition(abs(color.redComponent - sidebar.redComponent) < 0.025 &&
                     abs(color.greenComponent - sidebar.greenComponent) < 0.025 &&
                     abs(color.blueComponent - sidebar.blueComponent) < 0.025, "Resize gutter must use the sidebar color without a white strip")
        print("PASS: rendered sidebar resize gutter matches the sidebar background")
        await verifyWindowControlsLayout(handle: handle)
        await verifyLinkPreview()
        // Navigation checks above add pages; the drag scenario owns a fresh three-tab fixture.
        for id in store.tabs.map(\.id) { store.close(id) }
        for title in ["阅读", "工作", "新标签页"] { store.newTab(title: title) }
        do {
            try await AISelfCheck.wait {
                let table = self.table()
                return !table.animatingRows && !table.animatingGroups &&
                    table.ids == self.store.tabs.map(\.id) && table.numberOfRows == self.store.tabs.count
            }
        } catch { fputs("FAIL: tab fixture animations did not settle: \(error)\n", stderr); exit(1) }
        if defaults.bool(forKey: "sidebarHidden") {
            verify(width: 32)
            defaults.set(false, forKey: "sidebarHidden")
            await settle()
        }
        verify(width: 196)
        let dragTable = table()
        let originalIDs = store.tabs.map(\.id)
        dragTable.beginDrag(at: 0)
        dragTable.previewDrag(to: 2)
        await settle()
        guard dragTable.ids == [originalIDs[1], originalIDs[2], originalIDs[0]],
              (dragTable.view(atColumn: 0, row: 2, makeIfNecessary: true) as? TabCell)?.content.isHidden == true,
              (dragTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TabCell)?.label.stringValue == store.tabs[1].title else {
            fputs("FAIL: initial native drag preview: tabs=\(originalIDs.count), rows=\(dragTable.ids), expected=\([originalIDs[1], originalIDs[2], originalIDs[0]])\n", stderr); exit(1)
        }
        precondition(store.tabs.map(\.id) == originalIDs, "Preview must not persist a reorder before release")
        dragTable.previewDrag(to: 1)
        await settle()
        precondition(dragTable.ids == [originalIDs[1], originalIDs[0], originalIDs[2]])
        precondition((dragTable.view(atColumn: 0, row: 1, makeIfNecessary: true) as? TabCell)?.content.isHidden == true)
        store.tabs[0].title = "拖动期间标题更新"
        await settle()
        precondition(dragTable.ids == [originalIDs[1], originalIDs[0], originalIDs[2]],
                     "Metadata changes must preserve the live insertion preview")
        precondition((dragTable.view(atColumn: 0, row: 1, makeIfNecessary: true) as? TabCell)?.content.isHidden == true,
                     "Metadata updates must not reveal the dragged tab's original content")
        dragTable.endDragPreview()
        await settle()
        precondition(dragTable.ids == originalIDs)
        for row in 0..<3 {
            let cell = dragTable.view(atColumn: 0, row: row, makeIfNecessary: true) as! TabCell
            precondition(!cell.content.isHidden)
        }
        dragTable.beginDrag(at: 2)
        dragTable.previewDrag(to: 0)
        await settle()
        precondition(dragTable.ids == [originalIDs[2], originalIDs[0], originalIDs[1]])
        precondition((dragTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TabCell)?.content.isHidden == true)
        dragTable.endDragPreview()
        await settle()
        dragTable.beginDrag(at: 1)
        _ = dragTable.updateDragPosition?(NSPoint(x: 20, y: 20))
        await settle()
        precondition(dragTable.ids == [originalIDs[1], originalIDs[0], originalIDs[2]])
        _ = dragTable.updateDragPosition?(NSPoint(x: 20, y: 64))
        await settle()
        precondition(dragTable.ids == originalIDs, "Returning to the original row must move the placeholder back")
        precondition((dragTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TabCell)?.content.isHidden == false)
        dragTable.endDragPreview()
        await settle()
        let allTabs = store.tabs
        store.tabs = [allTabs[0]]
        await settle()
        dragTable.beginDrag(at: 0)
        _ = dragTable.updateDragPosition?(NSPoint(x: 20, y: 20))
        dragTable.endDragPreview()
        await settle()
        precondition(dragTable.ids == [allTabs[0].id] &&
                     (dragTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TabCell)?.content.isHidden == false,
                     "A single tab must reappear after a no-op drag")
        store.tabs = allTabs
        await settle()
        print("PASS: original-row pointer preview and single-tab no-op drag restore visible content")
        print("PASS: native row insertion preview in both directions, middle slot, stable hidden content during metadata changes and cancellation")
        await verifyTabGroups()
        NSApp.activate(ignoringOtherApps: true)
        panel.focusWindow()
        check(panel.shouldHideForStatusClick(), "Focusing the panel must establish status-click intent")
        let other = Panel(contentRect: NSRect(x: 100, y: 100, width: 160, height: 100),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        // Reproduce the ordering: status bar takes focus before its action is delivered.
        panel.statusItemPressed = { true }
        other.makeKeyAndOrderFront(nil)
        await settle()
        panel.recordFocusLoss(statusItemPress: true)
        check(!panel.isKeyWindow && panel.shouldHideForStatusClick(),
                     "The status click must retain the previously active window's hide intent")
        panel.recordFocusLoss(statusItemPress: false)
        check(!panel.shouldHideForStatusClick(), "A real app switch must instead require activation")
        panel.statusItemPressed = nil
        other.orderOut(nil)
        check(panel.isVisible, "Focus changes must not hide Perch")
        panel.focusWindow()
        check(panel.shouldHideForStatusClick(), "After reactivation the next click must hide")
        store.activate(store.tabs[0].id)
        store.newTab(title: "插入动画")
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(!table().enclosingScrollView!.hasVerticalScroller,
                     "A short list must not flash a scrollbar during insertion")
        await settle()
        verify(width: 196)
        store.close(store.tabs[1].id)
        await settle()
        verify(width: 196)
        store.move(store.tabs.last!.id, to: 0)
        await settle()
        verify(width: 196)
        defaults.set(true, forKey: "sidebarHidden")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try? await Task.sleep(nanoseconds: 90_000_000)
            let width = table().enclosingScrollView!.frame.width
            check(width > 36 && width < 200, "Sidebar collapse must pass through an intermediate width; got \(width)")
        }
        await settle()
        verify(width: 32)
        let cell = table().view(atColumn: 0, row: 0, makeIfNecessary: true) as! TabCell
        check(cell.titleClip.frame.width < 1 && cell.closeButton.isHidden && !cell.icon.isHidden,
              "Compact tabs must show the icon and hide the title and close button")
        let iconRect = table().convert(cell.icon.bounds, from: cell.icon)
        precondition(table().visibleRect.contains(iconRect), "Compact icon must remain fully inside the visible sidebar")
        precondition(abs(cell.frame.width - 36) < 2, "Compact table column must shrink with its viewport")
        table().selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await settle()
        precondition(store.selected == store.tabs[0].id, "Icon rail must still select tabs")
        defaults.set(false, forKey: "sidebarHidden")
        await settle()
        verify(width: 196)
        let expanded = table().view(atColumn: 0, row: 0, makeIfNecessary: true) as! TabCell
        expanded.setHovered(false, animated: false)
        check(!expanded.titleClip.isHidden && expanded.titleClip.alphaValue == 1 &&
                     expanded.closeButton.isHidden, "Expanded tab titles must reappear without persistent close buttons")
        let nextCell = table().view(atColumn: 0, row: 1, makeIfNecessary: true) as! TabCell
        expanded.setHovered(true, animated: false)
        nextCell.setHovered(true, animated: false)
        precondition(!expanded.hovered && nextCell.hovered,
                     "Entering another tab must clear any stale hover state")
        nextCell.setHovered(false, animated: false)
        defaults.set(true, forKey: "sidebarHidden")
        try? await Task.sleep(nanoseconds: 30_000_000)
        defaults.set(false, forKey: "sidebarHidden")
        await settle()
        verify(width: 196)
        precondition(!expanded.titleClip.isHidden && expanded.titleClip.alphaValue == 1,
                     "Interrupted collapse must not leave expanded labels hidden")
        store.reopen()
        store.newTab(); store.close(store.selected!)
        await settle()
        verify(width: 196)
        precondition(defaults.double(forKey: "sidebarWidth") == 212)
        let shortTabs = store.tabs
        store.tabs += (0..<30).map { Tab(title: "长列表 \($0)", address: "") }
        await settle()
        precondition(!table().enclosingScrollView!.hasVerticalScroller,
                     "Overflowing tab lists must scroll without a visible scrollbar")
        table().scrollRowToVisible(store.tabs.count - 1)
        await settle()
        let last = table().view(atColumn: 0, row: store.tabs.count - 1, makeIfNecessary: true) as! TabCell
        precondition(table().visibleRect.contains(table().convert(last.icon.bounds, from: last.icon)),
                     "Last icon \(table().convert(last.icon.bounds, from: last.icon)) outside \(table().visibleRect); table \(table().frame)")
        store.tabs = shortTabs
        await settle()
        precondition(!table().enclosingScrollView!.hasVerticalScroller)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.focusWindow()
        await settle()
        _ = store.add(title: "地址建议合成书签", address: "http://127.0.0.1:9/suggestion-fixture")
        let previousTab = store.selected
        store.newTab()
        await settle()
        let newField = addressField()
        guard let editor = panel.firstResponder as? NSTextView, newField.currentEditor() === editor else {
            fputs("FAIL: new empty tabs must focus the toolbar after its native field attaches\n", stderr)
            exit(1)
        }
        editor.insertText("直接输入", replacementRange: NSRange(location: NSNotFound, length: 0))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("与粘贴", forType: .string)
        precondition(editor.readSelection(from: pasteboard), "New tab's focused editor must accept pasted text")
        precondition(editor.string == "直接输入与粘贴")
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let oldCoordinator = newField.delegate as! AddressTextField.Coordinator
        let oldTab = store.selected!
        store.newTab()
        precondition(!oldCoordinator.parent.canFocus(oldTab),
                     "A previous field must reject the new tab's focus request")
        await settle()
        precondition(addressField().stringValue.isEmpty && addressField().currentEditor() != nil,
                     "A second empty tab must not retain the previous address draft")
        let secondTab = store.selected!
        let homeFixture = HomePageFixture(store: store, panel: panel)
        let homeWeb = try! await homeFixture.home()
        try! await homeFixture.click("#search", web: homeWeb)
        precondition((panel.firstResponder as? NSView)?.isDescendant(of: homeWeb) == true,
                     "The homepage search must accept native WebKit focus")
        store.activate(oldTab)
        await settle()
        precondition(addressField().currentEditor() === panel.firstResponder &&
                     (panel.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 2, length: 3),
                     "Returning to a tab must restore its last focused control and text selection")
        store.activate(secondTab)
        await settle()
        precondition((panel.firstResponder as? NSView)?.isDescendant(of: homeWeb) == true,
                     "Returning to an empty tab must restore its retained WebKit search focus")
        store.close(store.selected!)
        store.close(store.selected!)
        store.newTab()
        store.selected = previousTab
        await settle()
        precondition(store.pendingAddressFocus == nil, "Rapid tab switches must cancel pending focus")
        print("PASS: new tab accepts direct input/paste, clears old drafts and cancels stale focus")
        NotificationCenter.default.post(name: .focusAddress, object: nil)
        await settle()
        let field = addressField()
        precondition(panel.firstResponder === field.currentEditor(), "Command-L must focus only the toolbar address")
        editAddress("地址建议")
        await settle()
        let coordinator = field.delegate as! AddressTextField.Coordinator
        // Keep visible suggestions available between input and the asynchronous replacement.
        for text in ["地址建议合", "地址建议合成", "地址建议合成书"] {
            editAddress(text)
            precondition(coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("moveDown:")),
                         "Typing another character must retain the visible dropdown while searching")
            await settle()
            precondition(coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("moveDown:")))
        }
        editAddress(" ")
        precondition(!coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("moveDown:")),
                     "Clearing input must dismiss suggestions immediately")
        editAddress("地址建议")
        await settle()
        // Repeated edits must cancel older results, and Escape must not let delayed results reopen.
        editAddress("地址建议"); editAddress("missing-query-fixture")
        await settle()
        precondition(!coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("moveDown:")))
        editAddress("地址建议")
        precondition(coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("cancelOperation:")))
        await settle()
        precondition(!coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("moveDown:")))
        // Store mutations invalidate cached results even while the text remains the same.
        editAddress("地址建议新增")
        await settle()
        precondition(!coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("moveDown:")))
        precondition(store.add(title: "地址建议新增", address: "http://127.0.0.1:9/new-suggestion-fixture"))
        await settle()
        precondition(coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("moveDown:")))
        store.sites.removeAll { $0.address == "http://127.0.0.1:9/new-suggestion-fixture" }
        await settle()
        precondition(!coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("moveDown:")))
        editAddress("地址建议")
        await settle()
        precondition(coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("moveDown:")))
        await settle()
        let suggestionEditor = field.currentEditor() as! NSTextView
        suggestionEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(store.tabs.first(where: { $0.id == store.selected })?.address == "http://127.0.0.1:9/suggestion-fixture")
        print("PASS: native address focus, retained dropdown during typing, empty-input dismissal, async suggestions, rapid edits, Escape cancellation, mutation invalidation and arrow/Enter navigation")
        if CommandLine.arguments.contains("--verify-address-input") { return }
        let delegate = AppDelegate(store: store)
        delegate.panel = panel
        delegate.installMenu()
        func command(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = .command) -> Bool {
            let typed = code == 48 && flags.contains(.shift) ? String(UnicodeScalar(NSBackTabCharacter)!) :
                flags.contains(.shift) ? characters.uppercased() : characters
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: panel.windowNumber, context: nil, characters: typed,
                                        charactersIgnoringModifiers: typed, isARepeat: false, keyCode: code)!
            let handled = NSApp.mainMenu!.performKeyEquivalent(with: event)
            return handled
        }
        precondition(command("r", code: 15), "Command-R must be handled while WebKit is active")
        precondition(command("r", code: 15, flags: [.command, .shift]))
        let zoomBrowser = store.browser!
        precondition(command("=", code: 24) && zoomBrowser.webView.pageZoom > 1)
        precondition(zoomBrowser.zoomVisible && zoomBrowser.zoomPercent == 110)
        precondition(command("-", code: 27) && zoomBrowser.zoomPercent == 100)
        precondition(command("=", code: 24) && zoomBrowser.zoomPercent == 110)
        precondition(command("0", code: 29) && zoomBrowser.webView.pageZoom == 1 && zoomBrowser.zoomPercent == 100)
        zoomBrowser.changeZoom(-1)
        precondition(zoomBrowser.zoomPercent == 91)
        zoomBrowser.changeZoom(0)
        precondition(zoomBrowser.zoomPercent == 100)
        precondition(command("f", code: 3) && store.browser!.finding)
        let previousID = store.selected
        precondition(command("\t", code: 48, flags: .control) && store.selected != previousID)
        precondition(command("\t", code: 48, flags: [.control, .shift]) && store.selected == previousID)
        precondition(command("9", code: 25) && store.selected == store.tabs.last?.id)
        precondition(command("1", code: 18) && store.selected == store.tabs.first?.id)
        print("PASS: native menu shortcuts for reload, forced reload, page zoom, find and tab switching")
        await verifySettingsFocus()
        print("PASS: real root layout keeps sidebar width through tab insert/remove/reorder/reopen; rounded rows, icon rail and inactive-window activation")
    }
    private func verifyTabClosing() async {
        SelfTests.prepareAccessibility()
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fputs("FAIL: tab closing: \(message)\n", stderr); exit(1) }
        }
        let savedTabs = store.tabs, savedGroups = store.tabGroups, savedSelection = store.selected
        let savedClosed = store.recentlyClosed
        func plusY() -> CGFloat {
            var visited = Set<ObjectIdentifier>()
            func find(_ node: NSObject) -> CGFloat? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.responds(to: NSSelectorFromString("accessibilityLabel")),
                   node.value(forKey: "accessibilityLabel") as? String == "新建标签页",
                   node.responds(to: NSSelectorFromString("accessibilityFrame")),
                   let frame = node.value(forKey: "accessibilityFrame") as? NSValue { return frame.rectValue.midY }
                var children: [NSObject] = (node as? NSView)?.subviews ?? []
                if node.responds(to: NSSelectorFromString("accessibilityChildren")),
                   let accessible = node.value(forKey: "accessibilityChildren") as? [NSObject] { children += accessible }
                for child in children { if let result = find(child) { return result } }
                return nil
            }
            guard let y = find(panel.contentView!) else { fputs("FAIL: new-tab button frame unavailable\n", stderr); exit(1) }
            return y
        }
        for grouped in [false, true] {
            store.tabs = (0..<4).map { Tab(title: "关闭动画 \($0)", address: "") }
            store.tabGroups = []
            let ids = store.tabs.map(\.id)
            if grouped {
                let group = store.createTabGroup(ids[0])!
                for id in ids.dropFirst() { store.moveTab(id, to: store.tabs.count, groupID: group) }
            }
            store.activate(ids[3])
            store.activate(ids[1])
            await settle()
            let list = table()
            let plusStart = plusY()
            store.newTab()
            let added = store.selected!
            var plusOpeningFrames = 0
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 16_000_000)
                let y = plusY()
                if y < plusStart - 0.5 && y > plusStart - TabSelectionRow.rowHeight + 0.5 { plusOpeningFrames += 1 }
            }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check(plusOpeningFrames > 0, "The new-tab button must move through intermediate positions on insertion")
            }
            store.activate(ids[3]); store.activate(ids[1])
            await settle()
            let index = list.ids.firstIndex(of: ids[1])!
            let cell = list.view(atColumn: 0, row: index, makeIfNecessary: true) as! TabCell
            cell.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered,
                location: cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!)
            await settle()
            check(cell.closeButton.isEnabled && !cell.closeButton.isHidden, "Hover must expose the close button")
            let followingID = list.ids[index + 1]
            let startY = list.rect(ofRow: index + 1).minY
            let button = cell.closeButton
            let plusBeforeClose = plusY()
            let clickStarted = ProcessInfo.processInfo.systemUptime
            await clickInPanel(button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            let clickElapsed = ProcessInfo.processInfo.systemUptime - clickStarted
            var retainedFrames = 0, movingFrames = 0, plusClosingFrames = 0
            var minY = startY, maxY = startY
            var positions: [String] = []
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 16_000_000)
                if cell.window === panel && !cell.visibleRect.isEmpty { retainedFrames += 1 }
                let followingIndex = list.ids.firstIndex(of: followingID)!
                let y = list.rect(ofRow: followingIndex).minY
                positions.append(String(format: "%.3f:%.1f", ProcessInfo.processInfo.systemUptime - clickStarted, y))
                minY = min(minY, y); maxY = max(maxY, y)
                if y < startY - 0.5 && y > startY - TabSelectionRow.rowHeight + 0.5 { movingFrames += 1 }
                let plus = plusY()
                if plus > plusBeforeClose + 0.5 && plus < plusBeforeClose + TabSelectionRow.rowHeight - 0.5 { plusClosingFrames += 1 }
                if list.animatingRows {
                    let moving = list.view(atColumn: 0, row: min(index + 1, list.numberOfRows - 1), makeIfNecessary: true) as! TabCell
                    let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                        context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
                    moving.mouseEntered(with: event)
                    check(!moving.hovered, "Moving rows must not flash hover highlights")
                    moving.mouseExited(with: event)
                }
            }
            check(!store.tabs.contains { $0.id == ids[1] }, "The close button must remove its tab")
            check(store.selected == ids[3], "The close button must restore the previously active tab")
            check(!list.ids.contains(ids[1]) && !list.animatingRows,
                  "Row removal must finish: retained=\(list.ids.contains(ids[1])), animating=\(list.animatingRows), updating=\((list.delegate as! NativeTabList.Coordinator).updating)")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check(retainedFrames > 0, "Outgoing tab content must remain visible during removal, grouped=\(grouped)")
                check(movingFrames > 0, "Remaining rows must move through intermediate positions, grouped=\(grouped), start=\(startY), range=\(minY)...\(maxY), click=\(clickElapsed), retained=\(retainedFrames), plus=\(plusClosingFrames), positions=\(positions)")
                check(plusClosingFrames > 0, "The new-tab button must follow the closing wipe continuously")
            }
            store.close(ids[0]); store.close(ids[2]); store.close(added)
            await settle()
            check(store.selected == ids[3] && list.ids.contains(ids[3]), "Rapid inactive closures must preserve the active tab")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                store.newTab()
                let reversed = store.selected!
                await settle()
                let restoredTab = store.tabs.first { $0.id == reversed }!
                store.close(reversed)
                try? await Task.sleep(nanoseconds: 70_000_000)
                let row = list.ids.firstIndex(of: reversed)!
                let before = list.rect(ofRow: row).height
                // Exercise the row animator's identity-preserving reversal; Store.reopen intentionally creates a new tab.
                store.tabs.append(restoredTab)
                store.activate(reversed)
                try? await Task.sleep(nanoseconds: 16_000_000)
                let after = list.rect(ofRow: list.ids.firstIndex(of: reversed)!).height
                check(before > 0 && after >= before - 2 && abs(after - before) < 8,
                      "Restoring a row during removal must continue from the displayed height")
                await settle()
                check(list.rect(ofRow: list.ids.firstIndex(of: reversed)!).height == TabSelectionRow.rowHeight,
                      "The reversed wipe must finish at full height")
            }
        }
        store.tabs = savedTabs; store.tabGroups = savedGroups; store.selected = savedSelection
        store.recentlyClosed = savedClosed
        await settle()
        print("PASS: native close-button wipes, continuous insertion/removal of the new-tab button, stable moving-row hover and activation history")
        fflush(stdout)
    }
    private func verifyTabBurst() async {
        SelfTests.prepareAccessibility()
        let savedTabs = store.tabs, savedGroups = store.tabGroups, savedSelection = store.selected
        store.tabs = (0..<12).map { Tab(title: "连续新建 \($0)", address: "") }
        store.tabGroups = []
        let first = store.tabs[0].id
        store.homeAddressDrafts[first] = [true: "toolbar draft", false: "central draft"]
        store.activate(first)
        await settle()
        func fields(_ view: NSView) -> [AddressTextField.Field] {
            (view as? AddressTextField.Field).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let originalFields = fields(panel.contentView!)
        precondition(originalFields.count == 1 && originalFields.allSatisfy { $0.ownerTab == first })
        let fixture = HomePageFixture(store: store, panel: panel)
        let originalHome = try! await fixture.home()
        for grouped in [false, true] {
            if grouped { _ = store.createTabGroup(store.selected!) }
            await settle()
            var gaps: [Double] = [], operations: [Double] = []
            var previous = ProcessInfo.processInfo.systemUptime
            // A new selected homepage arrives before the preceding 280ms wipe finishes.
            for tick in 0..<120 {
                if tick % 4 == 0 {
                    let start = ProcessInfo.processInfo.systemUptime
                    store.newTab()
                    operations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                gaps.append((now - previous) * 1000)
                previous = now
            }
            await settle()
            let list = table()
            precondition(!list.animatingRows && Set(list.ids).count == list.ids.count)
            precondition(list.ids == store.tabRows.map(\.id))
            func controller(_ view: NSView) -> TabContentsController? {
                if let found = view.nextResponder as? TabContentsController { return found }
                return view.subviews.lazy.compactMap(controller).first
            }
            precondition(controller(panel.contentView!)?.tabViewItems.count == 2,
                         "Continuous pristine homes must share one controller while the original draft retains its own")
            let sorted = gaps.sorted()
            print(String(format: "MEASURE: burst grouped=%@, tabs=%d, interval median=%.1f p95=%.1f max=%.1f ms, newTab max=%.1f ms",
                         String(grouped), store.tabs.count, sorted[sorted.count / 2],
                         sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!, operations.max()!))
            fflush(stdout)
        }
        let scrolledHome = store.selected!
        let savedSites = store.sites
        store.sites = (0..<40).map { Site(title: "滚动保留 \($0)", address: "https://scroll-\($0).invalid") }
        await settle()
        let scrolledWeb = try! await fixture.home()
        _ = try! await scrolledWeb.evaluateJavaScript("window.scrollTo(0,160)")
        await settle()
        let position = try! await scrolledWeb.evaluateJavaScript("window.scrollY") as! Double
        precondition(position > 0)
        store.newTab()
        await settle()
        store.activate(scrolledHome)
        await settle()
        let returnedWeb = try! await fixture.home()
        let returnedPosition = try! await returnedWeb.evaluateJavaScript("window.scrollY") as! Double
        precondition(returnedWeb === scrolledWeb && returnedPosition == position,
                     "Scrolled HTML homes must retain their WebView and reading position")
        store.sites = savedSites
        store.activate(first)
        await settle()
        let returnedFields = fields(panel.contentView!)
        precondition(Set(originalFields.map(ObjectIdentifier.init)) == Set(returnedFields.map(ObjectIdentifier.init)),
                     "New tabs must not recreate the retained homepage's input fields")
        precondition(returnedFields.allSatisfy { $0.ownerTab == first })
        precondition(returnedFields.first { $0.identifier?.rawValue == "toolbarAddress" }?.stringValue == "toolbar draft")
        let returnedHome = try! await fixture.home()
        let centralDraft = try! await returnedHome.evaluateJavaScript("document.getElementById('search').value") as? String
        precondition(returnedHome === originalHome && centralDraft == "central draft")
        store.tabs = savedTabs; store.tabGroups = savedGroups; store.selected = savedSelection
        await settle()
        print("PASS: overlapping selected-homepage insertions, retained input identity, ownership, drafts and homepage scroll")
    }
    private func verifyTabPerformance() async {
        func check(_ condition: Bool, _ message: String) {
            if !condition { fputs("FAIL: tab performance: \(message)\n", stderr); exit(1) }
        }
        let savedTabs = store.tabs, savedGroups = store.tabGroups, savedSelection = store.selected
        for count in [12, 180] {
            store.tabs = (0..<count).map { Tab(title: "性能 \($0)", address: "") }
            store.tabGroups = []
            store.activate(store.tabs[0].id)
            await settle()
            let list = table(), coordinator = table().delegate as! NativeTabList.Coordinator
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<60 { coordinator.update(list, compact: false, theme: PerchTheme.shared.selection) }
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 60
            print("MEASURE: \(count) tabs, unchanged sidebar update \(String(format: "%.3f", elapsed)) ms")
            fflush(stdout)
            for grouped in [false, true] {
                if grouped {
                    let group = store.createTabGroup(store.tabs[0].id)!
                    for id in store.tabs.dropFirst().map(\.id) { store.moveTab(id, to: store.tabs.count, groupID: group) }
                    await settle()
                }
                for _ in 0..<3 {
                    let started = ProcessInfo.processInfo.systemUptime
                    store.newTab()
                    let added = store.selected!
                    var previous = started, gaps: [Double] = [], heights: [String] = []
                    var intermediate = 0, previousHeight: CGFloat = 0
                    for _ in 0..<24 {
                        try? await Task.sleep(nanoseconds: 16_000_000)
                        let now = ProcessInfo.processInfo.systemUptime
                        gaps.append((now - previous) * 1000)
                        previous = now
                        if let row = list.ids.firstIndex(of: added) {
                            let height = list.rect(ofRow: row).height
                            check(height >= previousHeight - 0.5,
                                  "New-tab wipes must not rebound: count=\(count), grouped=\(grouped), heights=\(heights), now=\(now - started):\(height)")
                            previousHeight = height
                            if height > 0.5 && height < TabSelectionRow.rowHeight - 0.5 { intermediate += 1 }
                            heights.append(String(format: "%.3f:%.1f", now - started, height))
                        } else { heights.append(String(format: "%.3f:missing", now - started)) }
                    }
                    check(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || intermediate >= 4,
                          "New-tab wipes must retain several intermediate frames: count=\(count), grouped=\(grouped), heights=\(heights)")
                    print("MEASURE: \(count) tabs, insertion grouped=\(grouped), maximum interval \(String(format: "%.1f", gaps.max() ?? 0)) ms, heights=\(heights)")
                    fflush(stdout)
                    store.close(added)
                    await settle()
                }
            }
            store.tabGroups = []
            for index in store.tabs.indices { store.tabs[index].groupID = nil }
            let group = store.createTabGroup(store.tabs[0].id)!
            let ids = store.tabs.map(\.id)
            for id in ids.dropFirst() { store.moveTab(id, to: store.tabs.count, groupID: group) }
            store.activate(ids[0])
            await settle()
            var maxGap = 0.0
            for _ in 0..<3 {
                store.toggleTabGroup(group)
                var previous = ProcessInfo.processInfo.systemUptime
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    let now = ProcessInfo.processInfo.systemUptime
                    maxGap = max(maxGap, now - previous)
                    previous = now
                }
            }
            await settle()
            print("MEASURE: \(count) grouped tabs, interrupted wipe maximum event-loop interval \(String(format: "%.1f", maxGap * 1000)) ms")
            precondition(Set(list.ids).count == list.ids.count && !list.animatingGroups,
                         "Interrupted large groups must finish with unique rows")
            fflush(stdout)
        }
        store.tabs = savedTabs; store.tabGroups = savedGroups; store.selected = savedSelection
        await settle()
    }
    private func verifyInternalTabPerformance() async {
        store.tabs = (0..<12).map { Tab(title: "性能 \($0)", address: "") }
        store.tabGroups = []
        store.sites = (0..<120).map { Site(title: "书签 \($0)", address: "https://site-\($0).fixture.invalid/") }
        let icon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
        }
        for site in store.sites { FaviconCache.save(icon, for: site.address, defaults: defaults) }
        store.history = (0..<1000).map {
            Visit(title: "记录 \($0)", address: "https://fixture.invalid/history/\($0)",
                  date: Date().addingTimeInterval(-Double($0) * 60))
        }
        store.activate(store.tabs[0].id)
        // Retain the original home instead of measuring only pristine-home reuse.
        store.homeAddressDrafts[store.selected!] = [true: "retained fixture"]
        await settle()
        let list = table()
        for attempt in 0..<4 {
            for kind in ["home", "downloads", "history"] {
                let start = ProcessInfo.processInfo.systemUptime
                switch kind {
                case "downloads": store.openDownloads()
                case "history": store.openHistory()
                default: store.newTab()
                }
                let created = ProcessInfo.processInfo.systemUptime
                let added = store.selected!
                let internalPage = kind != "home"
                precondition(!internalPage || store.cachedBrowser(for: added) == nil,
                             "Selecting a fresh internal tab must not synchronously create its browser")
                var previous = start, gaps: [Double] = [], intermediate = 0
                for _ in 0..<36 {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    let now = ProcessInfo.processInfo.systemUptime
                    gaps.append((now - previous) * 1000); previous = now
                    if let row = list.ids.firstIndex(of: added) {
                        let height = list.rect(ofRow: row).height
                        if height > 0.5 && height < TabSelectionRow.rowHeight - 0.5 {
                            intermediate += 1
                            precondition(!internalPage || store.cachedBrowser(for: added) == nil,
                                         "WebKit must wait for the native insertion to finish")
                        }
                    }
                }
                print(String(format: "MEASURE: internal %@ attempt=%d create=%.1f first=%.1f animation-max=%.1f ms intermediate=%d",
                             kind, attempt, (created - start) * 1000, gaps.first ?? 0,
                             gaps.dropFirst().max() ?? 0, intermediate))
                fflush(stdout)
                precondition(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || intermediate >= 4,
                             "Internal page opening skipped its tab animation: \(kind), gaps=\(gaps)")
                precondition(!internalPage || store.cachedBrowser(for: added) != nil,
                             "The selected page must start after the wipe")
                store.close(added)
                await settle()
            }
        }
        store.openHistory()
        let cancelled = store.selected!
        store.close(cancelled)
        await settle()
        precondition(store.cachedBrowser(for: cancelled) == nil && !store.pendingInternalPageLoads.contains(cancelled))
        print("PASS: native insertion precedes first WebKit load; closing a pending internal tab cancels its load")
    }
    private func verifyGroupTransition() async {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fputs("FAIL: group transition: \(message)\n", stderr); exit(1) }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.focusWindow()
        let savedTabs = store.tabs, savedGroups = store.tabGroups, savedSelection = store.selected
        let compact = defaults.bool(forKey: "sidebarHidden")
        defaults.set(false, forKey: "sidebarHidden")
        store.tabs = (0..<5).map { Tab(title: "展开裁切 \($0)", address: "") }
        store.tabGroups = []
        let outside = store.tabs[0].id
        let members = store.tabs.dropFirst().map(\.id)
        let group = store.createTabGroup(members[0])!
        store.editTabGroup(group, color: .blue)
        for id in members.dropFirst() { store.moveTab(id, to: store.tabs.count, groupID: group) }
        store.activate(outside)
        store.toggleTabGroup(group)
        await settle()
        var intermediateFrames = 0
        var railOpeningFrames = 0, railClosingFrames = 0
        var memberWipeFrames = 0
        for (active, narrow) in [(outside, false), (members[0], false), (members[2], false), (members.last!, true)] {
            store.activate(active)
            defaults.set(narrow, forKey: "sidebarHidden")
            if !store.tabGroups.first(where: { $0.id == group })!.collapsed { store.toggleTabGroup(group) }
            await settle()
        for (expanding, samples) in [(true, 24), (false, 24), (true, 1), (false, 1), (true, 1), (false, 1),
                                     (true, 5), (false, 5), (true, 24), (false, 24)] {
            panel.focusWindow()
            let list = table()
            let container = list.enclosingScrollView!.superview as! TabListContainer
            let railView = container.railViews[group]!
            let previousProgress = railView.progress
            var activeY: CGFloat?
            let row = list.ids.firstIndex(of: group)!
            let header = list.view(atColumn: 0, row: row, makeIfNecessary: true)!
            let point = header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil)
            let clickStart = ProcessInfo.processInfo.systemUptime
            await clickInPanel(point)
            for sample in 0..<samples {
                try? await Task.sleep(nanoseconds: 16_000_000)
                check(container.layer?.masksToBounds == true, "Animated tab content must be clipped at the native viewport")
                if sample == 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    check(abs(railView.progress - previousProgress) < 0.3,
                          "Reversing a wipe must continue from the displayed line length: before=\(previousProgress), after=\(railView.progress), elapsed=\(ProcessInfo.processInfo.systemUptime - clickStart), expanding=\(expanding), samples=\(samples)")
                }
                let root = panel.contentView!
                let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
                root.cacheDisplay(in: root.bounds, to: bitmap)
                func color(_ point: NSPoint) -> NSColor {
                    bitmap.colorAt(x: Int(point.x * CGFloat(bitmap.pixelsWide) / root.bounds.width),
                        y: Int((root.isFlipped ? point.y : root.bounds.height - point.y) *
                               CGFloat(bitmap.pixelsHigh) / root.bounds.height))!.usingColorSpace(.deviceRGB)!
                }
                let reference = color(header.convert(NSPoint(x: 6, y: header.bounds.midY), to: root))
                let below = color(container.convert(NSPoint(x: 7, y: container.bounds.maxY + 8), to: root))
                check(abs(reference.redComponent - below.redComponent) +
                      abs(reference.greenComponent - below.greenComponent) +
                      abs(reference.blueComponent - below.blueComponent) > 0.2,
                      "The group rail must not paint below the viewport onto the moving new-tab button")
                let line = railView.lineRect
                let totalHeight = list.ids.indices.filter { members.contains(list.ids[$0]) }
                    .reduce(CGFloat(0)) { $0 + list.rect(ofRow: $1).height }
                let retained = members.contains(active) ? TabSelectionRow.rowHeight : 0
                let expectedHeight = max(0, totalHeight - retained * (1 - railView.progress) +
                    31 * (1 - container.expansion) * railView.progress - 4)
                check(abs(line.height - expectedHeight) < 0.02,
                      "The line edge must follow actual clipped tab geometry on every frame")
                let visibleLine = container.convert(line, from: railView).intersection(container.bounds)
                if railView.progress > 0.1 && railView.progress < 0.9 && visibleLine.height > 6 {
                    if expanding { railOpeningFrames += 1 } else { railClosingFrames += 1 }
                    let inside = color(container.convert(NSPoint(x: visibleLine.midX,
                        y: visibleLine.minY + min(8, visibleLine.height / 2)), to: root))
                    let after = color(railView.convert(NSPoint(x: line.midX, y: line.maxY + 4), to: root))
                    check(abs(reference.redComponent - inside.redComponent) +
                          abs(reference.greenComponent - inside.greenComponent) +
                          abs(reference.blueComponent - inside.blueComponent) < 0.075,
                          "The displayed line must stay opaque behind the moving wipe edge: progress=\(railView.progress), line=\(line), viewport=\(container.bounds), actual=\(inside), reference=\(reference)")
                    check(abs(reference.redComponent - after.redComponent) +
                          abs(reference.greenComponent - after.greenComponent) +
                          abs(reference.blueComponent - after.blueComponent) > 0.2,
                          "The line must not jump to its full length ahead of the wipe")
                }
                for index in list.ids.indices where members.contains(list.ids[index]) {
                    if let cell = list.view(atColumn: 0, row: index, makeIfNecessary: false) {
                        check(cell.alphaValue == 1, "Group members must not fade during a wipe")
                        let tabCell = cell as! TabCell
                        let inset = 10 * container.expansion * railView.progress
                        check(abs(tabCell.icon.convert(tabCell.icon.bounds, to: tabCell).minX - 9 - inset) < 0.5,
                              "Grouped icons must move horizontally with disclosure progress instead of jumping on collapse")
                        let selection = list.rowView(atRow: index, makeIfNecessary: false) as? TabSelectionRow
                        check(abs((selection?.extraLeadingInset ?? 0) - inset * 0.7) < 0.01,
                              "Group highlights and icon insets must follow the same displayed progress")
                        let height = list.rect(ofRow: index).height
                        if height > 1 && height < TabSelectionRow.rowHeight - 1 {
                            memberWipeFrames += 1
                            let tabCell = cell as! TabCell
                            check(abs(tabCell.content.frame.height - TabSelectionRow.rowHeight) < 0.5,
                                  "Wiping must clip fixed-size icon content instead of compressing it")
                        }
                    }
                }
                if members.contains(active) {
                    check(store.selected == active && list.ids.contains(active),
                          "The selected grouped tab must stay selected and visible throughout its wipe")
                    let activeRect = list.rect(ofRow: list.ids.firstIndex(of: active)!)
                    check(abs(activeRect.height - TabSelectionRow.rowHeight) < 0.01,
                          "The selected icon must never collapse or reappear during either wipe direction")
                    if let previous = activeY {
                        check(expanding ? activeRect.minY >= previous - 0.5 : activeRect.minY <= previous + 0.5,
                              "The selected icon must move naturally with preceding rows without a rebound: expanding=\(expanding), samples=\(samples), sample=\(sample), oldY=\(previous), newY=\(activeRect.minY), progress=\(railView.progress)")
                    }
                    activeY = activeRect.minY
                    check(list.ids.filter { members.contains($0) } == members.filter { list.ids.contains($0) },
                          "Wiping must preserve the original member order, including the selected tab")
                }
                if expanding && container.bounds.height > 74 && container.bounds.height < 214 {
                    intermediateFrames += 1
                    if intermediateFrames == 1 {
                        try? bitmap.representation(using: .png, properties: [:])?.write(to:
                            FileManager.default.temporaryDirectory.appendingPathComponent("perch-group-opening.png"))
                    }
                }
            }
            check(store.tabGroups.first { $0.id == group }?.collapsed == !expanding,
                  "The actual group header event must toggle its expansion: expanding=\(expanding), samples=\(samples), collapsed=\(store.tabGroups.first { $0.id == group }!.collapsed), progress=\(railView.progress), row=\(row), point=\(point), viewport=\(container.bounds), updating=\((list.delegate as! NativeTabList.Coordinator).updating), hit=\(String(describing: panel.contentView!.hitTest(panel.contentView!.convert(point, from: nil))))")
        }
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(intermediateFrames > 1, "Clipping must be sampled while the group is opening, not only at its endpoints")
            check(railOpeningFrames > 1 && railClosingFrames > 1,
                  "The line itself must animate through intermediate lengths in both directions")
            check(memberWipeFrames > 1, "Group icons must reveal and disappear through intermediate clipped row heights")
        }
        store.toggleTabGroup(group)
        // Fill the viewport so ordinary selection cannot accidentally rely on outer list clipping.
        store.tabs.append(contentsOf: (0..<15).map { Tab(title: "固定位置 \($0)", address: "") })
        await settle()
        let list = table()
        let positions = Dictionary(uniqueKeysWithValues: members.map { id -> (UUID, CGFloat) in
            let cell = list.view(atColumn: 0, row: list.ids.firstIndex(of: id)!, makeIfNecessary: true) as! TabCell
            return (id, cell.icon.convert(cell.icon.bounds, to: panel.contentView!).midY)
        })
        for id in members + members.reversed() {
            panel.focusWindow()
            let row = list.ids.firstIndex(of: id)!
            let cell = list.view(atColumn: 0, row: row, makeIfNecessary: true) as! TabCell
            let point = cell.icon.convert(NSPoint(x: cell.icon.bounds.midX, y: cell.icon.bounds.midY), to: nil)
            await clickInPanel(point)
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 16_000_000)
                for member in members {
                    let index = list.ids.firstIndex(of: member)!
                    let cell = list.view(atColumn: 0, row: index, makeIfNecessary: true) as! TabCell
                    let rowView = list.rowView(atRow: index, makeIfNecessary: true)!
                    check(abs(cell.icon.convert(cell.icon.bounds, to: panel.contentView!).midY - positions[member]!) < 0.5,
                          "Ordinary icon clicks must not change any grouped icon's vertical position")
                    if let displayed = rowView.layer?.presentation() {
                        check(abs(displayed.frame.minY - rowView.frame.minY) < 0.5,
                              "Ordinary icon clicks must not leave a second row-position animation running")
                    }
                }
            }
            check(store.selected == id, "The actual icon click must select the expected member")
        }
        store.tabs = savedTabs; store.tabGroups = savedGroups; store.selected = savedSelection
        defaults.set(compact, forKey: "sidebarHidden")
        await settle()
        print("PASS: group wipe with outside/first/middle/last selection, full-height active icon, stable member order, 16ms reversals, viewport clipping and ordinary icon clicks")
    }
    private func verifySidebarAnimation() async {
        func precondition(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            if !condition() { fputs("FAIL: sidebar animation line \(line): \(message)\n", stderr); exit(1) }
        }
        let initialCompact = defaults.bool(forKey: "sidebarHidden")
        let savedTabs = store.tabs, savedGroups = store.tabGroups, savedSelection = store.selected
        let groupedID = store.tabs[0].id
        let group = store.createTabGroup(groupedID)!
        store.moveTab(store.tabs[1].id, to: 1, groupID: group)
        defaults.set(false, forKey: "sidebarHidden")
        await settle()
        let id = store.tabs.first { $0.groupID == nil }!.id
        func iconX(_ id: UUID) -> CGFloat {
            let list = table()
            let row = list.ids.firstIndex(of: id)!
            let cell = list.view(atColumn: 0, row: row, makeIfNecessary: true) as! TabCell
            return cell.icon.convert(cell.icon.bounds, to: panel.contentView!).midX
        }
        let initialX = iconX(id)
        var widths: [CGFloat] = []
        var groupedPositions: [CGFloat] = []
        var railPositions: [CGFloat] = []
        func toggleSidebar() async {
            func find(_ node: NSObject) -> NSObject? {
                if node.responds(to: NSSelectorFromString("accessibilityLabel")),
                   node.value(forKey: "accessibilityLabel") as? String == "切换侧栏" { return node }
                var children: [NSObject] = (node as? NSView)?.subviews ?? []
                if node.responds(to: NSSelectorFromString("accessibilityChildren")),
                   let accessible = node.value(forKey: "accessibilityChildren") as? [NSObject] { children += accessible }
                return children.lazy.compactMap(find).first
            }
            let button = find(panel.contentView!)!
            let frame = (button.value(forKey: "accessibilityFrame") as! NSValue).rectValue
            await clickInPanel(panel.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)))
        }
        // Six samples reverse before the 220ms transition ends; sixteen finish it.
        for (compact, samples) in [(true, 16), (false, 16), (true, 6), (false, 6), (true, 16), (false, 16)] {
            var captured = false
            await toggleSidebar()
            for sample in 0..<samples {
                try? await Task.sleep(nanoseconds: 16_000_000)
                precondition(defaults.bool(forKey: "sidebarHidden") == compact,
                             "The actual sidebar button must toggle the sidebar")
                let x = iconX(id)
                precondition(abs(x - initialX) < 0.5,
                             "Sidebar animation must keep the icon fixed: expected \(initialX), got \(x)")
                let list = table()
                let container = list.enclosingScrollView!.superview as! TabListContainer
                let progress = container.expansion
                let header = list.view(atColumn: 0, row: list.ids.firstIndex(of: group)!, makeIfNecessary: true) as! TabGroupCell
                precondition(abs(header.expansion - progress) < 0.0001,
                             "Group button disclosure must follow the sidebar without another group click: header=\(header.expansion), sidebar=\(progress)")
                let row = list.ids.firstIndex(of: groupedID)!
                let selection = list.rowView(atRow: row, makeIfNecessary: true) as! TabSelectionRow
                let groupedX = iconX(groupedID)
                precondition(abs(groupedX - initialX - 10 * progress) < 0.5 &&
                             abs(selection.extraLeadingInset - 7 * progress) < 0.01,
                             "Grouped icon and highlight insets must follow the same displayed expansion progress")
                let railView = container.railViews[group]!
                let rail = container.convert(railView.lineRect, from: railView)
                groupedPositions.append(groupedX)
                railPositions.append(rail.minX)
                widths.append(list.enclosingScrollView!.frame.width)
                if (!captured && progress > 0.2 && progress < 0.8) || sample == samples - 1 {
                    let root = panel.contentView!
                    let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    func color(_ point: NSPoint) -> NSColor {
                        bitmap.colorAt(x: Int(point.x * CGFloat(bitmap.pixelsWide) / root.bounds.width),
                            y: Int((root.isFlipped ? point.y : root.bounds.height - point.y) *
                                   CGFloat(bitmap.pixelsHigh) / root.bounds.height))!.usingColorSpace(.deviceRGB)!
                    }
                    let reference = color(header.convert(NSPoint(x: 6, y: 8), to: root))
                    let child = container.convert(list.rect(ofRow: row), from: list)
                    let actual = color(container.convert(NSPoint(x: rail.midX, y: child.midY), to: root))
                    precondition(abs(actual.redComponent - reference.redComponent) < 0.025 &&
                                 abs(actual.greenComponent - reference.greenComponent) < 0.025 &&
                                 abs(actual.blueComponent - reference.blueComponent) < 0.025,
                                 "The group rail must actually render at its intermediate animated position")
                    let arrowX = 18 + progress * (header.bounds.maxX - 33)
                    let foreground = header.group.color.foreground.usingColorSpace(.deviceRGB)!
                    var arrowDifference: CGFloat = 3
                    for dx in -3...3 {
                        for dy in -2...2 {
                            let pixel = color(header.convert(NSPoint(x: arrowX + CGFloat(dx),
                                y: header.bounds.midY + CGFloat(dy)), to: root))
                            arrowDifference = min(arrowDifference, abs(pixel.redComponent - foreground.redComponent) +
                                abs(pixel.greenComponent - foreground.greenComponent) +
                                abs(pixel.blueComponent - foreground.blueComponent))
                        }
                    }
                    precondition(arrowDifference < 0.2,
                                 "The disclosure arrow must render at its current position without clicking the group")
                    if sample == samples - 1, let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
                            compact ? "perch-sidebar-header-compact.png" : "perch-sidebar-header-expanded.png"))
                    }
                    captured = true
                }
            }
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(widths.contains { $0 > 40 && $0 < 190 },
                         "Icon positions must be sampled during a running sidebar width animation")
            precondition(groupedPositions.contains { $0 > initialX + 1 && $0 < initialX + 9 } &&
                         railPositions.contains { $0 > 1.5 && $0 < 5.5 },
                         "Grouped icons and rails must pass through intermediate positions instead of jumping")
        }
        store.tabs = savedTabs; store.tabGroups = savedGroups; store.selected = savedSelection
        defaults.set(initialCompact, forKey: "sidebarHidden")
        await settle()
    }
    private func verifyWindowControlsLayout(handle: SidebarResizeHandle.ResizeView) async {
        final class CloseProbe: NSObject, NSWindowDelegate {
            var calls = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool { calls += 1; return false }
        }
        SelfTests.prepareAccessibility()
        func element(_ node: Any) -> NSObject? {
            guard let value = node as? NSObject else { return nil }
            if value.responds(to: NSSelectorFromString("accessibilityLabel")),
               value.value(forKey: "accessibilityLabel") as? String == "切换侧栏" { return value }
            guard value.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            return (value.value(forKey: "accessibilityChildren") as? [Any] ?? []).lazy.compactMap(element).first
        }
        func controls(_ view: NSView) -> WindowControls.ControlsView? {
            (view as? WindowControls.ControlsView) ?? view.subviews.lazy.compactMap(controls).first
        }
        let initialCompact = defaults.bool(forKey: "sidebarHidden")
        let initialWidth = defaults.double(forKey: "sidebarWidth")
        defaults.set(false, forKey: "sidebarHidden")
        await settle()
        func verify() {
            let root = panel.contentView!
            guard let toggle = element(root),
                  let frame = toggle.value(forKey: "accessibilityFrame") as? NSValue,
                  let lights = controls(root) else {
                preconditionFailure("Window controls and sidebar toggle must be accessible")
            }
            let lightsFrame = panel.convertToScreen(lights.convert(lights.bounds, to: nil))
            let firstRowFrame = table().numberOfRows > 0
                ? table().view(atColumn: 0, row: 0, makeIfNecessary: true).map {
                    panel.convertToScreen($0.convert($0.bounds, to: nil))
                } : nil
            precondition(lights.buttons.count == 3 && lights.buttons.allSatisfy { !$0.isHidden && $0.superview !== lights },
                         "Window controls must reuse the native titlebar group for hover symbols")
            for button in lights.buttons {
                let buttonFrame = panel.convertToScreen(button.convert(button.bounds, to: nil))
                precondition(lightsFrame.insetBy(dx: -1, dy: -1).contains(buttonFrame),
                             "Native titlebar buttons must follow their layout anchor")
                precondition(abs(buttonFrame.midY - frame.rectValue.midY) < 2,
                             "Sidebar toggle must align vertically with the native window controls")
                if !store.isChatPage {
                    let field = addressField()
                    let fieldFrame = panel.convertToScreen(field.convert(field.bounds, to: nil))
                    precondition(abs(buttonFrame.midY - fieldFrame.midY) < 2,
                                 "Address field must align vertically with the native window controls")
                    let rootFrame = panel.convertToScreen(root.convert(root.bounds, to: nil))
                    precondition(abs(rootFrame.maxY - fieldFrame.midY - 22) < 2,
                                 "Address field must have balanced space within the 44pt toolbar")
                }
            }
            precondition(!lightsFrame.intersects(frame.rectValue),
                         "Sidebar toggle must never cross the traffic lights, including during reversal")
            if let rowFrame = firstRowFrame {
                precondition(!rowFrame.intersects(frame.rectValue), "Sidebar toggle must not overlap the first tab")
            }
        }
        verify()
        let initialToggle = element(panel.contentView!)!
        let fixedToggleFrame = (initialToggle.value(forKey: "accessibilityFrame") as! NSValue).rectValue
        let firstRow = table().view(atColumn: 0, row: 0, makeIfNecessary: true)!
        let fixedFirstRowMidY = panel.convertToScreen(firstRow.convert(firstRow.bounds, to: nil)).midY
        NSApp.activate(ignoringOtherApps: true)
        panel.focusWindow()
        await settle()
        let previousDelegate = panel.delegate
        let closeProbe = CloseProbe()
        panel.delegate = closeProbe
        panel.performClose(nil)
        precondition(closeProbe.calls == 1 && panel.isVisible,
                     "Native close must reach the delegate exactly once without recursively clicking itself")
        panel.delegate = previousDelegate
        for compact in [true, false, true, false] {
            defaults.set(compact, forKey: "sidebarHidden")
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                verify()
            }
        }
        await settle()
        defaults.set(145.0, forKey: "sidebarWidth")
        await settle()
        for compact in [true, false] {
            defaults.set(compact, forKey: "sidebarHidden")
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                verify()
            }
        }
        defaults.set(initialWidth, forKey: "sidebarWidth")
        await settle()
        for width in [145.0, 124, 120, 110, 100, 80, 48] {
            handle.changed?(width - initialWidth)
            await settle()
            verify()
            let toggle = element(panel.contentView!)!
            let frame = (toggle.value(forKey: "accessibilityFrame") as! NSValue).rectValue
            precondition(abs(frame.minX - fixedToggleFrame.minX) < 1 &&
                         abs(frame.minY - fixedToggleFrame.minY) < 1,
                         "Dragging a narrow sidebar must keep its toggle fixed beside the traffic lights")
            let cell = table().view(atColumn: 0, row: 0, makeIfNecessary: true) as! TabCell
            let row = panel.convertToScreen(cell.convert(cell.bounds, to: nil))
            precondition(abs(row.midY - fixedFirstRowMidY) < 1,
                         "Collapsing the sidebar must not move tabs down for the fixed toggle")
            let icon = panel.convertToScreen(cell.icon.convert(cell.icon.bounds, to: nil))
            precondition(abs(icon.midX - panel.frame.minX - 24) < 1,
                         "Tab icons must remain left aligned throughout sidebar dragging")
        }
        handle.ended?()
        await settle()
        defaults.set(initialWidth, forKey: "sidebarWidth")
        defaults.set(initialCompact, forKey: "sidebarHidden")
        await settle()
        print("PASS: rendered sidebar toggle stays fixed beside native window buttons without moving or overlapping tabs")
    }
}

@MainActor
final class WindowSelfCheck {
    let panel = Panel(contentRect: NSRect(x: 100, y: 100, width: 160, height: 100),
                      styleMask: [.borderless], backing: .buffered, defer: false)
    init() {
        panel.isReleasedWhenClosed = false
        let suite = "dev.perch.window-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        panel.setFrame(NSRect(x: 130, y: 145, width: 232, height: 176), display: false)
        let savedFrame = panel.frame
        panel.savePlacement(to: defaults)
        let restored = Panel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        restored.isReleasedWhenClosed = false
        let didRestore = restored.restorePlacement(from: defaults)
        precondition(didRestore && restored.frame == savedFrame,
                     "Window frame restore: expected \(savedFrame), got \(restored.frame), restored=\(didRestore)")
        defaults.set("invalid", forKey: "windowFrame")
        precondition(!restored.restorePlacement(from: defaults), "Invalid frame data must be ignored")
        let store = Store(defaults: defaults)
        let delegate = AppDelegate(store: store)
        delegate.panel = restored
        store.settings.followMouseOnShow = true
        delegate.show()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        precondition(screen.visibleFrame.contains(restored.frame))
        let expected = ScreenPlacement.nearMouse(mouse, size: restored.frame.size, in: screen.visibleFrame)
        // AppKit aligns native window origins to screen pixels.
        precondition(abs(restored.frame.minX - expected.minX) <= 1 && abs(restored.frame.minY - expected.minY) <= 1,
                     "Mouse placement: expected \(expected), got \(restored.frame)")
        let followed = restored.frame
        restored.setFrameOrigin(NSPoint(x: followed.minX + 30, y: followed.minY + 30))
        delegate.show()
        precondition(restored.frame == followed, "Every explicit show must reposition near the mouse")
        store.settings.followMouseOnShow = false
        let manual = NSRect(x: screen.visibleFrame.minX + 10, y: screen.visibleFrame.minY + 10, width: 232, height: 176)
        restored.setFrame(manual, display: false)
        delegate.show()
        precondition(restored.frame == manual, "Disabled mouse following must preserve manual placement")
        let importedFrame = NSRect(x: screen.visibleFrame.minX + 50, y: screen.visibleFrame.minY + 60,
                                   width: 700, height: 540)
        defaults.set(NSStringFromRect(importedFrame), forKey: LayoutPreference.windowFrame.rawValue)
        delegate.restoreImportedPlacement()
        precondition(restored.frame == importedFrame, "Imported placement must apply before the current window can overwrite it")
        let deferredFrame = importedFrame.offsetBy(dx: 20, dy: 20)
        delegate.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: restored))
        defaults.set(NSStringFromRect(deferredFrame), forKey: LayoutPreference.windowFrame.rawValue)
        delegate.restoreImportedPlacement()
        delegate.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: restored))
        precondition(restored.frame == importedFrame &&
                     defaults.string(forKey: LayoutPreference.windowFrame.rawValue) == NSStringFromRect(deferredFrame),
                     "Fullscreen transition must defer placement without overwriting imported coordinates")
        delegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: restored))
        precondition(restored.frame == deferredFrame, "Leaving fullscreen must apply pending imported placement")
        for bounds in [NSRect(x: -1600, y: 30, width: 1600, height: 900),
                       NSRect(x: 100, y: -700, width: 700, height: 600)] {
            for point in [NSPoint(x: bounds.minX, y: bounds.minY), NSPoint(x: bounds.maxX, y: bounds.maxY),
                          NSPoint(x: bounds.midX, y: bounds.midY)] {
                let frame = ScreenPlacement.nearMouse(point, size: NSSize(width: 850, height: 660), in: bounds)
                precondition(bounds.contains(frame), "Mouse placement must fit negative-coordinate and smaller displays")
            }
        }
        restored.orderOut(nil)
        print("PASS: real window show follows mouse on each presentation, disabled placement and multi-screen edge fitting")
        panel.showAnimated()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            precondition(panel.isVisible && panel.alphaValue == 1)
            precondition(panel.frame == savedFrame, "Showing must preserve the saved window frame")
            panel.hideAnimated()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
                panel.showAnimated()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                    precondition(panel.isVisible && !panel.isHiding && panel.alphaValue == 1 && !panel.ignoresMouseEvents,
                                 "An old hide completion must not hide the newly shown window")
                    panel.hideAnimated()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                        precondition(!panel.isVisible && !panel.isHiding && panel.alphaValue == 1 && !panel.ignoresMouseEvents)
                        precondition(panel.frame == savedFrame, "Hide/show must preserve both position and size")
                        print("PASS: window frame restoration, fade, interrupted hide/show and mouse-event restoration")
                        exit(0)
                    }
                }
            }
        }
    }
}

@MainActor
enum NavigationSelfCheck {
    static func run(baseURL: String) async throws {
        guard URL(string: baseURL)?.host == "127.0.0.1" else { throw PerchError("Navigation fixture must use loopback") }
        let suite = "dev.perch.navigation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = Browser(url: URL(string: baseURL + "/nav/a")!, dataStore: .nonPersistent(), previewDefaults: defaults)
        func wait(_ condition: () -> Bool) async throws { try await AISelfCheck.wait(timeout: 10, condition) }
        func load(_ path: String) async throws {
            browser.load(URL(string: baseURL + "/nav/" + path)!)
            try await wait { browser.webView.url?.lastPathComponent == path && !browser.webView.isLoading }
        }
        try await wait { browser.webView.title == "a" && !browser.webView.isLoading }
        try await load("b")
        browser.load(URL(string: baseURL + "/nav/slow-headers")!)
        try await wait { browser.webView.isLoading }
        browser.goBack()
        try await wait { !browser.webView.isLoading }
        guard browser.webView.url?.lastPathComponent == "b" && browser.error == nil else { throw PerchError("Provisional back skipped the visible page") }
        try await load("b")
        browser.load(URL(string: baseURL + "/nav/slow-body")!)
        try await wait { browser.webView.title == "slow-body" && browser.webView.isLoading }
        browser.goBack()
        try await wait { !browser.webView.isLoading }
        guard browser.webView.url?.lastPathComponent == "b" else { throw PerchError("Committed back did not reach the previous page") }
        browser.goForward()
        browser.goBack()
        try await wait { !browser.webView.isLoading }
        guard browser.webView.url?.lastPathComponent == "b" else { throw PerchError("Rapid forward/back skipped the starting page") }
        try await load("b")
        browser.load(URL(string: baseURL + "/nav/failure")!)
        try await wait { browser.error != nil }
        browser.goBack()
        try await wait { !browser.webView.isLoading }
        guard browser.webView.url?.lastPathComponent == "b" && browser.error == nil else { throw PerchError("Failed provisional page did not restore the visible page") }
        browser.goBack()
        try await wait { !browser.webView.isLoading }
        guard browser.webView.url?.lastPathComponent == "a" else { throw PerchError("Normal back failed after provisional recovery") }
        browser.goForward()
        try await wait { !browser.webView.isLoading }
        guard browser.webView.url?.lastPathComponent == "b" else { throw PerchError("Normal forward failed after provisional recovery") }
        _ = try await browser.webView.evaluateJavaScript("history.pushState({}, '', '/nav/pushed'); true")
        try await wait { browser.address.hasSuffix("/nav/pushed") }
        browser.goBack()
        try await wait { browser.webView.url?.lastPathComponent == "b" }
        browser.goForward()
        try await wait { browser.webView.url?.lastPathComponent == "pushed" }
        let page = URL(string: baseURL + "/nav/auth-icon")!
        var loadedIcon = false
        browser.favicon.changed = { if $0 != nil { loadedIcon = true } }
        browser.load(page)
        try await wait { loadedIcon }
        precondition(FaviconLoader.sameOrigin(page, URL(string: baseURL + "/nav/auth-icon.png")!))
        precondition(!FaviconLoader.sameOrigin(page, URL(string: "http://127.0.0.1:1/nav/auth-icon.png")!))
        precondition(!FaviconLoader.sameOrigin(page, URL(string: "https://127.0.0.1/nav/auth-icon.png")!))
        print("PASS: authenticated same-origin favicon uses isolated WebKit session")
        print("PASS: provisional cancellation, committed and rapid history navigation, failure recovery and same-document pushState")
        let store = Store(defaults: defaults)
        store.newTab()
        let homeID = store.selected!
        let draft = "  " + baseURL + "/nav/a  "
        store.homeAddressDrafts[homeID] = [false: draft, true: "toolbar draft"]
        store.navigate(draft)
        let homeBrowser = store.browser!
        try await AISelfCheck.wait(timeout: 10) { homeBrowser.webView.title == "a" && !homeBrowser.loading && homeBrowser.canGoBack }
        print("PASS: first home URL navigation establishes a back entry")
        homeBrowser.goBack()
        try await AISelfCheck.wait(timeout: 10) { store.browser == nil && homeBrowser.isHome && !homeBrowser.loading }
        print("PASS: first back restores native home")
        guard store.selected == homeID, store.cachedBrowser(for: homeID) === homeBrowser,
              homeBrowser.canGoForward, homeBrowser.address.isEmpty,
              store.homeAddressDrafts[homeID]?[false] == draft,
              store.homeAddressDrafts[homeID]?[true] == "toolbar draft",
              !store.loadedReferencePages.contains(where: { $0 === homeBrowser }),
              !store.history.contains(where: { $0.address.hasPrefix("perch-home:") }) else {
            throw PerchError("Returning home lost drafts, identity or home isolation")
        }
        homeBrowser.goForward()
        try await AISelfCheck.wait(timeout: 10) { store.browser === homeBrowser && homeBrowser.webView.title == "a" && !homeBrowser.loading }
        homeBrowser.goBack()
        try await AISelfCheck.wait(timeout: 10) { store.browser == nil && !homeBrowser.loading }
        store.settings.searchEngine = "custom"
        store.settings.customSearchURL = baseURL + "/nav/b?q={query}"
        store.navigate("new search")
        try await AISelfCheck.wait(timeout: 10) { homeBrowser.webView.title == "b" && !homeBrowser.loading }
        guard !homeBrowser.canGoForward, homeBrowser.webView.url?.query == "q=new%20search" else {
            throw PerchError("Search from restored home did not replace forward history")
        }
        homeBrowser.goBack()
        try await AISelfCheck.wait(timeout: 10) { store.browser == nil && !homeBrowser.loading }
        store.navigate(baseURL + "/nav/failure")
        try await AISelfCheck.wait(timeout: 10) { homeBrowser.error != nil }
        homeBrowser.goBack()
        try await AISelfCheck.wait(timeout: 10) { store.browser == nil && homeBrowser.error == nil && !homeBrowser.loading }
        store.navigate(baseURL + "/nav/slow-headers")
        try await AISelfCheck.wait(timeout: 10) { homeBrowser.loading }
        homeBrowser.goBack()
        try await AISelfCheck.wait(timeout: 10) { store.browser == nil && !homeBrowser.loading }
        store.newTab()
        guard store.homeAddressDrafts[store.selected!] == nil,
              store.homeAddressDrafts[homeID]?[false] == draft else { throw PerchError("Home drafts leaked across tabs") }
        store.activate(homeID)
        let group = store.createTabGroup(homeID)!
        let count = store.tabs.count
        store.open(Site(title: "首页合成书签", address: baseURL + "/nav/a"))
        try await AISelfCheck.wait(timeout: 10) { homeBrowser.webView.title == "a" && !homeBrowser.loading }
        guard store.selected == homeID, store.tabs.count == count,
              store.tabs.first(where: { $0.id == homeID })?.groupID == group else { throw PerchError("Home bookmark did not reuse its grouped tab") }
        _ = try await homeBrowser.webView.evaluateJavaScript("window.open('/nav/b', '_blank'); true")
        try await AISelfCheck.wait(timeout: 10) { store.tabs.count == count + 1 }
        guard store.tabs.first(where: { $0.id == store.selected })?.groupID == group else { throw PerchError("Page popup escaped its source group") }
        store.activate(homeID)
        store.open(Site(title: "网页合成书签", address: baseURL + "/nav/b"))
        guard store.tabs.count == count + 2,
              store.tabs.first(where: { $0.id == store.selected })?.groupID == group else { throw PerchError("Bookmark from a web tab escaped its group") }
        store.openBookmarks([Site(title: "批量一", address: baseURL + "/nav/a"), Site(title: "批量二", address: baseURL + "/nav/b")])
        guard store.tabs.filter({ $0.groupID == group }).count == 5 else { throw PerchError("Batch bookmarks escaped their group") }
        store.activate(homeID)
        homeBrowser.goBack()
        try await AISelfCheck.wait(timeout: 10) { store.browser == nil && !homeBrowser.loading }
        store.openChat()
        guard store.isChatPage, store.cachedBrowser(for: homeID) === homeBrowser else { throw PerchError("Home to Chat lost navigation history") }
        print("PASS: home bookmark reuse/back, source/current group inheritance, batch bookmarks and home-to-Chat navigation")
        print("PASS: native home back/forward, URL/search branching, drafts, failed/pending navigation and tab isolation")
    }
}

@MainActor
final class WebSelfCheck: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let expectedUA = "Perch-Synthetic-UA/2.0"
    let favicon = FaviconLoader()
    var iconPassed = false
    var cookiePassed = false
    var cookieClearPassed = false
    let passwordBridge = PasswordBridge()
    var passwordPassed = false
    var passwordChecksPassed = false
    let fixtureOrigin = CommandLine.arguments.contains("--http") ? "http://perch-fixture.invalid" : "https://perch-fixture.invalid"
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(passwordBridge, contentWorld: .defaultClient, name: "perchPassword")
        configuration.userContentController.addUserScript(WKUserScript(source: PasswordBridge.script,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.customUserAgent = expectedUA
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        precondition(FaviconLoader.decode(png) != nil && FaviconLoader.decode(Data("not-an-image".utf8)) == nil)
        favicon.changed = { [weak self] image in
            guard let self, image != nil else { return }
            self.iconPassed = true; self.finish()
        }
        view.loadHTMLString("""
            <!doctype html><title>Perch self-check</title><link rel='icon' href='data:image/png;base64,\(png.base64EncodedString())'>
            <form onsubmit="event.preventDefault()"><input autocomplete="username"><input type="password" autocomplete="current-password"><button>Log in</button></form>
            """,
                            baseURL: URL(string: fixtureOrigin + "/"))
        Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in
            fputs("FAIL: WebKit self-check timed out\n", stderr); exit(1)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        favicon.load(from: webView)
        Task { @MainActor [self] in
            do {
                let cookieDataStore = WKWebsiteDataStore.nonPersistent()
                let cookieStore = cookieDataStore.httpCookieStore
                func fixture(_ name: String, _ domain: String) -> HTTPCookie {
                    BrowserImporter.cookie(domain: domain, name: name, value: "synthetic", path: "/",
                                           secure: false, httpOnly: false, expires: Date().addingTimeInterval(3600))!
                }
                let host = "www.perch-cookie.invalid"
                let fixtures = [fixture("host", host), fixture("shared", ".perch-cookie.invalid"),
                                fixture("child", "child." + host), fixture("other", "other.invalid")]
                precondition(WebsiteCookies.matches(fixtures[0], host: host))
                precondition(WebsiteCookies.matches(fixtures[1], host: host))
                precondition(!WebsiteCookies.matches(fixtures[2], host: host))
                precondition(!WebsiteCookies.matches(fixtures[3], host: host))
                precondition(!WebsiteCookies.matches(fixture("boundary", ".evilperch-cookie.invalid"), host: host))
                precondition(!WebsiteCookies.matches(fixture("parent-host-only", "perch-cookie.invalid"), host: host))
                for cookie in fixtures {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        cookieStore.setCookie(cookie) { continuation.resume() }
                    }
                }
                let removed = await WebsiteCookies.clear(host: host, store: cookieStore)
                let remaining: [HTTPCookie] = await withCheckedContinuation { continuation in
                    cookieStore.getAllCookies { continuation.resume(returning: $0) }
                }
                precondition(removed == 2 && Set(remaining.map(\.name)) == Set(["child", "other"]),
                             "Cookie clearing must remove only the current host and shared parent cookies")
                let secondRemoval = await WebsiteCookies.clear(host: host, store: cookieStore)
                precondition(secondRemoval == 0)
                withExtendedLifetime(cookieDataStore) {}
                print("PASS: isolated current-host cookie removal and shared-domain boundaries")
                cookieClearPassed = true; finish()
                let item = SavedPassword(origin: fixtureOrigin, username: "synthetic-user", password: "synthetic-secret")
                if fixtureOrigin.hasPrefix("http:") {
                    let secure = try await view.evaluateJavaScript("window.isSecureContext")
                    precondition(secure as? Bool == false, "HTTP regression must run outside a secure context")
                }
                try await PasswordBridge.fill(item, in: view)
                let filled = try await view.evaluateJavaScript("document.querySelector('input[type=password]').value === 'synthetic-secret' && document.querySelector('input[autocomplete=username]').value === 'synthetic-user'")
                precondition(filled as? Bool == true, "Password filling must set both fields without authentication")
                let exposed = try await view.evaluateJavaScript("typeof window.webkit?.messageHandlers?.perchPassword")
                precondition(exposed as? String == "undefined", "Password capture bridge must be isolated from page scripts")
                passwordBridge.detected = { [weak self] detected in
                    precondition(detected.origin == item.origin && detected.username == item.username && detected.password == item.password)
                    self?.passwordPassed = true; self?.finish()
                }
                _ = try await view.evaluateJavaScript("document.querySelector('form').requestSubmit()")
                var request: (String, NSRect, String)?
                passwordBridge.requested = { origin, rect, token in request = (origin, rect, token) }
                _ = try await view.evaluateJavaScript("document.querySelector('input[autocomplete=username]').focus()")
                try await Task.sleep(nanoseconds: 100_000_000)
                guard let first = request else { preconditionFailure("Focusing username must request the password picker") }
                precondition(first.0 == item.origin && first.1.width > 0 && first.1.height > 0)
                _ = try await view.evaluateJavaScript("""
                    document.body.insertAdjacentHTML('beforeend','<form id="other"><input autocomplete="username"><input type="password"></form>');
                    document.querySelector('#other input[type=password]').focus()
                    """)
                try await Task.sleep(nanoseconds: 100_000_000)
                guard let second = request else { preconditionFailure("Password field must request the password picker") }
                precondition(second.2 != first.2)
                do { try await PasswordBridge.fill(item, in: view, token: first.2); preconditionFailure("Stale field token must be rejected") }
                catch {}
                let selected = SavedPassword(origin: item.origin, username: "second-user", password: "second-secret")
                try await PasswordBridge.fill(selected, in: view, token: second.2)
                let targeted = try await view.evaluateJavaScript("""
                    document.querySelector('#other input[type=password]').value === 'second-secret' &&
                    document.querySelector('#other input[autocomplete=username]').value === 'second-user' &&
                    document.querySelector('form input[type=password]').value === 'synthetic-secret'
                    """)
                precondition(targeted as? Bool == true, "Picker must fill only the clicked form on a page with multiple logins")
                _ = try await view.evaluateJavaScript("document.querySelector('#other').remove()")
                do { try await PasswordBridge.fill(item, in: view, token: second.2); preconditionFailure("Removed fields must reject filling") }
                catch {}
                let other = SavedPassword(origin: "https://other.invalid", username: "synthetic-user", password: "synthetic-secret")
                do { try await PasswordBridge.fill(other, in: view); preconditionFailure("Cross-origin filling must be rejected") }
                catch {}
                _ = try await view.evaluateJavaScript("document.querySelector('input[type=password]').autocomplete = 'new-password'")
                request = nil
                _ = try await view.evaluateJavaScript("document.querySelector('input[type=password]').focus()")
                try await Task.sleep(nanoseconds: 100_000_000)
                precondition(request == nil, "Registration field must not offer saved passwords")
                do { try await PasswordBridge.fill(item, in: view); preconditionFailure("Registration filling must be rejected") }
                catch {}
                print("PASS: isolated field-focus picker, targeted multi-form unauthenticated fill, stale/removed target and registration/cross-origin rejection (\(fixtureOrigin))")
                passwordChecksPassed = true; finish()
            } catch {
                fputs("FAIL: synthetic password WebKit check: \(error.localizedDescription)\n", stderr); exit(1)
            }
        }
        webView.evaluateJavaScript("navigator.userAgent") { [self] value, error in
            precondition(error == nil && value as? String == expectedUA)
            let cookie = BrowserImporter.cookie(domain: ".perch-fixture.invalid", name: "session", value: "synthetic-only", path: "/",
                                                 secure: true, httpOnly: true, expires: Date().addingTimeInterval(3600), sameSite: "Strict")!
            let store = view.configuration.websiteDataStore.httpCookieStore
            store.setCookie(cookie) {
                store.getAllCookies { cookies in
                    guard let actual = cookies.first(where: { $0.name == "session" }) else { preconditionFailure("Cookie was not written") }
                    precondition(actual.value == cookie.value && actual.isSecure && actual.isHTTPOnly)
                    precondition(actual.sameSitePolicy == .sameSiteStrict)
                    self.cookiePassed = true
                    self.finish()
                }
            }
        }
    }
    private func finish() {
        guard iconPassed && cookiePassed && cookieClearPassed && passwordPassed && passwordChecksPassed else { return }
        print("PASS: WKWebView custom UA, document favicon, and non-persistent Cookie write/read with Secure, HttpOnly and SameSite")
        exit(0)
    }
}
