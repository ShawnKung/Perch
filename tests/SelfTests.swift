import Foundation
import SQLite3
import CommonCrypto
import AppKit
import WebKit
import SwiftUI
import Security
import Carbon

enum SelfTests {
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
        try BackupSelfCheck.run()
        try addressSuggestions()
        try databaseSnapshot()
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
        store.mergeHistory([Visit(title: "Example", address: "https://example.com", date: Date(timeIntervalSince1970: 123456))])
        store.mergeHistory(store.history)
        precondition(store.history.count == 1)
        precondition(Store(defaults: defaults).history.count == 1)
        store.deleteHistory()
        precondition(Store(defaults: defaults).history.isEmpty)
        let address = "https://perch-bookmark.invalid"
        precondition(store.bookmark(for: address) == nil)
        store.toggleBookmark(title: "Star test", address: address)
        precondition(store.bookmark(for: address + "/") != nil)
        precondition(store.bookmark(for: address + "/other") == nil)
        precondition(Store(defaults: defaults).bookmark(for: address) != nil)
        store.toggleBookmark(title: "Star test", address: address + "/")
        precondition(store.bookmark(for: address) == nil && Store(defaults: defaults).bookmark(for: address) == nil)
        print("PASS: bookmark star URL matching, toggle and persistence")
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
        store.toggleBookmark(title: "", address: leaf.address!)
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
    init(board: NSPasteboard, table: BookmarkOutline) {
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
            else { await run() }
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
        precondition(!folderDelegate.outlineView(table, shouldShowOutlineCellForItem: folderFixture),
                     "Bookmark folders must not show disclosure arrows")
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
    func homeAddressField() -> NSTextField {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == "homeAddress" { return field }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(panel.contentView!)!
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
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        panel.focusWindow()
        await settle()
        let focusDeadline = Date().addingTimeInterval(3)
        while !NSApp.isActive || !panel.isKeyWindow {
            guard Date() < focusDeadline else {
                fputs("FAIL: focus restoration fixture could not activate its isolated window\n", stderr); exit(1)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let selected = store.selected, let other = store.tabs.first(where: { $0.id != selected }) else {
            preconditionFailure("Homepage focus fixture requires two tabs")
        }
        for (home, throughTable) in [(true, true), (false, true), (true, false), (false, false)] {
            let field = home ? homeAddressField() : addressField()
            panel.makeFirstResponder(field)
            guard field.currentEditor() === panel.firstResponder else {
                fputs("FAIL: could not focus \(home ? "home search" : "toolbar address") before switching\n", stderr); exit(1)
            }
            let editor = field.currentEditor() as! NSTextView
            let draft = home ? "首页草稿 fixture" : "地址草稿 fixture"
            editor.selectAll(nil)
            editor.insertText(draft, replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.setSelectedRange(NSRange(location: 2, length: 1))
            // AppKit transfers first responder before the table receives mouseDown.
            if throughTable { panel.makeFirstResponder(table()) }
            store.activate(other.id)
            await settle()
            let otherField = home ? homeAddressField() : addressField()
            guard otherField.stringValue != draft else {
                fputs("FAIL: homepage drafts leaked between tabs\n", stderr); exit(1)
            }
            if throughTable { panel.makeFirstResponder(table()) }
            store.activate(selected)
            await settle()
            let restored = home ? homeAddressField() : addressField()
            let restoreDeadline = Date().addingTimeInterval(3)
            while restored.currentEditor() !== panel.firstResponder || restored.currentEditor() == nil {
                guard Date() < restoreDeadline else { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard restored.currentEditor() === panel.firstResponder else {
                fputs("FAIL: did not restore \(home ? "home search" : "toolbar address") after switching: key=\(panel.isKeyWindow), active=\(NSApp.isActive), responder=\(String(describing: panel.firstResponder)), editor=\(String(describing: restored.currentEditor()))\n", stderr); exit(1)
            }
            guard restored.currentEditor()?.string == draft,
                  (restored.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 2, length: 1) else {
                fputs("FAIL: did not restore \(home ? "home search" : "toolbar address") text and selection: text=\(restored.currentEditor()?.string ?? "nil"), selection=\(String(describing: (restored.currentEditor() as? NSTextView)?.selectedRange()))\n", stderr); exit(1)
            }
        }
        print("PASS: homepage search and address drafts, focus and selection survive table and direct tab switches without leaking")
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
        let host = NSHostingView(rootView: HomeScreen(store: store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 150, y: 180, width: 780, height: 580),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; panel.makeKeyAndOrderFront(nil) }
        await settle()
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.delegate is AddressTextField.Coordinator { return field }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let field = find(host)!
        window.makeFirstResponder(field)
        let editor = field.currentEditor() as! NSTextView
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let sites = store.sites
        store.sites = sites
        await settle()
        fflush(stdout)
        precondition(editor.string == "n" && editor.hasMarkedText(), "Redrawing the homepage must not swallow the first IME letter")
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        store.sites = sites
        await settle()
        fflush(stdout)
        precondition(editor.string == "ni" && editor.hasMarkedText())
        let coordinator = field.delegate as! AddressTextField.Coordinator
        for command in ["moveDown:", "moveUp:", "insertNewline:", "cancelOperation:"] {
            precondition(!coordinator.control(field, textView: editor, doCommandBy: NSSelectorFromString(command)),
                         "IME candidate keys must remain with the native input method")
        }
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle()
        fflush(stdout)
        precondition(!editor.hasMarkedText() && editor.string == "你" && coordinator.parent.text == "你")
        editor.insertText("好", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle()
        precondition(editor.string == "你好" && coordinator.parent.text == "你好")
        precondition(field.focusRingType == .none, "The homepage must not show an inner blue focus ring")
        print("PASS: homepage native IME first letter, composition across redraws, candidate keys, Chinese commit and plain focus appearance")
        store.sites = (0..<8).map { Site(title: "Suggestion fixture \($0)", address: "https://suggestion-\($0).invalid/") }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("Suggestion fixture", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle()
        let fieldRect = field.convert(field.bounds, to: nil)
        let point = NSPoint(x: fieldRect.midX, y: fieldRect.minY - 30 - 3 * 49 - 20)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            window.sendEvent(event)
        }
        await settle()
        precondition(store.tabs.first(where: { $0.id == store.selected })?.address.hasPrefix("https://suggestion-") == true,
                     "Suggestion rows overlapping homepage cards must receive mouse clicks")
        store.sites = sites
        print("PASS: homepage suggestion dropdown receives clicks above the Chat and shortcut cards")
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
    func verifyWebContextMenu() async {
        let browser = Browser(url: URL(string: "https://perch-context.invalid/")!, dataStore: .nonPersistent())
        browser.webView.stopLoading()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = browser.webView
        window.makeKeyAndOrderFront(nil)
        defer { browser.webView.stopLoading(); window.close(); panel.makeKeyAndOrderFront(nil) }
        browser.webView.loadHTMLString("<html><body><p>Native context menu fixture</p><a href='https://link.invalid/'>Link</a></body></html>",
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
        let point = NSPoint(x: 300, y: 200)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: browser.webView.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        DispatchQueue.main.async {
            let hit = browser.webView.hitTest(point) ?? browser.webView
            hit.rightMouseDown(with: event)
        }
        await settle()
        guard let menu = trackedWebMenu else { preconditionFailure("A real WebKit right click must open a native menu") }
        precondition(menu.items.contains { $0.title == "复制当前网址" },
                     "WebKit's native context menu must include Perch actions")
        let sentinel = NSMenuItem(title: "Native link action fixture", action: nil, keyEquivalent: "")
        let retained = NSMenu(); retained.addItem(sentinel)
        browser.extendContextMenu(retained)
        let count = retained.items.count
        browser.extendContextMenu(retained)
        precondition(retained.items.first === sentinel && retained.items.count == count)
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
        precondition(savedMenu.items.contains { $0.title == "移除书签" })
        browser.address = "javascript:alert(1)"
        precondition(browser.validateMenuItem(copy), "Copy keeps the menu-opening URL snapshot")
        let invalid = NSMenu(); browser.extendContextMenu(invalid)
        precondition(invalid.items.first { $0.title == "复制当前网址" }?.isEnabled == false)
        print("PASS: actual WebKit right-click menu, native item preservation, navigation availability, isolated clipboard, find and URL validation")
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
                if browser.hoverLinks?.site?.address == expected { return }
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
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                panel.focusWindow()
                panel.makeFirstResponder(browser.webView)
                await settle()
                if NSApp.isActive && panel.isKeyWindow && browser.webView.window === panel { return }
            }
            check(false, "Link preview fixture could not activate its isolated window")
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
            fputs("FAIL: holding Alt on a link must present a preview\n", stderr); exit(1)
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
        precondition(LibraryPage.allCases.map(\.rawValue) == ["常规", "AI", "书签与历史", "密码", "导入导出"],
                     "Manager tabs must keep the requested labels and order")
        precondition(!(sheet.firstResponder is NSTextView), "Opening settings must not auto-focus numeric input")
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
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
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
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
        try! store.saveSettings(initial)
        print("PASS: settings open without numeric focus; actual clicks retain input focus inside the field, blur on whitespace and save the decimal")
    }
    func run() async {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            guard condition() else {
                fputs("FAIL: UI interaction at line \(line): \(message)\n", stderr); exit(1)
            }
        }
        await settle()
        if defaults.bool(forKey: "sidebarHidden") { verify(width: 32) }
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
        await settle()
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
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
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
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
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
        let homeField = homeAddressField()
        panel.makeFirstResponder(homeField)
        precondition(homeField.currentEditor() === panel.firstResponder,
                     "The homepage search field must accept native focus")
        store.activate(oldTab)
        await settle()
        precondition(addressField().currentEditor() === panel.firstResponder &&
                     (panel.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 2, length: 3),
                     "Returning to a tab must restore its last focused control and text selection")
        store.activate(secondTab)
        await settle()
        precondition(homeAddressField().currentEditor() === panel.firstResponder,
                     "Returning to an empty tab must restore the rebuilt homepage search field")
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
        precondition(coordinator.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("insertNewline:")))
        precondition(store.tabs.first(where: { $0.id == store.selected })?.address == "http://127.0.0.1:9/suggestion-fixture")
        print("PASS: native address focus, retained dropdown during typing, empty-input dismissal, async suggestions, rapid edits, Escape cancellation, mutation invalidation and arrow/Enter navigation")
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
    private func verifyWindowControlsLayout(handle: SidebarResizeHandle.ResizeView) async {
        final class CloseProbe: NSObject, NSWindowDelegate {
            var calls = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool { calls += 1; return false }
        }
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
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
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
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
