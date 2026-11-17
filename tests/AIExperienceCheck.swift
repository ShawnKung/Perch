import AppKit
import SwiftUI
import WebKit

private struct AIStreamingProbe: View {
    @ObservedObject var ai: AIController
    let tab: UUID
    var body: some View { AIMarkdownView(text: ai.sessions[tab]?.messages.last?.text ?? "") }
}

extension AISelfCheck {
    static func typographyUI() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let originalSize = PerchTheme.shared.chatFontSize
        let originalTheme = PerchTheme.shared.selection
        let suite = "dev.perch.typography.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perch-typography-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            PerchTheme.shared.chatFontSize = originalSize
            PerchTheme.shared.selection = originalTheme
        }
        var user = AIMessage(role: "user", text: "检查字体与高亮：中文 English 🙂，调整字号时，文字应在气泡内换行。")
        user.references = [AIPageReference(title: "中文 English 参考网页", url: URL(string: "https://example.invalid"))]
        let markdown = """
        ## 字体与布局
        中文 English 🙂，内联 `highlighted_code` 与 **粗体文字**。

        > 引用内容应在高亮背景内换行，不越过窗口边缘。

        ```swift
        let longLine = "ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZ"
        ```

        | 名称 | 内容 |
        | --- | --- |
        | 中文 | English 🙂 |
        | 地址 | https://example.invalid/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz |
        """
        var answer = AIMessage(role: "assistant", text: markdown)
        answer.reasoning = "思考内容：字号变化后重新换行，并保留原生文字选择。\nEnglish reasoning 🙂."
        answer.followups = ["继续查看较大字号下的文字换行与按钮边界"]
        let session = AISession(messages: [user, answer])
        var records = [session.id: session]
        for index in 0..<12 {
            var message = AIMessage(role: "user", text: "网页历史 \(index) · 中文 English 长标题换行检查")
            message.references = [AIPageReference(title: "中文 English 参考网页", url: URL(string: "https://example.invalid"))]
            let record = AISession(updated: Date().addingTimeInterval(Double(-index - 1)), messages: [message], origin: .web)
            records[record.id] = record
        }
        try JSONEncoder().encode(AIConversationArchive(conversations: records, tabs: [AIController.homeID: session.id]))
            .write(to: directory.appendingPathComponent("conversations.json"))
        let store = Store(defaults: defaults)
        let ai = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(ai.save(AIConfiguration(provider: .custom, baseURL: "http://127.0.0.1:1", model: "fixture"), key: "synthetic-key"))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 850, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        defer { window.orderOut(nil); window.contentView = nil }
        func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
        }
        func element(_ node: Any, _ label: String) -> NSObject? {
            guard let node = node as? NSObject else { return nil }
            for key in ["accessibilityLabel", "accessibilityTitle"] where node.responds(to: NSSelectorFromString(key)) {
                if node.value(forKey: key) as? String == label {
                    if label != "Chat 正文字号" ||
                        (node.responds(to: NSSelectorFromString("accessibilityRole")) &&
                         node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.slider.rawValue) {
                        return node
                    }
                }
            }
            guard node.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            return (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).lazy.compactMap { element($0, label) }.first
        }
        func frame(_ host: NSView, _ label: String) throws -> NSRect {
            guard let value = element(host, label)?.value(forKey: "accessibilityFrame") as? NSValue else {
                throw PerchError("Missing typography control: \(label)")
            }
            return value.rectValue
        }
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            }
        }
        func snapshot(_ host: NSView, _ name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"],
                  let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
        }
        let settingsHost = NSHostingView(rootView: SettingsPage(store: store).defaultAppStorage(defaults))
        window.contentView = settingsHost; window.makeKeyAndOrderFront(nil)
        try await wait { element(settingsHost, "Chat 正文字号") != nil }
        try snapshot(settingsHost, "settings-font-default")
        let slider = try frame(settingsHost, "Chat 正文字号")
        click(NSPoint(x: slider.maxX - 8, y: slider.midY))
        try await wait { store.settings.chatFontSize > 13 }
        try await Task.sleep(nanoseconds: 150_000_000)
        let saved = try JSONDecoder().decode(BrowserSettings.self, from: defaults.data(forKey: "settings")!)
        precondition(saved.chatFontSize == store.settings.chatFontSize)
        try snapshot(settingsHost, "settings-font-size")
        let reset = try frame(settingsHost, "恢复默认")
        click(NSPoint(x: reset.midX, y: reset.midY))
        try await wait { store.settings.chatFontSize == 13 && PerchTheme.shared.chatFontSize == 13 }
        let legacy = try JSONDecoder().decode(BrowserSettings.self, from: Data("{}".utf8))
        precondition(legacy.chatFontSize == 13)
        for invalid in [0, 23] {
            precondition((try? JSONDecoder().decode(BrowserSettings.self, from: Data("{\"chatFontSize\":\(invalid)}".utf8))) == nil)
        }
        print("PASS: native slider click persists Chat font size, reset restores 13 pt, legacy and invalid settings are handled")
        for fullPage in [true, false] {
            let host = NSHostingView(rootView: AIChatSidebar(store: store, ai: ai, fullPage: fullPage, owner: AIController.homeID, close: {}).defaultAppStorage(defaults))
            window.contentView = host
            window.setContentSize(NSSize(width: fullPage ? 850 : 360, height: 720))
            ai.drafts[AIController.homeID] = "输入草稿 English 中文 🙂\n字号变化后保留选区。"
            window.makeKeyAndOrderFront(nil)
            try await wait { !views(host, of: AIMarkdownWebView.self).isEmpty && !views(host, of: AIComposerTextView.self).isEmpty }
            let web = views(host, of: AIMarkdownWebView.self)[0]
            let editor = views(host, of: AIComposerTextView.self)[0]
            try await wait { (web.navigationDelegate as? AIMarkdownView.Coordinator)?.loaded == true }
            try await wait { element(host, "正在加载对话") == nil }
            _ = try await web.evaluateJavaScript("""
            window.typographyNode = document.querySelector('#content p');
            const r = document.createRange(); r.selectNodeContents(typographyNode);
            window.getSelection().removeAllRanges(); window.getSelection().addRange(r);
            window.typographySelection = window.getSelection().toString();
            """)
            editor.setSelectedRange(NSRange(location: 2, length: 4))
            var heights: [Double] = []
            for size in [11.0, 13.0, 22.0, 13.0] {
                var settings = store.settings; settings.chatFontSize = size
                try store.saveSettings(settings)
                try await wait { editor.font?.pointSize == CGFloat(size) }
                try await Task.sleep(nanoseconds: 200_000_000)
                host.layoutSubtreeIfNeeded()
                if let table = views(host, of: AIHistoryTable.self).first {
                    let selectedIDs = table.selectedRowIndexes.compactMap { table.conversationIDs[$0] }
                    precondition(selectedIDs == [session.id], "Font changes must preserve the active history row")
                    table.layoutSubtreeIfNeeded()
                    for row in 0..<table.numberOfRows {
                        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? AIHistoryCell else { continue }
                        cell.layoutSubtreeIfNeeded()
                        let fields = views(cell, of: NSTextField.self)
                        for field in fields {
                            let baseline = field.stringValue.hasPrefix("@ ") ? 9.5 : 13.0
                            precondition(abs((field.font?.pointSize ?? 0) - CGFloat(size * baseline / 13)) < 0.01)
                            precondition(field.frame.minY >= 0 && field.frame.maxY <= cell.bounds.height,
                                         "History text must fit inside its row highlight")
                        }
                        if fields.contains(where: { $0.stringValue.hasPrefix("@ ") }) {
                            let textRect = fields.reduce(NSRect.null) { $0.union($1.frame) }
                            precondition(abs(textRect.midY - cell.bounds.midY) < 0.5,
                                         "History title and source must be vertically centered together")
                        }
                    }
                }
                let metrics = try await web.callAsyncJavaScript("""
                const content = document.getElementById('content');
                return {size:parseFloat(getComputedStyle(document.body).fontSize),
                  height:content.getBoundingClientRect().height,
                  bounded:content.scrollWidth <= window.innerWidth + 1,
                  preserved:typographyNode === document.querySelector('#content p') &&
                    window.getSelection().toString() === typographySelection,
                  code:parseFloat(getComputedStyle(content.querySelector('code')).fontSize),
                  button:parseFloat(getComputedStyle(content.querySelector('pre button')).fontSize),
                  toolbarBounded:[...content.querySelectorAll('pre button')].every(b => {
                    const p=b.closest('pre').getBoundingClientRect(), r=b.getBoundingClientRect();
                    return r.top >= p.top && r.bottom <= p.bottom && r.right <= p.right &&
                      r.left >= p.left &&
                      [...b.closest('pre').querySelectorAll('button')].every(other => {
                        if (b === other) return true;
                        const q = other.getBoundingClientRect();
                        return r.right <= q.left || q.right <= r.left || r.bottom <= q.top || q.bottom <= r.top;
                      });
                  })};
                """, arguments: [:], in: nil, contentWorld: .page) as! [String: Any]
                guard abs((metrics["size"] as! Double) - size) < 0.01,
                      abs((metrics["code"] as! Double) - size * 12 / 13) < 0.01,
                      abs((metrics["button"] as! Double) - size * 11 / 13) < 0.01,
                      metrics["toolbarBounded"] as? Bool == true,
                      metrics["bounded"] as? Bool == true, metrics["preserved"] as? Bool == true else {
                    throw PerchError("Chat typography layout failed: fullPage=\(fullPage), \(metrics)")
                }
                heights.append(metrics["height"] as! Double)
                precondition(editor.selectedRange() == NSRange(location: 2, length: 4) && editor.string == ai.drafts[AIController.homeID])
                let send = try frame(host, "发送")
                let input = try frame(host, "向 AI 提问，输入 @ 引用标签页")
                precondition(!input.intersects(send) && send.width >= 33 && send.height >= 33)
                let contentFrame = window.convertToScreen(window.contentView!.bounds)
                precondition(contentFrame.insetBy(dx: -1, dy: -1).contains(send))
                try snapshot(host, "\(fullPage ? "full" : "sidebar")-font-\(Int(size))")
            }
            precondition(heights[2] > heights[1] && heights[1] > heights[0] && abs(heights[3] - heights[1]) < 1)
            _ = ai.editMessage(user.id, tab: AIController.homeID)
            var settings = store.settings; settings.chatFontSize = 22; try store.saveSettings(settings)
            try await Task.sleep(nanoseconds: 200_000_000)
            try snapshot(host, "\(fullPage ? "full" : "sidebar")-font-22-edit")
            ai.cancelEditing(AIController.homeID)
            print("PASS: \(fullPage ? "full Chat" : "360 pt sidebar") proportional text/history sizing, 11/13/22 pt reflow, centered history sources, Markdown/control bounds and DOM/selection/draft preservation")
        }
        let reasoningHost = NSHostingView(rootView: AIReasoningText(text: answer.reasoning!, active: false).frame(height: 150))
        window.contentView = reasoningHost; window.setContentSize(NSSize(width: 320, height: 150))
        try await wait { !views(reasoningHost, of: AIReasoningScrollView.self).isEmpty }
        let reasoning = views(reasoningHost, of: AIReasoningScrollView.self)[0]
        reasoning.editor.setSelectedRange(NSRange(location: 0, length: 4))
        PerchTheme.shared.chatFontSize = 11
        try await wait { abs((reasoning.editor.font?.pointSize ?? 0) - 11 * 12 / 13) < 0.01 }
        let smallHeight = reasoning.textHeight(width: 320)
        PerchTheme.shared.chatFontSize = 22
        try await wait { abs((reasoning.editor.font?.pointSize ?? 0) - 22 * 12 / 13) < 0.01 }
        precondition(reasoning.textHeight(width: 320) > smallHeight && reasoning.editor.selectedRange().length == 4)
        try snapshot(reasoningHost, "reasoning-font-22")
        print("PASS: reasoning text reflows with font size and preserves its native selection")
    }

    static func streamingChecks(baseURL: String) async throws {
        let suite = "dev.perch.streaming.selftest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perch-streaming-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let ai = AIController(defaults: defaults, conversationDirectory: directory)
        for api in AIProtocol.allCases {
            var config = AIConfiguration(provider: .custom, baseURL: baseURL + "/streaming", model: "fixture")
            config.apiProtocol = api
            precondition(ai.save(config, key: "synthetic-key"))
            let tab = UUID()
            let host = NSHostingView(rootView: AIStreamingProbe(ai: ai, tab: tab))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            func renderer(_ view: NSView) -> WKWebView? {
                (view as? WKWebView) ?? view.subviews.lazy.compactMap { renderer($0) }.first
            }
            try await wait { renderer(host) != nil }
            let web = renderer(host)!
            precondition(ai.send("Streaming fixture", tab: tab, browser: nil, usePage: false))
            let sent = ai.sessions[tab]!.messages[0].timestamp
            precondition(sent != nil && ai.sessions[tab]?.messages.last?.timestamp == nil)
            for prefix in ["第一段", "第一段\n\n第二段", "第一段\n\n第二段\n\n第三段"] {
                try await wait { ai.sessions[tab]?.messages.last?.text == prefix }
                let expected = prefix.components(separatedBy: .whitespacesAndNewlines).joined()
                var rendered = ""
                let deadline = Date().addingTimeInterval(1)
                while rendered != expected && Date() < deadline {
                    rendered = (try? await web.evaluateJavaScript("document.getElementById('content').textContent.replace(/\\s/g,'')")) as? String ?? ""
                    if rendered != expected { try await Task.sleep(nanoseconds: 20_000_000) }
                }
                guard rendered == expected else { throw PerchError("Markdown did not render the streaming prefix: \(api.rawValue), \(rendered)") }
                guard ai.sessions[tab]?.requestID != nil else { throw PerchError("Text only appeared after stream completion: \(api.rawValue)") }
            }
            try await wait { ai.sessions[tab]?.requestID == nil }
            precondition(ai.sessions[tab]?.error == nil)
            let reply = ai.sessions[tab]!.messages.last!
            precondition(reply.timestamp != nil && reply.timestamp! >= sent!)
            let saved = try JSONEncoder().encode(reply)
            let decoded = try JSONDecoder().decode(AIMessage.self, from: saved)
            precondition(decoded.timestamp == reply.timestamp)
            var legacy = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
            legacy.removeValue(forKey: "timestamp")
            let legacyData = try JSONSerialization.data(withJSONObject: legacy)
            let oldMessage = try JSONDecoder().decode(AIMessage.self, from: legacyData)
            precondition(oldMessage.timestamp == nil)
            print("PASS: \(api.rawValue) publishes and renders every text prefix before stream completion")
        }
        let store = Store(defaults: defaults)
        for api in AIProtocol.allCases {
            for fullPage in [true, false] {
                var config = AIConfiguration(provider: .custom, baseURL: baseURL + "/streaming", model: "fixture")
                config.apiProtocol = api
                precondition(ai.save(config, key: "synthetic-key"))
                let tab = UUID()
                let host = NSHostingView(rootView: AIChatSidebar(store: store, ai: ai, fullPage: fullPage, owner: tab, close: {})
                    .defaultAppStorage(defaults))
                let window = NSWindow(contentRect: NSRect(x: 120, y: 160, width: fullPage ? 850 : 360, height: 650),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host; window.orderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil }
                func renderer(_ view: NSView) -> WKWebView? {
                    (view as? WKWebView) ?? view.subviews.lazy.compactMap { renderer($0) }.first
                }
                precondition(ai.send("Thinking streaming fixture", tab: tab, browser: nil, usePage: false))
                try await wait { ai.sessions[tab]?.messages.last?.reasoning?.count ?? 0 > 1000 }
                guard renderer(host) == nil else { throw PerchError("Body renderer was created before the first text delta") }
                for prefix in ["第一段", "第一段\n\n第二段", "第一段\n\n第二段\n\n第三段"] {
                    try await wait { ai.sessions[tab]?.messages.last?.text == prefix }
                    let expected = prefix.components(separatedBy: .whitespacesAndNewlines).joined()
                    let deadline = Date().addingTimeInterval(2)
                    var rendered = ""
                    while rendered != expected && Date() < deadline {
                        if let web = renderer(host) {
                            rendered = (try? await web.evaluateJavaScript("document.getElementById('content').textContent.replace(/\\s/g,'')")) as? String ?? ""
                        }
                        if rendered != expected { try await Task.sleep(nanoseconds: 20_000_000) }
                    }
                    guard rendered == expected, ai.sessions[tab]?.requestID != nil else {
                        throw PerchError("Chat body failed to stream after thinking: \(api.rawValue), fullPage=\(fullPage), rendered=\(rendered)")
                    }
                }
                try await wait { ai.sessions[tab]?.requestID == nil }
                precondition(ai.sessions[tab]?.error == nil)
            }
        }
        print("PASS: full Chat and sidebar render each body prefix after long thinking, before completion")
        let config = AIConfiguration(provider: .custom, baseURL: baseURL + "/streaming", model: "fixture")
        precondition(store.ai.save(config, key: "synthetic-key"))
        store.openChat(owner: AIController.homeID)
        for _ in 0..<23 {
            precondition(store.ai.send("History streaming fixture", tab: AIController.homeID, browser: nil, usePage: false))
            try await wait { store.ai.sessions[AIController.homeID]?.requestID == nil }
        }
        let host = NSHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 1000, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let live = store.ai
        precondition(live.send("Burst streaming fixture", tab: AIController.homeID, browser: nil, usePage: false))
        var lengths: [Int] = []
        let deadline = Date().addingTimeInterval(12)
        func answer(_ view: NSView) -> WKWebView? {
            if let web = view as? AIMarkdownWebView,
               (web.navigationDelegate as? AIMarkdownView.Coordinator)?.text.hasPrefix("正文增量片段") == true { return web }
            return view.subviews.lazy.compactMap { answer($0) }.first
        }
        while Date() < deadline, live.sessions[AIController.homeID]?.requestID != nil {
            if let web = answer(host),
               let count = try? await web.evaluateJavaScript("document.getElementById('content').textContent.length") as? Int,
               count > 0, lengths.last != count {
                lengths.append(count)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard lengths.contains(where: { $0 > 0 && $0 < 2800 }) else {
            throw PerchError("Buffered SSE only rendered the completed body: \(lengths)")
        }
        precondition(live.sessions[AIController.homeID]?.requestID == nil && live.sessions[AIController.homeID]?.error == nil)
        precondition(live.sessions[AIController.homeID]?.messages.last?.text == String(repeating: "正文增量片段。\n", count: 700))
        print("PASS: buffered SSE renders an intermediate body in the actual root Chat")
        let chatID = store.selected!
        store.newTab(address: baseURL + "/background-page")
        let pageID = store.selected!, page = store.browser!.webView
        page.loadHTMLString("<!doctype html><p>Background generation fixture</p>", baseURL: URL(string: baseURL))
        for api in AIProtocol.allCases {
            var configuration = config
            configuration.apiProtocol = api
            precondition(live.save(configuration, key: "synthetic-key"))
            store.activate(chatID)
            live.drafts[AIController.homeID] = "Retained draft"
            precondition(live.send("Streaming fixture", tab: AIController.homeID, browser: nil, usePage: false))
            try await wait { live.sessions[AIController.homeID]?.messages.last?.text == "第一段" }
            store.activate(pageID)
            try await wait { page.window === window }
            try await wait { live.sessions[AIController.homeID]?.requestID == nil }
            precondition(live.sessions[AIController.homeID]?.error == nil &&
                         live.sessions[AIController.homeID]?.messages.last?.text == "第一段\n\n第二段\n\n第三段")
            precondition(live.drafts[AIController.homeID] == "Retained draft")
            store.activate(chatID)
            try await wait { page.window == nil }
        }
        print("PASS: all three protocols finish generating while native Chat is off-window and preserve its draft")
    }
    static func experienceChecks(baseURL: String) async throws {
        try await followupControlsChecks()
        let suite = "dev.perch.experience.selftest.\(UUID())", tab = UUID()
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perch-experience-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let ai = AIController(defaults: defaults, conversationDirectory: directory)
        var config = AIConfiguration(provider: .custom, baseURL: baseURL + "/v1", model: "fixture")
        for api in AIProtocol.allCases {
            config.apiProtocol = api
            precondition(ai.save(config, key: "synthetic-key"))
            ai.clear(tab)
            precondition(ai.send("Interaction clarify", tab: tab, browser: nil, usePage: false))
            precondition(ai.send("File followup", tab: tab, browser: nil, usePage: false))
            try await wait { ai.sessions[tab]?.requestID == nil }
            guard let message = ai.sessions[tab]?.messages.last, message.clarification?.questions.count == 2,
                  ai.sessions[tab]?.error == nil else { throw PerchError("Clarification failed: \(ai.sessions[tab]?.error ?? "missing card")") }
            precondition(ai.pausedQueues.contains(tab) && ai.queuedMessages[tab]?.count == 1)
            let restored = AIController(defaults: defaults, conversationDirectory: directory)
            precondition(restored.sessions[tab]?.messages.last?.clarification == message.clarification)
            precondition(!ai.answerClarification(["", "macOS"], messageID: message.id, tab: tab, availablePages: { [] }))
            ai.drafts[tab] = "Keep my draft"
            precondition(ai.answerClarification(["Swift", "macOS 自由输入"], messageID: message.id, tab: tab, availablePages: { [] }))
            precondition(!ai.answerClarification(["Swift", "duplicate"], messageID: message.id, tab: tab, availablePages: { [] }))
            try await wait { ai.sessions[tab]?.requestID == nil }
            precondition(ai.sessions[tab]?.messages.last?.text == "Clarification resumed")
            precondition(ai.sessions[tab]?.messages[1].clarification?.answers == ["Swift", "macOS 自由输入"])
            precondition(ai.drafts[tab] == "Keep my draft" && ai.queuedMessages[tab]?.count == 1)
            ai.removeQueuedMessage(ai.queuedMessages[tab]!.first!.id, tab: tab)
            precondition(ai.send("Interaction suggest", tab: tab, browser: nil, usePage: false))
            try await wait { ai.sessions[tab]?.requestID == nil }
            guard let final = ai.sessions[tab]?.messages.last, let suggestions = final.followups,
                  suggestions.count == 2, ai.sessions[tab]?.error == nil else { throw PerchError("Missing followups") }
            let count = ai.sessions[tab]!.messages.count
            ai.fillFollowup(suggestions[0], messageID: final.id, tab: tab)
            precondition(ai.drafts[tab] == suggestions[0] && ai.sessions[tab]!.messages.count == count && ai.sessions[tab]?.requestID == nil)
            ai.fillFollowup("not a suggestion", messageID: final.id, tab: tab)
            precondition(ai.drafts[tab] == suggestions[0])
            let fork = ai.forkConversation(ai.sessions[tab]!.id)!
            precondition(ai.conversations[fork]?.messages.last?.followups == suggestions)
            precondition(ai.sessions[tab]!.markdown.contains("输出语言") && ai.sessions[tab]!.markdown.contains("补充一个示例"))
            precondition(!ai.sendFollowup("not a suggestion", messageID: final.id, tab: tab, availablePages: { [] }))
            ai.drafts[tab] = "Keep my unfinished draft"
            precondition(ai.sendFollowup(suggestions[1], messageID: final.id, tab: tab, availablePages: { [] }))
            precondition(ai.sessions[tab]?.messages[count].text == suggestions[1])
            precondition(!ai.sendFollowup(suggestions[1], messageID: final.id, tab: tab, availablePages: { [] }))
            try await wait { ai.sessions[tab]?.requestID == nil }
            precondition(ai.drafts[tab] == "Keep my unfinished draft")
            precondition(!ai.sendFollowup(suggestions[0], messageID: final.id, tab: tab, availablePages: { [] }))
            // Invalid tool data is rejected without replacing a previously usable message.
            for arguments in [#"{"questions":[]}"#, #"{"questions":[{"label":"x","options":["a","a"]}]}"#,
                              #"{"questions":[{"label":"x","options":[]}],"extra":1}"#] {
                var invalid = AIMessage(role: "assistant", text: "")
                let result = try AIInteraction.receive(AIPageToolCall(id: "bad", name: "ask_clarification", arguments: arguments), message: &invalid)
                precondition(result.contains("error") && invalid.clarification == nil)
            }
            print("PASS: \(api.rawValue) clarification, paused queue, followup fill-only/direct send, draft preservation, duplicate/stale rejection and Fork")
        }
        ai.clear(tab)
        precondition(ai.send("File fixture", tab: tab, browser: nil, usePage: false))
        try await wait { ai.sessions[tab]?.requestID == nil }
        let first = ai.sessions[tab]!.messages.last!
        precondition(ai.send("File revision", tab: tab, browser: nil, usePage: false))
        try await wait { ai.sessions[tab]?.requestID == nil }
        let session = ai.sessions[tab]!, last = session.messages.last!
        precondition(session.fileVersions(name: "helper.user.js", through: first.id).count == 1)
        let versions = session.fileVersions(name: "helper.user.js", through: last.id)
        precondition(versions.count == 2 && versions[0].id != versions[1].id)
        let diff = String(AIFileDifference.text(from: "a\nold\nz", to: "a\nnew\nz").characters)
        precondition(diff.contains("− old") && diff.contains("+ new") && diff.contains("  z"))
        let source = AISearchSource(title: "Source <script>", url: URL(string: "https://fixture.invalid/source")!, excerpt: "Actual excerpt <b>literal</b>")
        let cited = AISearchSource.citedText("可靠结论", output: [["type": "message", "content": [
            ["text": "可靠结论", "annotations": [["url": source.id, "title": "Source", "end_index": 4]]]
        ]]])
        precondition(cited == "可靠结论 [Source](<https://fixture.invalid/source>)")
        let legacy = try JSONDecoder().decode(AISearchSource.self, from: Data(#"{"title":"old","url":"https://fixture.invalid"}"#.utf8))
        precondition(legacy.excerpt == nil)
        print("PASS: previous-message version boundaries, additions/deletions, native citation placement and legacy source decode")

        let bridge = AIMarkdownView.Coordinator(height: .constant(300))
        let web = AIMarkdownView.webView(handler: bridge)
        bridge.text = "| Name | Count |\n|---|---|\n| B | 10 |\n| A | 2 |\n\n[证据](https://fixture.invalid/source)"
        bridge.sources = [source]; web.navigationDelegate = bridge
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 540, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
        defer {
            bridge.citationPreview.close()
            web.configuration.userContentController.removeScriptMessageHandler(forName: "markdown")
            web.navigationDelegate = nil; window.orderOut(nil); window.contentView = nil
        }
        try await wait { bridge.loaded }
        try await Task.sleep(nanoseconds: 250_000_000)
        let tableResult = try await web.evaluateJavaScript("""
        (() => {
          const table=document.querySelector('table'); table.querySelectorAll('th button')[1].click();
          const ascending=table.tBodies[0].rows[0].cells[1].textContent==='2';
          table.querySelectorAll('th button')[1].click();
          const descending=table.tBodies[0].rows[0].cells[1].textContent==='10';
          return ascending && descending && document.querySelectorAll('.table-tools button').length===3;
        })()
        """) as? Bool
        precondition(tableResult == true)
        let csv = try await web.callAsyncJavaScript("return tableCSV(rows);", arguments: ["rows": [["a,b", "x\"y", "a\nb", "=SUM(A1)"]]], in: nil, contentWorld: .page) as? String
        precondition(csv == "\"a,b\",\"x\"\"y\",\"a\nb\",\"'=SUM(A1)\"")
        let beforeHover = try await web.evaluateJavaScript("document.getElementById('content').getBoundingClientRect().height") as! Double
        _ = try await web.evaluateJavaScript("document.querySelector('.source-citation').dispatchEvent(new Event('mouseenter'))")
        try await Task.sleep(nanoseconds: 450_000_000)
        precondition(!bridge.citationPreview.popover.isShown, "Citation preview must wait 0.6 seconds")
        _ = try await web.evaluateJavaScript("document.querySelector('.source-citation').dispatchEvent(new Event('mouseleave'))")
        try await Task.sleep(nanoseconds: 750_000_000)
        precondition(!bridge.citationPreview.popover.isShown, "Leaving the citation must cancel its pending preview")
        _ = try await web.evaluateJavaScript("document.querySelector('.source-citation').dispatchEvent(new Event('mouseenter'))")
        try await wait { bridge.citationPreview.popover.isShown }
        let afterHover = try await web.evaluateJavaScript("document.getElementById('content').getBoundingClientRect().height") as! Double
        guard beforeHover == afterHover else { throw PerchError("Citation preview changed message height: \(beforeHover) → \(afterHover)") }
        let noInlinePreview = try await web.evaluateJavaScript("!document.querySelector('.source-preview')") as? Bool
        precondition(noInlinePreview == true, "Citation preview must not insert content into the message")
        _ = try await web.evaluateJavaScript("document.querySelector('.source-citation').dispatchEvent(new Event('mouseleave'))")
        bridge.citationPreview.hover(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        guard bridge.citationPreview.popover.isShown else { throw PerchError("Moving into the popover did not keep it open") }
        var opened: [URL] = []
        bridge.citationPreview.openURL = { opened.append($0) }
        bridge.citationPreview.openOriginal()
        guard opened == [source.url] else { throw PerchError("Citation original-link action opened an unexpected URL") }
        try await wait { !bridge.citationPreview.popover.isShown }
        let anchor = NSRect(x: 12, y: 12, width: 24, height: 20)
        bridge.citationPreview.enter(source: source, rect: anchor, web: web)
        try await wait { bridge.citationPreview.popover.isShown }
        let nextSource = AISearchSource(title: "Next fixture", url: URL(string: "https://fixture.invalid/next")!)
        bridge.citationPreview.enter(source: nextSource, rect: anchor, web: web)
        try await wait { !bridge.citationPreview.popover.isShown }
        try await wait { bridge.citationPreview.popover.isShown }
        bridge.citationPreview.openOriginal()
        guard opened == [source.url, nextSource.url] else { throw PerchError("Changing citations lost the pending preview or retained the old URL") }
        try await wait { !bridge.citationPreview.popover.isShown }
        let viewer = AITable.open(rows: [["Name", "Count"], ["A", "2"]], from: window)!
        try await wait { viewer.loaded }
        let expanded = try await viewer.web.evaluateJavaScript("window.tableExpanded && document.querySelectorAll('.table-tools button').length===2") as? Bool
        precondition(expanded == true && viewer.window.level == window.level)
        viewer.window.close()
        print("PASS: WebKit sorting/CSV, 0.6-second citation preview, cancellation, stable message height, popover hover, citation switching and original-link action")

        let previewConfiguration = WKWebViewConfiguration()
        previewConfiguration.websiteDataStore = .nonPersistent()
        previewConfiguration.userContentController.addUserScript(WKUserScript(source:
            "window.addEventListener('message', event => {window.previewResult=event.data;});",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let preview = WKWebView(frame: window.contentView!.bounds, configuration: previewConfiguration)
        let previewDelegate = AIFilePreview.Coordinator()
        preview.navigationDelegate = previewDelegate; window.contentView = preview
        preview.loadHTMLString(AIFilePreview.document("""
        <!doctype html><html><body><h1>Preview</h1><svg width="30" height="30"><circle cx="15" cy="15" r="10"/></svg>
        <script>
        (async()=>{
          let storageBlocked=false,networkBlocked=false,parentBlocked=false;
          try{localStorage.setItem('x','y')}catch(e){storageBlocked=true}
          try{await fetch('\(baseURL)/preview-must-not-fetch')}catch(e){networkBlocked=true}
          try{parent.document.body.textContent='escaped'}catch(e){parentBlocked=true}
          parent.postMessage({storageBlocked,networkBlocked,parentBlocked,scriptRan:true,
            hasBridge:!!window.webkit?.messageHandlers?.markdown},'*');
        })();
        </script></body></html>
        """), baseURL: nil)
        var previewResult: [String: Bool]?
        let deadline = Date().addingTimeInterval(8)
        while previewResult == nil && Date() < deadline {
            previewResult = try? await preview.evaluateJavaScript("window.previewResult") as? [String: Bool]
            if previewResult == nil { try await Task.sleep(nanoseconds: 30_000_000) }
        }
        guard let previewResult else { throw PerchError("Sandbox preview script did not execute") }
        precondition(previewResult["scriptRan"] == true && previewResult["storageBlocked"] == true &&
                     previewResult["networkBlocked"] == true && previewResult["parentBlocked"] == true && previewResult["hasBridge"] == false)
        let isolated = try await preview.evaluateJavaScript("document.querySelector('iframe').contentDocument===null") as? Bool
        precondition(isolated == true && !preview.configuration.websiteDataStore.isPersistent)
        preview.stopLoading(); preview.navigationDelegate = nil
        print("PASS: actual HTML/SVG sandbox scripts, blocked network/storage/parent access, absent native bridge and nonpersistent WebKit")
    }

    static func followupControlsChecks() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        var sent = 0, added = 0
        let text = "Fixture next step"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        let host = NSHostingView(rootView: VStack(alignment: .leading) {
            AIFollowupSuggestion(text: text, send: { sent += 1 }, addToConversation: { added += 1 })
            AIFollowupSuggestion(text: "Other next step", send: {}, addToConversation: {})
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil); window.contentView = nil
        }
        func element(_ node: Any, _ label: String) -> NSObject? {
            guard let object = node as? NSObject else { return nil }
            for key in ["accessibilityLabel", "accessibilityTitle"] {
                if object.responds(to: NSSelectorFromString(key)), object.value(forKey: key) as? String == label { return object }
            }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            return (object.value(forKey: "accessibilityChildren") as? [Any] ?? []).lazy.compactMap { element($0, label) }.first
        }
        func rect(_ label: String) -> NSRect {
            (element(host, label)!.value(forKey: "accessibilityFrame") as! NSValue).rectValue
        }
        func click(_ label: String) {
            let frame = rect(label)
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            }
        }
        let primary = "直接发送：\(text)", secondary = "添加到对话：\(text)"
        try await wait {
            element(host, primary) != nil && element(host, secondary) != nil &&
            element(host, "添加到对话：Other next step") != nil
        }
        precondition(!rect(primary).intersects(rect(secondary)), "Followup actions must have separate hit areas")
        _ = element(host, primary)!.perform(NSSelectorFromString("accessibilityPerformPress"))
        precondition(sent == 1 && added == 0)
        click(secondary)
        precondition(added == 1 && sent == 1, "Adding to the composer must not also send")
        click(primary)
        precondition(sent == 2 && added == 1)
        print("PASS: followup send/add actions always visible, separate hit areas and independent clicks")
    }
}
