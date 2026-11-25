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
        print("PASS: typed downloads URL reaches the native tab title")
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
        guard let root = window.contentView, let fileButton = element(record.filename, in: root),
              let fileFrame = (fileButton.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
            throw PerchError("Full records page did not expose its file row")
        }
        let hoverPoint = window.convertPoint(fromScreen: NSPoint(x: fileFrame.midX, y: fileFrame.midY))
        NSApp.postEvent(NSEvent.mouseEvent(with: .mouseMoved, location: hoverPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!, atStart: false)
        try await AISelfCheck.wait { window.contentView.flatMap { element("删除下载记录", in: $0) } != nil }
        if let root = window.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let preview = FileManager.default.temporaryDirectory.appendingPathComponent("perch-downloads-preview.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to:
                preview)
            print("Download UI preview: \(preview.path)")
        }
        try await click("删除下载记录", in: window)
        guard store.downloads.records.count == 1 && store.downloads.records[0].id == missing.id && record.available else {
            throw PerchError("Hovered delete button did not remove only its record")
        }
        try await click("全部清空", in: window)
        precondition(store.downloads.records.isEmpty && record.available)
        print("PASS: isolated native toolbar, recent popover, full records tab, hover/delete and clear-all mouse event paths; downloaded file preserved")
    }
}
