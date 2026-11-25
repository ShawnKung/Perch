import AppKit
import SwiftUI
import WebKit

@MainActor
enum DownloadSelfCheck {
    static func data() throws {
        let suite = "dev.perch.downloads.data.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)
        var record = DownloadRecord(source: URL(string: "https://fixture.invalid/file")!, filename: "fixture.txt")
        record.destination = file; record.state = .completed; record.received = 7; record.total = 7
        precondition(record.available && record.fraction == 1)
        precondition(DownloadController.destination(filename: "../../fixture.txt", directory: directory, reserved: []) ==
                     directory.appendingPathComponent("fixture (1).txt"))
        precondition(DownloadController.destination(filename: "fixture.txt", directory: directory,
                                                    reserved: [directory.appendingPathComponent("fixture (1).txt")]) ==
                     directory.appendingPathComponent("fixture (2).txt"))
        defaults.set(try JSONEncoder().encode([record]), forKey: "downloads")
        let downloads = DownloadController(defaults: defaults, directory: directory)
        precondition(downloads.records.count == 1 && downloads.records[0].available)
        try FileManager.default.removeItem(at: file)
        precondition(!downloads.records[0].available)
        downloads.clear()
        precondition(DownloadController(defaults: defaults).records.isEmpty)
        record.state = .downloading
        defaults.set(try JSONEncoder().encode([record]), forKey: "downloads")
        precondition(DownloadController(defaults: defaults).records[0].state == .failed)
        let malformed = Data("invalid fixture".utf8)
        defaults.set(malformed, forKey: "downloads")
        let corrupt = DownloadController(defaults: defaults)
        corrupt.clear()
        precondition(corrupt.storageError != nil && defaults.data(forKey: "downloads") == malformed)
        precondition(DownloadsPage.matches(URL(string: "perch://downloads/")))
        for raw in ["perch://downloads.evil", "perch://downloads/path", "perch://downloads?x=1",
                    "perch://user@downloads", "https://downloads"] {
            precondition(!DownloadsPage.matches(URL(string: raw)))
        }
        precondition(URLInput.parse("perch://downloads", search: false) == nil,
                     "Internal navigation must not widen bookmark or external URL validation")
        precondition(URLInput.parseNavigation(" PERCH://downloads/ ", search: false) == DownloadsPage.url)
        var group = TabGroup(name: "Downloads")
        var tab = Tab(title: "下载记录", address: DownloadsPage.url.absoluteString)
        tab.groupID = group.id; group.hiddenTabs = [tab]
        try TabGroup.validateStoredTabs([group])
        defaults.set(try JSONEncoder().encode([group]), forKey: "tabGroups")
        let store = Store(defaults: defaults, downloadDirectory: directory)
        store.openTabGroup(group.id)
        precondition(store.tabs.count == 1 && DownloadsPage.matches(URL(string: store.tabs[0].address)))
        precondition(store.browser?.downloads === store.downloads)
        print("PASS: download persistence, missing files, safe duplicate filenames, interruption, corrupt-data preservation and internal URL boundaries")
    }

