import AppKit
import SwiftUI

private final class UpdateFixtureProtocol: URLProtocol {
    static var status = 200
    static var remaining: String?
    static var body = Data(#"{"tag_name":"v0.2.10","draft":false,"prerelease":false}"#.utf8)
    static var fallbackStatus = 200
    static var responseURL = UpdateCheck.repositoryURL.appendingPathComponent("releases/tag/v0.2.10")
    static var failure: Error?
    static var requests = 0
    static var urls: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.urls.append(request.url!)
        let api = request.url == UpdateCheck.apiURL
        precondition(api || request.url == UpdateCheck.releaseURL)
        precondition(request.httpMethod == (api ? "GET" : "HEAD"))
        if api {
            precondition(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        }
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let headers = api ? Self.remaining.map { ["X-RateLimit-Remaining": $0] } : nil
        let response = HTTPURLResponse(url: api ? request.url! : Self.responseURL,
                                       statusCode: api ? Self.status : Self.fallbackStatus,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if api { client?.urlProtocol(self, didLoad: Self.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum UpdateSelfCheck {
    private static func releaseData(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease])
    }

    private static func release(_ tag: String) -> URL {
        UpdateCheck.repositoryURL.appendingPathComponent("releases/tag").appendingPathComponent(tag)
    }

    @MainActor static func run() async throws {
        for (current, remote, expected) in [
            ("0.2.9", "v0.2.10", "0.2.10"),
            ("0.2.5", "v0.3.0", "0.3.0"),
            ("0.9.9", "v1.0.0", "1.0.0"),
            ("0.2.5", "v0.2.5", nil),
            ("0.3.0", "v0.2.10", nil)
        ] as [(String, String, String?)] {
            let actual = try UpdateCheck.newerVersion(at: release(remote), than: current)
            precondition(actual == expected, "Unexpected version comparison: \(current), \(remote)")
            let api = try UpdateCheck.newerVersion(in: releaseData(remote), than: current)
            precondition(api == expected)
        }
        for data in [releaseData("v1.0.0", draft: true), releaseData("v1.0.0", prerelease: true)] {
            let actual = try UpdateCheck.newerVersion(in: data, than: "0.2.5")
            precondition(actual == nil)
        }
        for url in [
            release("v01.0.0"), release("v1.0.0-beta"), release("v1..0"),
            release("v999999999999999999999999999.0.0"),
            UpdateCheck.releaseURL,
            URL(string: "https://github.com/login")!,
            URL(string: "https://github.com/Other/Perch/releases/tag/v1.0.0")!,
            URL(string: "https://example.com/ShawnKung/Perch/releases/tag/v1.0.0")!,
            URL(string: "http://github.com/ShawnKung/Perch/releases/tag/v1.0.0")!
        ] {
            do {
                _ = try UpdateCheck.newerVersion(at: url, than: "0.2.5")
                preconditionFailure("An invalid release URL must not report an up-to-date version")
            } catch is PerchError {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        UpdateFixtureProtocol.body = releaseData("v0.2.10")
        let beforeAPI = UpdateFixtureProtocol.requests
        let latest = try await UpdateCheck.latestVersion(current: "0.2.9", session: session)
        precondition(latest == "0.2.10" && UpdateFixtureProtocol.requests == beforeAPI + 1 &&
                     UpdateFixtureProtocol.urls.last == UpdateCheck.apiURL)
        for status in [404, 403, 429, 500] {
            UpdateFixtureProtocol.status = status
            let before = UpdateFixtureProtocol.requests
            do {
                _ = try await UpdateCheck.latestVersion(current: "0.2.9", session: session)
                preconditionFailure("HTTP failure must not report an up-to-date version")
            } catch is PerchError {}
            precondition(UpdateFixtureProtocol.requests == before + 1, "Other HTTP errors must not fall back")
        }
        UpdateFixtureProtocol.status = 200
        UpdateFixtureProtocol.body = Data("{}".utf8)
        let beforeInvalid = UpdateFixtureProtocol.requests
        do {
            _ = try await UpdateCheck.latestVersion(current: "0.2.9", session: session)
            preconditionFailure("Invalid API data must fail")
        } catch is DecodingError {}
        precondition(UpdateFixtureProtocol.requests == beforeInvalid + 1)
        UpdateFixtureProtocol.body = releaseData("v0.2.10")
        UpdateFixtureProtocol.status = 403
        UpdateFixtureProtocol.remaining = "1"
        let beforeForbidden = UpdateFixtureProtocol.requests
        do {
            _ = try await UpdateCheck.latestVersion(current: "0.2.9", session: session)
            preconditionFailure("A non-exhausted 403 must fail")
        } catch is PerchError {}
        precondition(UpdateFixtureProtocol.requests == beforeForbidden + 1)
        UpdateFixtureProtocol.remaining = "0"
        let beforeFallback = UpdateFixtureProtocol.requests
        let fallback = try await UpdateCheck.latestVersion(current: "0.2.9", session: session)
        precondition(fallback == "0.2.10" && UpdateFixtureProtocol.requests == beforeFallback + 2 &&
                     Array(UpdateFixtureProtocol.urls.suffix(2)) == [UpdateCheck.apiURL, UpdateCheck.releaseURL])
        for status in [403, 500] {
            UpdateFixtureProtocol.fallbackStatus = status
            do {
                _ = try await UpdateCheck.latestVersion(current: "0.2.9", session: session)
                preconditionFailure("A failed fallback must not report a current version")
            } catch is PerchError {}
        }
        UpdateFixtureProtocol.fallbackStatus = 200
        UpdateFixtureProtocol.responseURL = UpdateCheck.releaseURL
        do {
            _ = try await UpdateCheck.latestVersion(current: "0.2.9", session: session)
            preconditionFailure("A missing version redirect must fail")
        } catch is PerchError {}
        UpdateFixtureProtocol.responseURL = release("v0.2.10")
        UpdateFixtureProtocol.status = 200
        UpdateFixtureProtocol.remaining = nil
        do {
            _ = try await UpdateCheck.latestVersion(current: "invalid", session: session)
            preconditionFailure("An invalid installed version must fail")
        } catch is PerchError {}
        UpdateFixtureProtocol.failure = URLError(.notConnectedToInternet)
        let beforeOffline = UpdateFixtureProtocol.requests
        do {
            _ = try await UpdateCheck.latestVersion(current: "0.2.9", session: session)
            preconditionFailure("Offline check must fail")
        } catch is URLError {}
        precondition(UpdateFixtureProtocol.requests == beforeOffline + 1, "Offline errors must not fall back")
        let suite = "dev.perch.update-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        store.receiveUpdate("0.2.10")
        precondition(store.availableUpdate == "0.2.10")
        store.receiveUpdate(nil)
        precondition(store.availableUpdate == nil)
        store.receiveUpdate("0.3.0")
        precondition(store.availableUpdate == "0.3.0")
        print("PASS: API-first checks, exhausted-403 HEAD fallback only, stable releases, trusted redirects and failure boundaries")
        print("PASS: detected versions control the passive update indicator")
        UpdateFixtureProtocol.failure = nil
        UpdateFixtureProtocol.body = releaseData("v0.2.9")
        let before = UpdateFixtureProtocol.requests
        store.checkForUpdates(manual: true, current: "0.2.9", session: session)
        precondition(store.checkingUpdate && store.updateCheckMessage == nil)
        store.checkForUpdates(manual: true, current: "0.2.9", session: session)
        try await AISelfCheck.wait { !store.checkingUpdate }
        precondition(UpdateFixtureProtocol.requests == before + 1 &&
                     store.availableUpdate == nil && store.updateCheckMessage == "当前已是最新版本")
        UpdateFixtureProtocol.status = 429
        store.checkForUpdates(manual: true, current: "0.2.9", session: session)
        try await AISelfCheck.wait { !store.checkingUpdate }
        precondition(store.updateCheckMessage?.contains("429") == true)
        store.checkForUpdates(current: "0.2.9", session: session)
        try await AISelfCheck.wait { !store.checkingUpdate }
        precondition(store.updateCheckMessage == nil, "Automatic check failures must stay silent")
        UpdateFixtureProtocol.status = 200
        UpdateFixtureProtocol.body = releaseData("v0.2.10")
        store.checkForUpdates(manual: true, current: "0.2.9", session: session)
        try await AISelfCheck.wait { !store.checkingUpdate }
        precondition(store.availableUpdate == "0.2.10" && store.updateCheckMessage == nil)
        UpdateFixtureProtocol.failure = URLError(.notConnectedToInternet)
        store.checkForUpdates(manual: true, current: "0.2.9", session: session)
        try await AISelfCheck.wait { !store.checkingUpdate }
        precondition(store.updateCheckMessage != nil && store.availableUpdate == "0.2.10",
                     "A failed recheck must preserve an already detected update")
        store.checkForUpdates(manual: true, current: "0.2.9", session: session)
        store.cancelUpdateCheck()
        precondition(!store.checkingUpdate)
        UpdateFixtureProtocol.failure = nil
        store.checkForUpdates(manual: true, current: "0.2.9", session: session)
        try await AISelfCheck.wait { !store.checkingUpdate }
        precondition(store.availableUpdate == "0.2.10" && store.updateCheckMessage == nil)
        print("PASS: shared automatic/manual checks, duplicate prevention, current version feedback, HTTP/offline errors, cancellation and retry")
    }

    @MainActor static func ui() async {
        func precondition(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
            if !condition() { fputs("FAIL: update sidebar line \(line): \(message)\n", stderr); exit(1) }
        }
        let suite = "dev.perch.update-ui-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        store.tabs = (0..<30).map { Tab(title: "合成标签 \($0)", address: "") }
        store.selected = store.tabs[0].id
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 850, height: 660),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = RootHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        SelfTests.prepareAccessibility()
        func settle() async {
            try? await Task.sleep(nanoseconds: 250_000_000)
            root.layoutSubtreeIfNeeded()
        }
        func find(_ label: String, in node: NSObject) -> NSObject? {
            if node.responds(to: NSSelectorFromString("accessibilityLabel")),
               node.value(forKey: "accessibilityLabel") as? String == label { return node }
            var children: [NSObject] = (node as? NSView)?.subviews ?? []
            if node.responds(to: NSSelectorFromString("accessibilityChildren")),
               let accessible = node.value(forKey: "accessibilityChildren") as? [NSObject] { children += accessible }
            return children.lazy.compactMap { find(label, in: $0) }.first
        }
        func tabList(in view: NSView) -> TabListContainer? {
            if let list = view as? TabListContainer { return list }
            return view.subviews.lazy.compactMap { tabList(in: $0) }.first
        }
        await settle()
        precondition(find("更新 Perch", in: root) == nil, "No update indicator is shown before detection")
        store.receiveUpdate("0.2.10")
        await settle()
        precondition(window.attachedSheet == nil && NSApp.modalWindow == nil,
                     "Detecting an update must not open a dialog")
        let expanded = snapshot(root, rect: NSRect(x: 0, y: 0, width: 199, height: root.bounds.height))
        defaults.set(true, forKey: "sidebarHidden")
        await settle()
        let compact = snapshot(root, rect: NSRect(x: 0, y: 0, width: 48, height: root.bounds.height))
        for collapsed in [true, false] {
            defaults.set(collapsed, forKey: "sidebarHidden")
            await settle()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<60 where !NSApp.isActive || !window.isKeyWindow {
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            precondition(NSApp.isActive && window.isKeyWindow,
                         "Update clicks require an active isolated window")
            let button = find("更新 Perch", in: root)!
            let nativeButton = button as! NSButton
            precondition(nativeButton.toolTip == "检测到新 0.2.10 版，点击更新" &&
                         nativeButton.title == (collapsed ? "" : "发现新版本"),
                         "The update indicator must show the correct label and version tooltip")
            let frame = (button.value(forKey: "accessibilityFrame") as! NSValue).rectValue
            let settings = find("设置", in: root)!
            let settingsFrame = (settings.value(forKey: "accessibilityFrame") as! NSValue).rectValue
            precondition(frame.minY > settingsFrame.maxY, "Update must appear above Settings")
            precondition(frame.width > (collapsed ? 20 : 100) && frame.height >= 32,
                         "The entire update row must be clickable")
            let list = tabList(in: root)!
            let table = list.scroll.documentView as! TabTable
            let listFrame = list.convert(list.bounds, to: nil)
            let newTab = find("新建标签页", in: root)!
            let newTabFrame = window.convertFromScreen((newTab.value(forKey: "accessibilityFrame") as! NSValue).rectValue)
            precondition(list.layer?.masksToBounds == true && listFrame.minY >= newTabFrame.maxY,
                         "Tabs must be clipped above the bottom actions")
            precondition(list.layer?.mask is CAGradientLayer,
                         "An overflowing tab list must fade above the bottom actions")
            let scrollPoint = list.convert(NSPoint(x: list.bounds.midX,
                                                  y: list.bounds.height - TabListContainer.bottomFadeHeight / 2), to: nil)
            let scrollHit = root.hitTest(root.superview!.convert(scrollPoint, from: nil))!
            precondition(scrollHit === list.scroll || scrollHit.isDescendant(of: list.scroll),
                         "The gradient must not intercept tab-list scrolling")
            let before = list.scroll.contentView.bounds.minY
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                wheel1: -180, wheel2: 0, wheel3: 0)!
            wheel.location = CGPoint(x: scrollPoint.x, y: NSScreen.screens[0].frame.height - scrollPoint.y)
            scrollHit.scrollWheel(with: NSEvent(cgEvent: wheel)!)
            await settle()
            precondition(list.scroll.contentView.bounds.minY > before,
                         "Native wheel events must scroll through the fade")
            table.scrollRowToVisible(table.numberOfRows - 1)
            await settle()
            let lastRow = table.rect(ofRow: table.numberOfRows - 1)
            try? await AISelfCheck.wait(timeout: 2) {
                list.layer?.mask == nil && table.visibleRect.minY <= lastRow.minY && table.visibleRect.maxY >= lastRow.maxY
            }
            precondition(list.layer?.mask == nil && table.visibleRect.minY <= lastRow.minY && table.visibleRect.maxY >= lastRow.maxY,
                         "The last tab must remain fully readable without a bottom fade: visible=\(table.visibleRect), last=\(table.rect(ofRow: table.numberOfRows - 1)), viewport=\(list.scroll.contentView.bounds), mask=\(String(describing: list.layer?.mask))")
            table.scrollRowToVisible(0)
            await settle()
            // Hit-test the expanded row's trailing whitespace as well as the compact icon.
            let buttonRect = nativeButton.convert(nativeButton.bounds, to: nil)
            let point = NSPoint(x: collapsed ? buttonRect.midX : buttonRect.maxX - 4, y: buttonRect.midY)
            let hit = root.hitTest(root.superview!.convert(point, from: nil))
            precondition(hit === nativeButton,
                         "The full update row must hit the native button: point=\(point), button=\(buttonRect), hit=\(String(describing: hit))")
            precondition(nativeButton.isEnabled && nativeButton.target != nil && nativeButton.action != nil,
                         "The update button must retain its enabled target/action")
            let coordinator = nativeButton.target as! UpdateIndicator.Coordinator
            var opened: [URL] = []
            coordinator.indicator.openRelease = { opened.append($0); return true }
            _ = nativeButton.accessibilityPerformPress()
            await settle()
            precondition(opened == [UpdateCheck.releaseURL] && store.availableUpdate == "0.2.10" &&
                         window.attachedSheet == nil && NSApp.modalWindow == nil,
                         "Pressing the update indicator must directly open the latest release without a dialog")
            coordinator.indicator.openRelease = { _ in false }
            _ = nativeButton.accessibilityPerformPress()
            await settle()
            precondition(nativeButton.toolTip?.contains("无法打开更新页面") == true &&
                         window.attachedSheet == nil && NSApp.modalWindow == nil,
                         "Browser launch failure must stay in the indicator tooltip without a dialog")
        }
        preview(expanded: expanded, compact: compact)
        print("PASS: clipped long tab list, bottom gradient, native wheel routing and fully visible last tab in both sidebar widths")
        print("PASS: passive sidebar indicator, expanded/compact labels, full-row hits and native accessibility press directly route to latest release without dialogs")
    }

    @MainActor static func aboutUI() async {
        let suite = "dev.perch.about-ui-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        UpdateFixtureProtocol.status = 200
        UpdateFixtureProtocol.remaining = nil
        UpdateFixtureProtocol.failure = nil
        UpdateFixtureProtocol.body = releaseData("v0.2.9")
        let panel = Panel(contentRect: NSRect(x: 150, y: 150, width: 990, height: 650),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        store.openSettings(.about)
        let web = store.browser!.webView
        panel.contentView = RootHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        panel.bindTabFocus(to: store)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        do {
            try await AISelfCheck.wait { web.url == SettingsRoute.about.url && !web.isLoading }
            try await AIChatPageSelfCheck.waitFor(web, "document.body.innerText.includes('开源仓库')")
            store.checkForUpdates(manual: true, current: "0.2.9", session: session)
            try await AIChatPageSelfCheck.waitFor(web, "document.body.innerText.includes('当前已是最新版本')")
            UpdateFixtureProtocol.status = 403
            store.checkForUpdates(manual: true, current: "0.2.9", session: session)
            try await AIChatPageSelfCheck.waitFor(web, "document.body.innerText.includes('403')")
            UpdateFixtureProtocol.status = 200
            UpdateFixtureProtocol.body = releaseData("v0.2.10")
            store.checkForUpdates(manual: true, current: "0.2.9", session: session)
            try await AIChatPageSelfCheck.waitFor(web, """
                document.querySelector('#check-update')?.hidden &&
                    !document.querySelector('#view-release')?.hidden &&
                    document.body.innerText.includes('0.2.10')
                """)
            print("PASS: HTML About shows current, error and update states inline")
} catch { fputs("FAIL: HTML About: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor private static func snapshot(_ view: NSView, rect: NSRect) -> NSImage {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: rect)!
        view.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }

    @MainActor private static func preview(expanded: NSImage, compact: NSImage) {
        guard let index = CommandLine.arguments.firstIndex(of: "--update-preview"),
              CommandLine.arguments.count > index + 1 else { return }
        let image = NSImage(size: NSSize(width: 300, height: 530))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
        for (text, x) in [("展开侧栏", 24.0), ("收起侧栏", 205.0)] {
            (text as NSString).draw(at: NSPoint(x: x, y: 495), withAttributes: attributes)
        }
        expanded.draw(in: NSRect(x: 24, y: 20, width: expanded.size.width * 0.7, height: expanded.size.height * 0.7))
        compact.draw(in: NSRect(x: 205, y: 20, width: compact.size.width * 0.7, height: compact.size.height * 0.7))
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        do { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
        catch { preconditionFailure("Cannot save update preview: \(error)") }
    }
}