    static func run(baseURL: String) async throws {
        setbuf(stdout, nil)
        guard URL(string: baseURL)?.host == "127.0.0.1" else { throw PerchError("Download fixture must use loopback") }
        let suite = "dev.perch.downloads.web.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let downloads = DownloadController(defaults: defaults, directory: directory)
        var browser: Browser? = Browser(url: URL(string: baseURL + "/page")!, dataStore: .nonPersistent(),
                                        previewDefaults: defaults, downloads: downloads)
        func wait(_ condition: () -> Bool) async throws { try await AISelfCheck.wait(timeout: 15, condition) }
        try await wait { browser?.webView.title == "Downloads fixture" && browser?.loading == false }
        let view = browser!.webView
        let bridgeVisible = try await view.evaluateJavaScript("!!window.webkit?.messageHandlers?.perchInternal") as? Bool
        guard bridgeVisible == false else { throw PerchError("Website can access the internal-page bridge") }
        _ = try await view.evaluateJavaScript("document.getElementById('slow').click(); true")
        try await wait { downloads.progressRecord?.received ?? 0 > 0 }
        let slow = downloads.progressRecord!.id
        guard downloads.progressRecord?.fraction != nil else { throw PerchError("Known size has no progress: \(downloads.records.map(\.detail))") }
        print("PASS: known download begins with determinate byte progress")
        _ = try await view.evaluateJavaScript("document.getElementById('fast').click(); true")
        try await wait { downloads.records.count == 2 && downloads.records[0].state == .completed }
        guard downloads.progressRecord?.id == slow else {
            throw PerchError("Newest completed download did not yield to older task: \(downloads.records.map(\.detail))")
        }
        let fast = downloads.records[0]
        let fastData = try Data(contentsOf: fast.destination!)
        guard fast.available && fastData == Data("fast fixture".utf8) else { throw PerchError("Fast file content differs") }
        guard ["/redirect", "/fast"].contains(fast.source.path) else {
            throw PerchError("Download link does not identify the requested file: \(fast.source)")
        }
        print("PASS: newest completed download yields to older active task; authenticated redirect source=\(fast.source.path)")
        _ = try await view.evaluateJavaScript("document.getElementById('unknown').click(); true")
        try await wait { downloads.records.count == 3 && downloads.records[0].received > 0 }
        guard downloads.progressRecord?.fraction == nil else { throw PerchError("Unknown size became determinate: \(downloads.records.map(\.total))") }
        try await wait { downloads.records.allSatisfy { $0.state == .completed } }
        guard Set(downloads.records.compactMap(\.destination)).count == 3 && downloads.progressRecord == nil else {
            throw PerchError("Completed downloads did not settle with unique files")
        }
        print("PASS: unknown progress and duplicate filename downloads complete")
        _ = try await view.evaluateJavaScript("""
            const a=document.createElement('a'); a.href=URL.createObjectURL(new Blob(['blob fixture']));
            a.download='blob.txt'; a.click(); true
            """)
        try await wait { downloads.records.count == 4 && downloads.records[0].state == .completed }
        let blobData = try Data(contentsOf: downloads.records[0].destination!)
        guard blobData == Data("blob fixture".utf8) else { throw PerchError("Blob file content differs") }
        var closingBrowser: Browser? = Browser(url: URL(string: baseURL + "/page")!, dataStore: .nonPersistent(),
                                              previewDefaults: defaults, downloads: downloads)
        try await wait { closingBrowser?.webView.title == "Downloads fixture" && closingBrowser?.loading == false }
        _ = try await closingBrowser!.webView.evaluateJavaScript("document.getElementById('slow').click(); true")
        try await wait { downloads.progressRecord?.received ?? 0 > 0 }
        downloads.clear()
        closingBrowser = nil
        guard browser?.error == nil else { throw PerchError("Download left navigation error: \(browser!.error!)") }
        browser = nil
        try await wait { !downloads.isDownloading }
        let completedFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard downloads.records.isEmpty && completedFiles.filter({ $0.hasPrefix("fixture") }).count == 4 else {
            throw PerchError("Cleared download did not finish after browser closed: \(completedFiles)")
        }
        print("PASS: WebKit authenticated redirects, attachment and blob downloads, known/unknown progress, multi-task fallback and clearing records while downloads continue")

        let store = Store(defaults: defaults, downloadDirectory: directory)
        func waitForStore(line: UInt = #line, _ condition: () -> Bool) async throws {
            do { try await AISelfCheck.wait(timeout: 15, line: line, condition) }
            catch {
                throw PerchError("Download navigation wait at line \(line): \(error.localizedDescription); tabs=\(store.tabs.map { "\($0.title):\($0.address)" }); browser=\(store.cachedBrowser(for: store.selected!)?.address ?? "nil"); title=\(store.cachedBrowser(for: store.selected!)?.title ?? "nil"); error=\(store.cachedBrowser(for: store.selected!)?.error ?? "nil"); downloads=\(store.downloads.records.map(\.detail))")
            }
        }
        store.newTab()
        let id = store.selected!
        store.navigate(baseURL + "/redirect-public")
        try await waitForStore { store.downloads.records.first?.state == .completed && store.cachedBrowser(for: id)?.loading == false }
        guard store.tabs.first(where: { $0.id == id })?.address.isEmpty == true &&
                store.cachedBrowser(for: id)?.isHome == true && store.cachedBrowser(for: id)?.error == nil && store.history.isEmpty else {
            throw PerchError("Download from a new home did not preserve its page")
        }
        store.navigate(baseURL + "/page")
        try await waitForStore { store.tabs.first(where: { $0.id == id })?.title == "Downloads fixture" && store.browser?.webView.isLoading == false }
        guard store.history.first?.title == "Downloads fixture" else { throw PerchError("Late WebKit title did not update the browsing history") }
        let historyCount = store.history.count
        store.navigate(baseURL + "/redirect-public")
        try await waitForStore { store.downloads.records.count == 2 && store.downloads.records[0].state == .completed && store.browser?.loading == false }
        guard store.tabs.first(where: { $0.id == id })?.address == baseURL + "/page" &&
                store.tabs.first(where: { $0.id == id })?.title == "Downloads fixture" && store.browser?.error == nil && store.history.count == historyCount else {
            throw PerchError("Download navigation did not preserve the website URL/title/history")
        }
        print("PASS: downloads preserve the home and website without adding browsing history")
        store.navigate("perch://downloads")
        try await waitForStore { store.tabs.first(where: { $0.id == id })?.title == "下载记录" && store.browser?.webView.isLoading == false }
        guard store.selected == id && store.history.count == historyCount else {
            throw PerchError("Typed route changed tab selection or wrote browser history")
        }
        let htmlTitle = try await store.browser!.webView.evaluateJavaScript("document.querySelector('h1')?.textContent") as? String
        guard htmlTitle == "下载记录" else { throw PerchError("Downloads route did not load the bundled HTML document") }
        print("PASS: typed downloads URL reaches the HTML page with an isolated bridge")
        store.navigate(baseURL + "/redirect-public")
        try await waitForStore { store.downloads.records.count == 3 && store.downloads.records[0].state == .completed && store.browser?.loading == false }
        guard DownloadsPage.matches(URL(string: store.tabs.first(where: { $0.id == id })?.address ?? "")),
              store.browser?.error == nil && store.history.count == historyCount else {
            throw PerchError("Download redirect replaced the native downloads page or showed an interruption error")
        }
        print("PASS: cross-origin download redirects preserve home, website and internal pages without interruption errors")
        store.openDownloads()
        guard store.selected == id && store.tabs.count == 1 else { throw PerchError("Full downloads opened a duplicate tab") }
        store.navigate(baseURL + "/page")
        try await waitForStore { store.tabs.first(where: { $0.id == id })?.title == "Downloads fixture" && store.browser?.webView.isLoading == false }
        store.browser!.goBack()
        try await waitForStore { store.tabs.first(where: { $0.id == id })?.title == "下载记录" && store.browser?.webView.isLoading == false }
        guard DownloadsPage.matches(URL(string: store.browser!.address)) else { throw PerchError("Back navigation did not restore the internal address") }
        let returnWeb = store.browser!.webView
        store.downloads.clear()
        try await Task.sleep(nanoseconds: 200_000_000)
        let rowCount = try await returnWeb.evaluateJavaScript("document.querySelectorAll('.row').length") as? Int
        guard rowCount == 0 else { throw PerchError("Restored downloads page stopped receiving record changes") }
        let restored = Store(defaults: defaults)
        guard restored.tabs.first.map({ DownloadsPage.matches(URL(string: $0.address)) }) == true else {
            throw PerchError("Internal downloads tab did not persist: \(restored.tabs.map(\.address))")
        }
        print("PASS: typed downloads URL, existing-tab reuse, native title, persistence and back navigation")
        try await ui(record: fast)
    }

    private static func ui(record: DownloadRecord) async throws {
        SelfTests.prepareAccessibility()
        let suite = "dev.perch.downloads.ui.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var missing = record
        missing.id = UUID(); missing.filename = "missing.bin"
        missing.destination = record.destination!.deletingLastPathComponent().appendingPathComponent("missing.bin")
        defaults.set(try JSONEncoder().encode([record, missing]), forKey: "downloads")
        let store = Store(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1100, height: 750),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 300_000_000)
        func element(_ label: String, in root: NSObject) -> NSObject? {
            var seen = Set<ObjectIdentifier>()
            func find(_ object: NSObject) -> NSObject? {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
                if object.responds(to: NSSelectorFromString("accessibilityLabel")),
                   object.value(forKey: "accessibilityLabel") as? String == label,
                   object.responds(to: NSSelectorFromString("accessibilityPerformPress")) { return object }
                var children: [NSObject] = (object as? NSView)?.subviews ?? []
                if object.responds(to: NSSelectorFromString("accessibilityChildren")),
                   let accessible = object.value(forKey: "accessibilityChildren") as? [NSObject] { children += accessible }
                for child in children { if let found = find(child) { return found } }
                return nil
            }
            return find(root)
        }
        func click(_ label: String, in target: NSWindow) async throws {
            guard let root = target.contentView, let button = element(label, in: root),
                  let frame = (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
                throw PerchError("Missing download UI button: \(label)")
            }
            let point = target.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            guard root.hitTest(root.superview?.convert(point, from: nil) ?? point) != nil else {
                throw PerchError("Download UI button has no event path: \(label)")
            }
            NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!, atStart: true)
            target.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try await click("近期下载任务", in: window)
        guard let popover = NSApp.windows.first(where: {
            $0 !== window && $0.isVisible && $0.contentView.flatMap { element("完整的下载记录", in: $0) } != nil
        }) else { throw PerchError("Download toolbar did not present recent records") }
        try await click("完整的下载记录", in: popover)
        try await AISelfCheck.wait { store.tabs.contains { DownloadsPage.matches(URL(string: $0.address)) } }
        guard !popover.isVisible && store.tabs.count == 1 else { throw PerchError("Full records click did not dismiss the popover and create one tab") }
        try await Task.sleep(nanoseconds: 300_000_000)
        let web = store.browser!.webView
        try await AISelfCheck.wait {
            web.url == DownloadsPage.url && !web.isLoading
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        func point(_ selector: String) async throws -> NSPoint {
            let value = try await web.callAsyncJavaScript("""
                const element = document.querySelector(selector);
                if (!element) throw new Error('Missing element: ' + selector);
                const rect = element.getBoundingClientRect();
                return {x:rect.x+rect.width/2,y:rect.y+rect.height/2};
                """, arguments: ["selector": selector], in: nil, contentWorld: .defaultClient)
            guard let coordinates = value as? [String: Double], let x = coordinates["x"], let y = coordinates["y"] else {
                throw PerchError("HTML element has no event target: \(selector)")
            }
            return web.convert(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), to: nil)
        }
        func clickHTML(_ selector: String) async throws {
            let location = try await point(selector)
            NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!, atStart: true)
            window.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        try await AISelfCheck.wait { NSApp.isActive && window.isKeyWindow }
        let rowPoint = try await web.evaluateJavaScript("""
            const rect=document.querySelector('.row').getBoundingClientRect();
            ({x:rect.x+2,y:rect.y+2})
            """) as! [String: Double]
        let hoverPoint = web.convert(NSPoint(x: rowPoint["x"]!,
            y: web.isFlipped ? rowPoint["y"]! : web.bounds.height-rowPoint["y"]!), to: nil)
        let root = window.contentView!
        let hit = root.hitTest(root.superview?.convert(hoverPoint, from: nil) ?? hoverPoint)
        print("Download pointer: web=\(web.frame), attached=\(web.window === window), key=\(window.isKeyWindow), target=\(String(describing: hit))")
        _ = try await web.evaluateJavaScript("""
            window.pointerEvents=[];
            for(const type of ['mousedown','mouseup','mousemove'])
              document.addEventListener(type,e=>pointerEvents.push([type,e.clientX,e.clientY,e.target.className]));
            """)
        // Synthetic mouseMoved does not reach WebKit's DOM; clicking the row padding
        // exercises AppKit hit testing and establishes the pointer without opening a file.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(NSEvent.mouseEvent(with: type,
                location: hoverPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let visible = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.actions')).opacity") as? String
        guard visible == "1" else {
            let trace = try await web.evaluateJavaScript("JSON.stringify({pointerEvents,hover:[...document.querySelectorAll(':hover')].map(e=>e.className)})")
            throw PerchError("Native row click did not reveal HTML row actions: \(String(describing: trace))")
        }
        let missingDisabled = try await web.evaluateJavaScript("document.querySelectorAll('.file')[1].disabled") as? Bool
        guard missingDisabled == true else { throw PerchError("Missing file can still be opened from HTML") }
        if let root = window.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let preview = FileManager.default.temporaryDirectory.appendingPathComponent("perch-downloads-preview.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to:
                preview)
            print("Download UI preview: \(preview.path)")
        }
        try await clickHTML(".row button[data-action='remove']")
        guard store.downloads.records.count == 1 && store.downloads.records[0].id == missing.id && record.available else {
            throw PerchError("Hovered delete button did not remove only its record")
        }
        try await clickHTML("#clear")
        precondition(store.downloads.records.isEmpty && record.available)
        print("PASS: native toolbar/popover and HTML records page pointer/delete/clear event paths; missing file disabled and downloaded file preserved")
    }
}
