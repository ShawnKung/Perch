import AppKit
import SwiftUI
import WebKit

// Synthetic provider and page only; never touches the production defaults or Keychain.
@MainActor
enum AISelfCheck {
    static func wait(timeout: TimeInterval = 8, file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw PerchError("AI self-check timed out (\(file):\(line))") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    static func fileChecks(baseURL: String) async throws {
        let suite = "dev.perch.files.selftest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perch-files-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let ai = AIController(defaults: defaults, conversationDirectory: directory)
        var config = AIConfiguration(provider: .custom, baseURL: baseURL + "/v1", model: "fixture")
        precondition(ai.save(config, key: "synthetic-key"))
        var example: AIGeneratedFile?
        for apiProtocol in AIProtocol.allCases {
            config.apiProtocol = apiProtocol
            precondition(ai.save(config))
            let reasoningTab = UUID()
            precondition(ai.send("Reasoning fixture", tab: reasoningTab, browser: nil, usePage: false))
            precondition(ai.sessions[reasoningTab]?.phase == .waiting && ai.sessions[reasoningTab]?.messages.last?.reasoning == nil)
            try await wait { ai.sessions[reasoningTab]?.messages.last?.reasoning?.isEmpty == false }
            precondition(ai.sessions[reasoningTab]?.requestID != nil && ai.sessions[reasoningTab]?.messages.last?.text == "" && ai.sessions[reasoningTab]?.phase == .thinking)
            try await wait { ai.sessions[reasoningTab]?.requestID == nil }
            let reasoningSession = ai.sessions[reasoningTab]!
            precondition(reasoningSession.error == nil && reasoningSession.messages.last?.reasoning == "Inspect fixture.")
            precondition(reasoningSession.phase == nil)
            precondition(reasoningSession.messages.last?.text == "Reasoning verified")
            let restoredReasoning = AIController(defaults: defaults, conversationDirectory: directory)
            precondition(restoredReasoning.sessions[reasoningTab]?.messages.last?.reasoning == "Inspect fixture.")
            let reasoningFork = ai.forkConversation(reasoningSession.id)!
            precondition(ai.conversations[reasoningFork]?.messages.last?.reasoning == "Inspect fixture.")
            precondition(reasoningSession.markdown.contains("### 思考过程\n\nInspect fixture."))
            let reasoningView = NSHostingView(rootView: AIReasoningView(text: "Inspect fixture.", phase: .thinking))
            reasoningView.frame = NSRect(x: 0, y: 0, width: 300, height: 260)
            reasoningView.layoutSubtreeIfNeeded()
            precondition(reasoningView.fittingSize.height > 0)
            print("PASS: \(apiProtocol.rawValue) live reasoning, snapshot deduplication, final answer, persistence, Fork, export and native disclosure layout")
            let phases = UUID()
            precondition(ai.send("File phase fixture", tab: phases, browser: nil, usePage: false))
            try await wait { ai.sessions[phases]?.phase == .creatingFile }
            precondition(ai.sessions[phases]?.messages.last?.generatedFiles == nil)
            try await wait { ai.sessions[phases]?.phase == .fileReady }
            precondition(ai.sessions[phases]?.requestID != nil && ai.sessions[phases]?.messages.last?.generatedFiles?.count == 1)
            try await wait { ai.sessions[phases]?.phase == .thinking && ai.sessions[phases]?.messages.last?.text.hasPrefix("Before tool") == true }
            precondition(ai.sessions[phases]?.requestID != nil)
            try await wait { ai.sessions[phases]?.requestID == nil }
            precondition(ai.sessions[phases]?.phase == nil && ai.sessions[phases]?.error == nil)
            precondition(ai.sessions[phases]?.messages.last?.reasoning == "Second round.")
            precondition(ai.sessions[phases]?.messages.last?.text == "Before toolAfter tool")
            let fileWait = UUID()
            precondition(ai.send("File phase fixture", tab: fileWait, browser: nil, usePage: false))
            try await wait { ai.sessions[fileWait]?.phase == .fileReady }
            ai.stop(fileWait)
            precondition(ai.sessions[fileWait]?.phase == nil && ai.sessions[fileWait]?.requestID == nil)
            precondition(ai.sessions[fileWait]?.messages.last?.generatedFiles?.count == 1)
            let restoredFileWait = AIController(defaults: defaults, conversationDirectory: directory)
            precondition(restoredFileWait.sessions[fileWait]?.phase == nil && restoredFileWait.sessions[fileWait]?.messages.last?.generatedFiles?.count == 1)
            print("PASS: \(apiProtocol.rawValue) file-ready waiting, continued reasoning, completion and cancellation preserve delivered files")
            let tab = UUID()
            precondition(ai.send("File fixture", tab: tab, browser: nil, usePage: false))
            try await wait(timeout: 15) { ai.sessions[tab]?.requestID == nil }
            guard let session = ai.sessions[tab], session.error == nil,
                  let files = session.messages.last?.generatedFiles, files.count == 2 else {
                throw PerchError("File delivery failed (\(apiProtocol)): \(ai.sessions[tab]?.error ?? "missing files")")
            }
            let script = files[0]
            precondition(script.name == "helper.user.js" && script.content.utf8.count > 16384 && script.content.hasSuffix("// updated\n"))
            let calls = session.messages.last!.toolRounds!.first!.calls
            let results = session.messages.last!.toolRounds!.first!.results
            precondition(calls.count == 3)
            let firstResult = try JSONSerialization.jsonObject(with: Data(results[0].utf8)) as! [String: Any]
            let thirdResult = try JSONSerialization.jsonObject(with: Data(results[2].utf8)) as! [String: Any]
            precondition(firstResult["file_id"] as? String == thirdResult["file_id"] as? String)
            precondition(session.markdown.contains(script.content) && session.markdown.contains("````text"))
            let restored = AIController(defaults: defaults, conversationDirectory: directory)
            precondition(restored.sessions[tab]?.messages.last?.generatedFiles == files)
            let fork = ai.forkConversation(session.id)!
            precondition(ai.conversations[fork]?.messages.last?.generatedFiles == files)
            // Replay the same history across all three protocol representations.
            for replay in AIProtocol.allCases {
                config.apiProtocol = replay; precondition(ai.save(config))
                precondition(ai.send("File followup", tab: tab, browser: nil, usePage: false))
                try await wait { ai.sessions[tab]?.requestID == nil }
                precondition(ai.sessions[tab]?.error == nil && ai.sessions[tab]?.messages.last?.text == "File history verified")
            }
            config.apiProtocol = apiProtocol; precondition(ai.save(config))
            precondition(ai.send("File revision", tab: tab, browser: nil, usePage: false))
            try await wait { ai.sessions[tab]?.requestID == nil }
            precondition(ai.sessions[tab]?.messages[1].generatedFiles == files)
            precondition(ai.sessions[tab]?.messages.last?.generatedFiles?.first?.id != script.id)
            for mode in ["invalid", "interrupted", "truncated", "missing-id"] {
                let bad = UUID()
                precondition(ai.send("File \(mode)", tab: bad, browser: nil, usePage: false))
                try await wait { ai.sessions[bad]?.requestID == nil }
                precondition((ai.sessions[bad]?.messages.last?.generatedFiles ?? []).isEmpty)
                precondition(ai.sessions[bad]?.error != nil)
            }
            let first = try script.download(to: directory)
            let second = try script.download(to: directory)
            precondition(first != second && second.lastPathComponent.hasSuffix(".user.js"))
            let bytes = try Data(contentsOf: first), duplicate = try Data(contentsOf: second)
            precondition(bytes == Data(script.content.utf8) && bytes == duplicate)
            example = script
            print("PASS: \(apiProtocol.rawValue) file-only delivery, >16 KiB, multiple files, stable IDs, cross-protocol replay, versions, persistence, Fork, export and incomplete-stream rejection")
        }
        var bounded = AIReasoningStream()
        let reasoningEvent = String(data: try JSONSerialization.data(withJSONObject: [
            "choices": [["delta": ["reasoning_content": String(repeating: "思", count: 32000)]]]
        ]), encoding: .utf8)!
        for _ in 0..<12 { bounded.consume(reasoningEvent, protocol: .openAI) }
        precondition(bounded.text.hasPrefix(String(repeating: "思", count: 63950)) && bounded.text.count <= 64000 && bounded.text.contains("思考内容过长"))
        let legacyMessage = AIMessage(role: "assistant", text: "legacy")
        let legacyData = try JSONEncoder().encode(legacyMessage)
        let decodedLegacy = try JSONDecoder().decode(AIMessage.self, from: legacyData)
        precondition(decodedLegacy.reasoning == nil)
        print("PASS: reasoning display bound does not abort generation; old message archive remains readable")
        var files: [AIGeneratedFile] = []
        for (name, content) in [("../bad.py", "text"), ("a\\b.py", "text"), (".hidden", "text"),
                                ("bad\n.py", "text"), ("ok.py", ""), ("ok.py", "\0"),
                                ("ok.py", String(repeating: "x", count: AIGeneratedFile.contentLimit + 1))] {
            let args = try JSONSerialization.data(withJSONObject: ["name": name, "content": content])
            let result = try AIGeneratedFile.receive(String(decoding: args, as: UTF8.self), files: &files)
            precondition(result.contains("error") && files.isEmpty)
        }
        for n in 0..<9 {
            let args = try JSONSerialization.data(withJSONObject: ["name": "\(n).txt", "content": "text"])
            _ = try AIGeneratedFile.receive(String(decoding: args, as: UTF8.self), files: &files)
        }
        precondition(files.count == 8)
        files = []
        for n in 0..<5 {
            let args = try JSONSerialization.data(withJSONObject: ["name": "\(n).txt", "content": String(repeating: "x", count: 65536)])
            _ = try AIGeneratedFile.receive(String(decoding: args, as: UTF8.self), files: &files)
        }
        precondition(files.count == 4)
        let legacy = try JSONEncoder().encode(AIMessage(role: "assistant", text: "old"))
        let decoded = try JSONDecoder().decode(AIMessage.self, from: legacy)
        precondition(decoded.generatedFiles == nil)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AIGeneratedFileCard(file: example!).padding(20).background(Style.paper))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()
        precondition(host.bounds.width == 420)
        if let path = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("generated-file.png"))
        }
        func element(_ node: Any, label: String) -> NSObject? {
            guard let object = node as? NSObject else { return nil }
            for key in ["accessibilityLabel", "accessibilityTitle"] {
                if object.responds(to: NSSelectorFromString(key)), object.value(forKey: key) as? String == label { return object }
            }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            return (object.value(forKey: "accessibilityChildren") as? [Any] ?? []).lazy.compactMap { element($0, label: label) }.first
        }
        try await wait { element(host, label: "下载") != nil && element(host, label: "查看源码") != nil }
        let disclosure = element(host, label: "查看源码")!
        let press = NSSelectorFromString("accessibilityPerformPress")
        precondition(disclosure.responds(to: press))
        _ = disclosure.perform(press)
        window.setContentSize(NSSize(width: 420, height: 400))
        try await Task.sleep(nanoseconds: 150_000_000)
        func hasScroll(_ view: NSView) -> Bool { view is NSScrollView || view.subviews.contains(where: hasScroll) }
        precondition(hasScroll(host))
        var saveCalled = false
        example!.saveAs(window: window) { _ in saveCalled = true }
        try await wait { window.attachedSheet is NSSavePanel }
        let panel = window.attachedSheet as! NSSavePanel
        precondition(panel.nameFieldStringValue == example!.name)
        panel.cancel(nil)
        try await wait { window.attachedSheet == nil }
        precondition(!saveCalled)
        print("PASS: filename/content/count/total limits, byte-exact non-overwriting download, legacy decode, native file-card/source interaction and Save As cancellation")
    }
    static func activityChecks() async throws {
        var message = AIMessage(role: "assistant", text: "")
        for status in [nil, "已允许联网，等待模型调用", "本轮未调用搜索"] as [String?] {
            message.searchStatus = status
            precondition(!AISearchEvidence.isVisible(message))
        }
        message.searchStatus = "正在搜索…"
        precondition(AISearchEvidence.isVisible(message))
        message.searchStatus = "搜索完成"
        message.searchSources = [AISearchSource(title: "Fixture source", url: URL(string: "https://fixture.invalid/source")!)]
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func element(_ node: Any, label: String) -> NSObject? {
            guard let object = node as? NSObject else { return nil }
            for key in ["accessibilityLabel", "accessibilityTitle"] {
                if object.responds(to: NSSelectorFromString(key)), object.value(forKey: key) as? String == label { return object }
            }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            return (object.value(forKey: "accessibilityChildren") as? [Any] ?? []).lazy.compactMap { element($0, label: label) }.first
        }
        for phase in [AIResponsePhase.waiting, .creatingFile, .fileReady, .thinking, .answering, .tools] {
            host.rootView = AnyView(AIReasoningView(text: "", phase: phase)
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
            try await wait { element(host, label: phase.title) != nil }
            precondition(element(host, label: "已停止") == nil)
        }
        for (title, view) in [
            ("搜索完成 · 1 个来源", AnyView(AISearchEvidence(message: message))),
            ("思考过程", AnyView(AIReasoningView(text: "Fixture reasoning")))
        ] {
            host.rootView = AnyView(view.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
            try await wait { element(host, label: title) != nil }
            func expanded() -> Bool {
                guard let button = element(host, label: title),
                      button.responds(to: NSSelectorFromString("accessibilityValue")) else { return false }
                return button.value(forKey: "accessibilityValue") as? String == "已展开"
            }
            precondition(!expanded())
            // Exercise physical hit areas for the arrow, symbol, title and empty trailing area.
            for offset in [6.0, 29.0, 66.0, 250.0] {
                for expected in [true, false] {
                    host.layoutSubtreeIfNeeded()
                    let button = element(host, label: title)!
                    let frame = (button.value(forKey: "accessibilityFrame") as! NSValue).rectValue
                    precondition(frame.width > 280)
                    let point = window.convertPoint(fromScreen: NSPoint(x: frame.minX + offset, y: frame.midY))
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
                    }
                    try await wait { expanded() == expected }
                }
            }
        }
        print("PASS: idle and legacy search hints hidden; search and reasoning expand/collapse from arrow, icon, text and trailing row")
        func reasoningScroll(_ node: NSView) -> AIReasoningScrollView? {
            if let scroll = node as? AIReasoningScrollView { return scroll }
            return node.subviews.lazy.compactMap(reasoningScroll).first
        }
        func renderDisclosure(text: String, phase: AIResponsePhase?, hasBody: Bool) {
            host.rootView = AnyView(AIReasoningView(text: text, phase: phase, hasBody: hasBody)
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
            host.layoutSubtreeIfNeeded()
        }
        func disclosureExpanded() -> Bool {
            host.layoutSubtreeIfNeeded()
            return reasoningScroll(host) != nil
        }
        renderDisclosure(text: "", phase: .thinking, hasBody: false)
        try await wait { element(host, label: AIResponsePhase.thinking.title) != nil }
        precondition(!disclosureExpanded())
        renderDisclosure(text: "Inspect fixture.", phase: .thinking, hasBody: false)
        try await wait { disclosureExpanded() }
        // The first body delta may arrive before the phase changes.
        renderDisclosure(text: "Inspect fixture.", phase: .thinking, hasBody: true)
        try await wait { !disclosureExpanded() }
        renderDisclosure(text: "Inspect fixture.", phase: .answering, hasBody: true)
        try await wait { element(host, label: AIResponsePhase.answering.title) != nil }
        let disclosure = element(host, label: AIResponsePhase.answering.title)!
        _ = disclosure.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await wait { disclosureExpanded() }
        renderDisclosure(text: "Inspect fixture. More reasoning.", phase: .thinking, hasBody: true)
        try await wait { element(host, label: AIResponsePhase.thinking.title) != nil }
        precondition(disclosureExpanded())
        renderDisclosure(text: "Inspect fixture. More reasoning.", phase: nil, hasBody: true)
        try await wait { element(host, label: "思考过程") != nil }
        precondition(disclosureExpanded())
        _ = element(host, label: "思考过程")!.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await wait { !disclosureExpanded() }
        renderDisclosure(text: "Inspect fixture. Tool reasoning.", phase: .thinking, hasBody: true)
        try await wait { element(host, label: AIResponsePhase.thinking.title) != nil }
        precondition(!disclosureExpanded())
        host.rootView = AnyView(EmptyView())
        try await wait { element(host, label: AIResponsePhase.thinking.title) == nil }
        renderDisclosure(text: "Saved reasoning.", phase: nil, hasBody: true)
        try await wait { element(host, label: "思考过程") != nil }
        precondition(!disclosureExpanded())
        print("PASS: reasoning expands before body, collapses at first body delta, preserves manual choice through later reasoning and defaults closed in history")
        var reasoningText = (0..<80).map { "Thought line \($0): inspecting the fixture." }.joined(separator: "\n")
        func renderReasoning(active: Bool) {
            host.rootView = AnyView(ScrollView {
                VStack(alignment: .leading) {
                    AIReasoningView(text: reasoningText, phase: active ? .thinking : nil)
                    AIMarkdownView(text: String(repeating: "Outer conversation fixture.\n\n", count: 40))
                }.padding(16)
            })
        }
        renderReasoning(active: true)
        try await wait {
            host.layoutSubtreeIfNeeded()
            guard let scroll = reasoningScroll(host) else { return false }
            return scroll.bottom > 500 && abs(scroll.bottom - scroll.contentView.bounds.minY) < 4
        }
        var scroll = reasoningScroll(host)!
        precondition(scroll.frame.height <= 221)
        let initialBottom = scroll.bottom
        reasoningText += "\n" + String(repeating: "New reasoning line.\n", count: 10)
        renderReasoning(active: true)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return scroll.bottom > initialBottom && abs(scroll.bottom - scroll.contentView.bounds.minY) < 4
        }
        func wheel(_ delta: Int32, in scroll: AIReasoningScrollView) {
            let event = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!)!
            scroll.editor.scrollWheel(with: event)
        }
        wheel(90, in: scroll)
        try await wait { !scroll.followsBottom && scroll.bottom - scroll.contentView.bounds.minY > 80 }
        let readingY = scroll.contentView.bounds.minY
        precondition(readingY > 20, "Exercise a reader in the middle, not just the top")
        let priorHeight = scroll.bottom
        reasoningText += "\n" + String(repeating: "More reasoning line.\n", count: 10)
        renderReasoning(active: true)
        try await wait { host.layoutSubtreeIfNeeded(); return scroll.bottom > priorHeight }
        precondition(abs(scroll.contentView.bounds.minY - readingY) < 2, "New reasoning must not move a reader who scrolled up")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        precondition(scroll.followsBottom)
        let resumedHeight = scroll.bottom
        reasoningText += "\n" + String(repeating: "Resumed reasoning line.\n", count: 10)
        renderReasoning(active: true)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return scroll.bottom > resumedHeight && abs(scroll.bottom - scroll.contentView.bounds.minY) < 4
        }
        renderReasoning(active: false)
        try await wait { reasoningScroll(host)?.active == false }
        func toggleReasoning() {
            host.layoutSubtreeIfNeeded()
            let button = element(host, label: "思考过程")!
            let press = NSSelectorFromString("accessibilityPerformPress")
            precondition(button.responds(to: press))
            _ = button.perform(press)
        }
        toggleReasoning()
        try await wait { reasoningScroll(host) == nil }
        toggleReasoning()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return reasoningScroll(host).map { $0.bottom > 500 && $0.frame.height > 200 && $0.frame.height <= 221 } == true
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        scroll = reasoningScroll(host)!
        precondition(scroll.editor.isSelectable && !scroll.editor.isEditable)
        print("PASS: reasoning follows bottom and pauses/resumes; reopened reasoning retains its bounded height and selectable read-only text")
    }
    static func searchChecks(baseURL: String) async throws {
        try await activityChecks()
        let suite = "dev.perch.search.selftest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perch-search-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let legacyOff = UUID()
        let legacy = AISession(messages: [AIMessage(role: "user", text: "legacy search fixture")], searchChoice: .off)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(AIConversationArchive(conversations: [legacy.id: legacy], tabs: [legacyOff: legacy.id]))
            .write(to: directory.appendingPathComponent("conversations.json"))
        let ai = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(!ai.searchEnabled(for: legacyOff) && ai.searchChoice(for: legacyOff) == .automatic)
        ai.setSearchSource(.native, tab: legacyOff)
        precondition(!ai.searchEnabled(for: legacyOff) && ai.searchRoute(for: legacyOff) == .off)
        ai.setSearchEnabled(true, tab: legacyOff)
        precondition(ai.searchEnabled(for: legacyOff) && ai.searchChoice(for: legacyOff) == .native)
        ai.clear(legacyOff)
        var model = AIConfiguration(provider: .custom, baseURL: baseURL + "/v1", model: "fixture")
        var search = AISearchConfiguration()
        search.baseURL = baseURL + "/v1"
        precondition(search.endpoint?.path == "/v1/tools/search")
        precondition(ai.save(model, key: "synthetic-key") && ai.saveSearch(search, key: "synthetic-search-key"))
        let stored = String(data: defaults.data(forKey: "aiSearchProvider")!, encoding: .utf8)!
        precondition(!stored.contains("synthetic-search-key") && model.account != search.account)
        let searchWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 780, height: 580),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        let searchHost = NSHostingView(rootView: AISearchProviderEditor(ai: ai, back: {}).background(Style.paper))
        searchWindow.contentView = searchHost; searchWindow.orderFront(nil)
        func secureField(_ view: NSView) -> NSSecureTextField? {
            if let field = view as? NSSecureTextField { return field }
            return view.subviews.compactMap(secureField).first
        }
        try await wait { secureField(searchHost)?.stringValue == "••••••••••••" }
        try await Task.sleep(nanoseconds: 150_000_000)
        if let path = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"] {
            searchHost.layoutSubtreeIfNeeded()
            if let bitmap = searchHost.bitmapImageRepForCachingDisplay(in: searchHost.bounds) {
                searchHost.cacheDisplay(in: searchHost.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("search-settings.png"))
            }
        }
        searchWindow.orderOut(nil); searchWindow.contentView = nil
        for args in ["not-json", "[]", "{}", "{\"query\":\"\"}", "{\"query\":\"q\",\"count\":true}", "{\"query\":\"q\",\"count\":1.2}", "{\"query\":\"q\",\"count\":11}", "{\"query\":\"q\",\"url\":\"https://example.com\"}",
                     "{\"query\":\"q\",\"num\":true}", "{\"query\":\"q\",\"num\":1.2}", "{\"query\":\"q\",\"num\":11}",
                     "{\"query\":\"q\",\"count\":3,\"num\":6}"] {
            do { _ = try AISearchResult.arguments(args); preconditionFailure("Invalid search arguments accepted") }
            catch {}
        }
        let (query, count) = try AISearchResult.arguments("{\"query\":\"fixture\",\"count\":3}")
        precondition(query == "fixture" && count == 3)
        let (aliasQuery, aliasCount) = try AISearchResult.arguments("{\"query\":\"DeepSeek 最新 模型 官网\",\"num\":6}")
        precondition(aliasQuery == "DeepSeek 最新 模型 官网" && aliasCount == 6)
        let (_, matchingCount) = try AISearchResult.arguments("{\"query\":\"fixture\",\"count\":3,\"num\":3}")
        precondition(matchingCount == 3)
        do {
            _ = try AISearchResult.arguments("{\"query\":\"valid query\",\"url\":\"https://example.com\"}")
            preconditionFailure("Unexpected search field accepted")
        } catch let error as PerchError { precondition(error.message.contains("仅支持") && !error.message.contains("query 必须")) }
        let (_, defaultCount) = try AISearchResult.arguments("{\"query\":\"fixture\"}")
        precondition(defaultCount == 5)
        precondition(AISearchSource.collect([["url": "javascript:alert(1)"], ["url": "https://user:secret@example.com"],
                                            ["url": "https://example.com", "title": "source"]]).count == 1)
        precondition(AINativeSearch.standard.effectiveProtocol(.openAI) == .responses)
        precondition(AINativeSearch.deepSeek.effectiveProtocol(.openAI) == .openAI)
        precondition(AINativeSearch.standard.definition(protocol: .openAI)?["type"] as? String == "web_search")
        var emptyNative = AIPageToolStream()
        try emptyNative.consume("{\"choices\":[{\"delta\":{\"server_tool_calls\":[]}}]}", protocol: .openAI)
        precondition(!emptyNative.searched)
        for protocolValue in AIProtocol.allCases {
            model.apiProtocol = protocolValue; model.nativeSearch = .deepSeek
            precondition(ai.save(model))
            let native = UUID()
            precondition(ai.searchRoute(for: native) == .native)
            precondition(ai.send("Search native fixture", tab: native, browser: nil, usePage: false))
            try await wait(timeout: 30) { ai.sessions[native]?.requestID == nil }
            let nativeAnswer = ai.sessions[native]!.messages.last!
            precondition(ai.sessions[native]?.error == nil && nativeAnswer.text.hasPrefix("Search verified"))
            precondition(nativeAnswer.searchSources?.first?.url.absoluteString == "https://search.fixture.invalid/source")
            precondition(nativeAnswer.searchEvents?.isEmpty == false && nativeAnswer.usage?.isEmpty == false)
            precondition(AISearchEvidence.isVisible(nativeAnswer))
            precondition((nativeAnswer.searchEvents ?? []).reduce(0) { $0 + $1.count } < 8192)
            if protocolValue != .openAI {
                precondition(nativeAnswer.toolRounds?.last?.calls.isEmpty == true && nativeAnswer.responseText == "")
            }
            if protocolValue == .responses {
                let overflow = UUID()
                precondition(ai.send("Search native overflow fixture", tab: overflow, browser: nil, usePage: false))
                try await wait(timeout: 30) { ai.sessions[overflow]?.requestID == nil }
                precondition(ai.sessions[overflow]?.error == "原生搜索记录超过大小限制。")
                print("PASS: >1 MiB reasoning excluded from search records, completion reasoning omitted, sources/usage retained, actual search overflow rejected")
            }
            precondition(ai.send("Search native followup fixture", tab: native, browser: nil, usePage: false))
            try await wait { ai.sessions[native]?.requestID == nil }
            precondition(ai.sessions[native]?.error == nil)
            ai.setSearchChoice(.off, tab: native)
            precondition(ai.searchRoute(for: native) == .off)
            precondition(ai.send("Search off fixture", tab: native, browser: nil, usePage: false))
            try await wait { ai.sessions[native]?.requestID == nil }
            precondition(ai.sessions[native]?.error == nil && ai.sessions[native]?.messages.last?.searchStatus == nil)
            let external = UUID()
            ai.setSearchChoice(.deepSeek, tab: external)
            precondition(ai.send("Search external fixture", tab: external, browser: nil, usePage: false))
            try await wait { ai.sessions[external]?.requestID == nil }
            let answer = ai.sessions[external]!.messages.last!
            precondition(ai.sessions[external]?.error == nil && answer.text == "Search verified" && answer.searchStatus == "搜索完成")
            precondition(answer.toolRounds?.first?.calls.first?.name == "web_search" && answer.searchSources?.count == 1)
            precondition(ai.sessions[external]!.markdown.contains("搜索来源") && ai.sessions[external]!.markdown.contains("https://search.fixture.invalid/source"))
            precondition(ai.send("Search external followup fixture", tab: external, browser: nil, usePage: false))
            try await wait { ai.sessions[external]?.requestID == nil }
            precondition(ai.sessions[external]?.error == nil)
            let alias = UUID()
            ai.setSearchChoice(.deepSeek, tab: alias)
            precondition(ai.send("Search external num fixture", tab: alias, browser: nil, usePage: false))
            try await wait { ai.sessions[alias]?.requestID == nil }
            let aliasAnswer = ai.sessions[alias]!.messages.last!
            precondition(ai.sessions[alias]?.error == nil && aliasAnswer.searchStatus == "搜索完成")
            precondition(aliasAnswer.toolRounds?.first?.calls.first?.arguments.contains("\"num\"") == true)
            precondition(aliasAnswer.toolRounds?.count == 1 && aliasAnswer.toolRounds?.first?.results.first?.contains("\"error\"") == false)
            let idle = UUID()
            precondition(ai.send("Search idle fixture", tab: idle, browser: nil, usePage: false))
            try await wait { ai.sessions[idle]?.requestID == nil }
            precondition(ai.sessions[idle]?.messages.last?.searchStatus == nil)
            precondition(!AISearchEvidence.isVisible(ai.sessions[idle]!.messages.last!))
            search.baseURL = baseURL + "/search-slow"
            precondition(ai.saveSearch(search))
            let cancelled = UUID()
            ai.setSearchChoice(.deepSeek, tab: cancelled)
            precondition(ai.send("Search external fixture", tab: cancelled, browser: nil, usePage: false))
            try await wait { ai.sessions[cancelled]?.messages.last?.searchStatus == "正在搜索…" }
            precondition(ai.sessions[cancelled]?.phase == .tools)
            ai.stop(cancelled)
            precondition(ai.sessions[cancelled]?.phase == nil && ai.sessions[cancelled]?.requestID == nil)
            precondition(ai.sessions[cancelled]?.messages.last?.searchStatus == "搜索已停止")
            let stopped = AIController(defaults: defaults, conversationDirectory: directory)
            precondition(stopped.sessions[cancelled]?.messages.last?.searchStatus == "搜索已停止" && stopped.sessions[cancelled]?.phase == nil)
            search.baseURL = baseURL + "/v1"
            precondition(ai.saveSearch(search))
            print("PASS: \(protocolValue.rawValue) search cancellation ends activity and persists stopped status")
        }
        model.apiProtocol = .responses; model.nativeSearch = .standard
        precondition(ai.save(model))
        let standard = UUID()
        precondition(ai.send("Search standard fixture", tab: standard, browser: nil, usePage: false))
        try await wait { ai.sessions[standard]?.requestID == nil }
        precondition(ai.sessions[standard]?.error == nil && ai.sessions[standard]?.messages.last?.searchSources?.count == 1)
        for (mode, paths) in [("sparse", ["source"]), ("multiple", ["source", "second", "citation"])] {
            let tab = UUID()
            precondition(ai.send("Search standard \(mode) fixture", tab: tab, browser: nil, usePage: false))
            try await wait { ai.sessions[tab]?.requestID == nil }
            let answer = ai.sessions[tab]!.messages.last!
            precondition(ai.sessions[tab]?.error == nil &&
                         Set(answer.searchSources!.map { $0.url.lastPathComponent }) == Set(paths))
        }
        model.apiProtocol = .openAI
        let originalAccount = model.account
        precondition(ai.save(model))
        let standardChat = UUID()
        precondition(ai.searchRoute(for: standardChat) == .native)
        for question in ["Search standard chat fixture", "Search standard chat followup fixture"] {
            precondition(ai.send(question, tab: standardChat, browser: nil, usePage: false))
            try await wait { ai.sessions[standardChat]?.requestID == nil }
            precondition(ai.sessions[standardChat]?.error == nil)
            precondition(ai.sessions[standardChat]?.messages.last?.toolRounds?.last?.apiProtocol == .responses ||
                         question.contains("followup"))
        }
        precondition(ai.configuration.apiProtocol == .openAI && ai.configuration.account == originalAccount)
        ai.setSearchChoice(.off, tab: standardChat)
        ai.setSearchSource(.native, tab: standardChat)
        precondition(!ai.searchEnabled(for: standardChat) && ai.searchChoice(for: standardChat) == .native &&
                     ai.searchRoute(for: standardChat) == .off)
        precondition(ai.send("Search standard chat off fixture", tab: standardChat, browser: nil, usePage: false))
        try await wait { ai.sessions[standardChat]?.requestID == nil }
        precondition(ai.sessions[standardChat]?.error == nil && ai.sessions[standardChat]?.messages.last?.searchStatus == nil)
        ai.setSearchEnabled(true, tab: standardChat)
        precondition(ai.searchRoute(for: standardChat) == .native && ai.searchChoice(for: standardChat) == .native)
        ai.setSearchEnabled(false, tab: standardChat)
        let nativeQueue = UUID()
        ai.setSearchChoice(.off, tab: nativeQueue)
        precondition(ai.send("queue first fixture", tab: nativeQueue, browser: nil, usePage: false))
        ai.setSearchChoice(.native, tab: nativeQueue)
        precondition(ai.send("Search standard chat fixture", tab: nativeQueue, browser: nil, usePage: false))
        precondition(ai.queuedMessages[nativeQueue]?.first?.searchChoice == .native)
        ai.setSearchChoice(.off, tab: nativeQueue)
        try await wait { ai.sessions[nativeQueue]?.requestID == nil && (ai.queuedMessages[nativeQueue] ?? []).isEmpty }
        precondition(ai.sessions[nativeQueue]?.error == nil && ai.sessions[nativeQueue]?.messages.last?.searchSources?.count == 1)
        model.apiProtocol = .openAI; model.nativeSearch = .none
        precondition(ai.save(model) && ai.searchRoute(for: UUID()) == .deepSeek)
        let queued = UUID()
        ai.setSearchChoice(.off, tab: queued)
        precondition(ai.send("queue first fixture", tab: queued, browser: nil, usePage: false))
        ai.setSearchChoice(.deepSeek, tab: queued)
        precondition(ai.send("Search external fixture", tab: queued, browser: nil, usePage: false))
        precondition(ai.queuedMessages[queued]?.first?.searchChoice == .deepSeek)
        ai.setSearchChoice(.off, tab: queued)
        try await wait { ai.sessions[queued]?.requestID == nil && (ai.queuedMessages[queued] ?? []).isEmpty }
        precondition(ai.sessions[queued]?.messages.last?.searchStatus == "搜索完成")
        search.baseURL = baseURL + "/search-error"
        precondition(ai.saveSearch(search))
        let failed = UUID()
        ai.setSearchChoice(.deepSeek, tab: failed)
        precondition(ai.send("Search external fixture", tab: failed, browser: nil, usePage: false))
        try await wait { ai.sessions[failed]?.requestID == nil }
        precondition(ai.sessions[failed]?.messages.last?.searchStatus?.contains("失败") == true)
        precondition(ai.sessions[failed]?.messages.last?.toolRounds?.first?.results.first?.contains("error") == true)
        ai.saveConversations()
        let restored = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(restored.searchConfiguration == search && restored.searchChoice(for: failed) == .deepSeek)
        precondition(!restored.searchEnabled(for: standardChat) && restored.searchChoice(for: standardChat) == .native &&
                     restored.searchRoute(for: standardChat) == .off)
        precondition(restored.sessions[standard]?.messages.last?.searchSources?.count == 1)
        precondition(restored.sessions[nativeQueue]?.messages.last?.toolRounds?.last?.apiProtocol == .responses)
        ai.removeSearchKey()
        precondition(ai.searchRoute(for: UUID()) == .off && ai.ready)
        ai.deleteSearch()
        precondition(defaults.data(forKey: "aiSearchProvider") == nil)
        let damaged = Data("damaged".utf8)
        defaults.set(damaged, forKey: "aiSearchProvider")
        let protected = AIController(defaults: defaults)
        precondition(!protected.saveSearch(search, key: "synthetic-search-key"))
        protected.deleteSearch()
        precondition(defaults.data(forKey: "aiSearchProvider") == damaged)
        print("PASS: native/standard search, direct HTTP in all protocols, independent keys, sources/usage/history/export, off/idle/error and frozen queue route")
    }
    static func run(baseURL: String) async throws {
        setbuf(stdout, nil)
        guard URL(string: baseURL)?.host == "127.0.0.1" else { throw PerchError("AI self-check requires a loopback fixture") }
        let suite = "dev.perch.ai.selftest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perch-ai-conversations-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ai = AIController(defaults: defaults, conversationDirectory: directory)
        var config = AIConfiguration(provider: .custom, baseURL: baseURL + "/v1", model: "fixture")
        let uiConfiguration = config
        precondition(config.endpoint?.path == "/v1/chat/completions")
        var remote = AIConfiguration(provider: .custom, baseURL: "http://192.0.2.1/v1", model: "fixture")
        precondition(remote.endpoint?.scheme == "http" && remote.modelsURL?.path == "/v1/models")
        remote.baseURL = "https://example.com/v1/chat/completions"
        precondition(remote.modelsURL?.absoluteString == "https://example.com/v1/models")
        let legacy = try JSONSerialization.data(withJSONObject: ["provider": AIProvider.custom.rawValue, "baseURL": baseURL + "/v1", "model": "fixture"])
        let migrated = try JSONDecoder().decode(AIConfiguration.self, from: legacy)
        precondition(migrated.keyEnvironment == nil && migrated.endpoint == config.endpoint && migrated.models == ["fixture"] && migrated.legacyAccount != nil && migrated.nativeSearch == .none)
        for value in ["https://user:pass@example.com", "https://example.com/v1?key=secret",
                      "https://example.com/#secret", "file:///tmp", "https:///"] {
            precondition(AIConfiguration(provider: .custom, baseURL: value, model: "fixture").endpoint == nil)
        }
        precondition(ai.save(config, key: "synthetic-key"))
        precondition(ai.ready && !String(data: defaults.data(forKey: "aiProviders")!, encoding: .utf8)!.contains("synthetic-key"))
        let catalog = try await ai.models(for: config, key: "")
        precondition(catalog == ["fixture", "alternate"])
        let variable = "PERCH_SYNTHETIC_AI_KEY"
        setenv(variable, "synthetic-key", 1)
        defer { unsetenv(variable) }
        let imported = try AIEnvironment.key(variable)
        precondition(imported == "synthetic-key")
        do { _ = try AIEnvironment.key("INVALID;NAME"); preconditionFailure() }
        catch { precondition(!error.localizedDescription.contains("synthetic-key")) }
        let original = config.id
        ai.addProvider(.custom)
        var other = ai.configuration
        other.baseURL = config.baseURL; other.model = "fixture"; other.models = ["fixture", "alternate"]
        precondition(ai.save(other) && !ai.ready && ai.providers.count == 3)
        precondition(ai.save(other, key: "synthetic-key"))
        ai.select(original)
        let chosen = UUID()
        ai.selections[chosen] = other.id; ai.selectedModels[chosen] = "alternate"
        precondition(ai.provider(for: chosen).id == other.id && ai.model(for: chosen) == "alternate" && ai.ready(for: chosen))
        ai.deleteProvider(other.id)
        precondition(ai.provider(for: chosen).id == original && ai.model(for: chosen) == "fixture")
        let restored = AIController(defaults: defaults)
        precondition(restored.providers.map(\.id) == ai.providers.map(\.id))
        var renamed = config
        renamed.providerID = "fixture-provider"
        precondition(ai.save(renamed) && ai.ready)
        var duplicate = AIConfiguration(provider: .custom, baseURL: config.baseURL, model: "fixture")
        duplicate.providerID = renamed.providerID
        precondition(!ai.save(duplicate))
        duplicate.providerID = "INVALID ID"
        precondition(!ai.save(duplicate))
        precondition(ai.save(config))
        print("PASS: HTTP connectivity, legacy configuration, independent Provider keys, model selection and persistence")
        try await searchChecks(baseURL: baseURL)
        try await fileChecks(baseURL: baseURL)
        let parsed = try AIStream.text("{\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}")
        let done = try AIStream.text("[DONE]")
        precondition(parsed == "你好" && done == nil)
        do { _ = try AIStream.text("{\"error\":{\"message\":\"synthetic-key\"}}"); preconditionFailure() }
        catch { precondition(!error.localizedDescription.contains("synthetic-key")) }
        var metadataStream = AIPageToolStream()
        for (name, args) in [("get_", "{\"reference_id\":"), ("page_html", "1,"), ("get_page_html", "\"offset\":0}") ] {
            let event = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["tool_calls": [
                ["index": 0, "id": "call-metadata", "function": ["name": name, "arguments": args]]
            ]]]]])
            try metadataStream.consume(String(data: event, encoding: .utf8)!, protocol: .openAI)
        }
        precondition(metadataStream.orderedCalls.first?.id == "call-metadata" &&
                     metadataStream.orderedCalls.first?.name == "get_page_html" &&
                     metadataStream.orderedCalls.first?.arguments == "{\"reference_id\":1,\"offset\":0}")
        let legacyRound = AIPageToolRound(calls: [AIPageToolCall(id: "call-oldcall-old",
            name: "get_page_htmlget_page_html", arguments: "{\"reference_id\":1}")],
            results: ["{\"error\":\"previous failure\"}"], text: "", apiProtocol: .openAI, output: Data("[]".utf8))
        for target in AIProtocol.allCases {
            var replay: [[String: Any]] = []
            try legacyRound.append(to: &replay, protocol: target)
            let json = String(data: try JSONSerialization.data(withJSONObject: replay), encoding: .utf8)!
            precondition(json.contains("call-old") && !json.contains("call-oldcall-old") &&
                         json.contains("get_page_html") && !json.contains("get_page_htmlget_page_html"))
        }
        print("PASS: repeated tool metadata is idempotent, split names/arguments remain incremental, and legacy duplicated call history replays in all protocols")
        let first = UUID(), second = UUID()
        ai.send("hello fixture", tab: first, browser: nil, usePage: false)
        try await wait { ai.sessions[first]?.requestID == nil }
        precondition(ai.sessions[first]?.messages.last?.text == "你好，Perch!" && ai.sessions[first]?.error == nil)
        precondition(ai.sessions[first]?.summaryTitle?.hasPrefix("合成标题") == true && ai.sessions[first]?.title.count == 20)
        let firstTitle = ai.sessions[first]?.summaryTitle
        ai.send("title should stay unchanged", tab: first, browser: nil, usePage: false)
        try await wait { ai.sessions[first]?.requestID == nil }
        precondition(ai.sessions[first]?.summaryTitle == firstTitle && ai.sessions[first]?.titleAttempted == true)
        for index in 0..<9 {
            ai.send("history retention fixture \(index)", tab: first, browser: nil, usePage: false)
            try await wait { ai.sessions[first]?.requestID == nil }
            precondition(ai.sessions[first]?.error == nil)
        }
        let titleFailure = UUID()
        ai.send("title failure fixture", tab: titleFailure, browser: nil, usePage: false)
        try await wait { ai.sessions[titleFailure]?.requestID == nil }
        precondition(ai.sessions[titleFailure]?.title == String("title failure fixture".prefix(20)) && ai.sessions[titleFailure]?.error == nil)
        let fallbackTitle = ai.sessions[titleFailure]?.title
        ai.send("follow up after title failure", tab: titleFailure, browser: nil, usePage: false)
        try await wait { ai.sessions[titleFailure]?.requestID == nil }
        precondition(ai.sessions[titleFailure]?.title == fallbackTitle)
        let canceledTitle = UUID()
        ai.send("title cancellation fixture", tab: canceledTitle, browser: nil, usePage: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        ai.stop(canceledTitle)
        ai.send("replacement title fixture", tab: canceledTitle, browser: nil, usePage: false)
        try await wait { ai.sessions[canceledTitle]?.requestID == nil }
        precondition(ai.sessions[canceledTitle]?.messages.count == 4 && ai.sessions[canceledTitle]?.error == nil)
        print("PASS: first-send title runs once, stays unchanged on follow-up, caps at 20 characters and falls back on failure")
        ai.send("other tab", tab: second, browser: nil, usePage: false)
        try await wait { ai.sessions[second]?.requestID == nil }
        precondition(ai.sessions[first]?.messages.first?.text == "hello fixture")
        precondition(ai.sessions[second]?.messages.first?.text == "other tab")
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("perch-fixture-\(UUID()).txt")
        try "Synthetic attachment: the verification code is FILE-4729.".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let file = try AIAttachment.read(fileURL)
        let attached = UUID()
        ai.send("Read attachment fixture", tab: attached, browser: nil, usePage: false, attachments: [file])
        try await wait { ai.sessions[attached]?.requestID == nil }
        precondition(ai.sessions[attached]?.error == nil && ai.sessions[attached]?.messages.first?.attachments.count == 1)
        ai.send("Remember attachment fixture", tab: attached, browser: nil, usePage: false)
        try await wait { ai.sessions[attached]?.requestID == nil }
        precondition(ai.sessions[attached]?.error == nil)
        try await keyDisplay(ai: ai, config: config)
        var anthropic = config
        anthropic.apiProtocol = .anthropic
        precondition(anthropic.endpoint?.path == "/v1/messages" && anthropic.modelsURL?.path == "/v1/models")
        anthropic.baseURL = config.baseURL + "/chat/completions"
        precondition(anthropic.endpoint?.path == "/v1/messages")
        anthropic.baseURL = config.baseURL
        precondition(ai.save(anthropic))
        let anthropicCatalog = try await ai.models(for: anthropic, key: "")
        precondition(anthropicCatalog == ["fixture", "alternate"])
        let anthropicTab = UUID()
        ai.send("Read attachment fixture", tab: anthropicTab, browser: nil, usePage: false, attachments: [file])
        try await wait { ai.sessions[anthropicTab]?.requestID == nil }
        precondition(ai.sessions[anthropicTab]?.error == nil && ai.sessions[anthropicTab]?.messages.last?.text == "你好，Perch!")
        precondition(ai.sessions[anthropicTab]?.summaryTitle?.hasPrefix("合成标题") == true)
        precondition(ai.save(config))
        print("PASS: text attachment round-trip and Anthropic authentication/request/stream")
        var responses = config
        responses.apiProtocol = .responses
        responses.baseURL = config.baseURL + "/chat/completions"
        precondition(responses.endpoint?.path == "/v1/responses" && responses.modelsURL?.path == "/v1/models")
        precondition(ai.save(responses))
        let responsesTab = UUID()
        ai.send("Read attachment fixture", tab: responsesTab, browser: nil, usePage: false, attachments: [file])
        try await wait { ai.sessions[responsesTab]?.requestID == nil }
        precondition(ai.sessions[responsesTab]?.error == nil && ai.sessions[responsesTab]?.messages.last?.text == "你好，Perch!")
        precondition(ai.sessions[responsesTab]?.summaryTitle?.hasPrefix("合成标题") == true)
        ai.send("Remember attachment fixture", tab: responsesTab, browser: nil, usePage: false)
        try await wait { ai.sessions[responsesTab]?.requestID == nil }
        precondition(ai.sessions[responsesTab]?.error == nil)
        do { _ = try AIStream.text("{\"type\":\"response.incomplete\"}", protocol: .responses); preconditionFailure() }
        catch { precondition(error.localizedDescription.contains("未完成")) }
        precondition(ai.save(config))
        print("PASS: Responses endpoint, instructions/input, file context, follow-up and completion/error events")

        let browser = Browser(url: URL(string: "about:blank")!, dataStore: .nonPersistent(), previewDefaults: defaults)
        let pageWindow = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        pageWindow.contentView = browser.webView
        pageWindow.orderFront(nil)
        defer { pageWindow.orderOut(nil) }
        browser.webView.loadHTMLString("""
        <html><head><title>AI synthetic page</title></head><body>
        <h1>Readable fixture</h1><p id="selected">Selected excerpt only</p><p>Other paragraph</p>
        <input type="password" value="PASSWORD_SECRET"><input value="FORM_SECRET">
        <textarea>TEXTAREA_SECRET</textarea><div contenteditable>EDIT_SECRET</div>
        <div hidden>HIDDEN_SECRET</div><div style="display:none">DISPLAY_SECRET</div>
        <a href="/relative?page=2&amp;sort=new" onclick="alert('EVENT_SECRET')" data-secret="DATA_SECRET">Relative link</a>
        <a href="https://user:AUTH_SECRET@target.invalid/item">Credential link</a>
        <a href="javascript:alert('URL_SECRET')">Unsafe link</a>
        <a hidden href="https://hidden.invalid/HIDDEN_URL_SECRET">Hidden link</a>
        <img src="/assets/chart.png" srcset="/assets/small.png 1x, /assets/large.png 2x" alt="Chart">
        <script>const secret = 'SCRIPT_SECRET';</script></body></html>
        """, baseURL: URL(string: "https://fixture.invalid/article?token=QUERY_SECRET#FRAGMENT_SECRET"))
        try await wait { browser.webView.title == "AI synthetic page" && !browser.webView.isLoading }
        _ = try await browser.webView.evaluateJavaScript("""
        const dynamic = document.createElement('a');
        dynamic.href = '/dynamic?from=rendered'; dynamic.textContent = 'Rendered link';
        document.body.appendChild(dynamic); true;
        """)
        let (body, source) = try await AIController.context(browser)
        guard body.contains("Readable fixture") && source == "当前网页" else { throw PerchError("Rendered text fixture failed: \(source)") }
        for secret in ["PASSWORD_SECRET", "FORM_SECRET", "TEXTAREA_SECRET", "EDIT_SECRET",
                       "HIDDEN_SECRET", "DISPLAY_SECRET", "SCRIPT_SECRET", "QUERY_SECRET", "FRAGMENT_SECRET",
                       "EVENT_SECRET", "DATA_SECRET", "AUTH_SECRET", "URL_SECRET", "HIDDEN_URL_SECRET"] {
            guard !body.contains(secret) else { throw PerchError("Default page text leaked synthetic field: \(secret)") }
        }
        precondition(!body.contains("<h1>") && !body.contains("https://fixture.invalid/dynamic?from=rendered"),
                     "Default references must remain text-only")
        let rendered = try await AIController.htmlContext(browser, expectedURL: browser.webView.url!)
        let renderedJSON = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as! [String: Any]
        guard (renderedJSON["html"] as? String)?.contains("<h1>Readable fixture</h1>") == true else { throw PerchError("Rendered HTML fixture missing heading") }
        for secret in ["PASSWORD_SECRET", "FORM_SECRET", "TEXTAREA_SECRET", "EDIT_SECRET", "HIDDEN_SECRET",
                       "DISPLAY_SECRET", "SCRIPT_SECRET", "EVENT_SECRET", "DATA_SECRET", "AUTH_SECRET", "URL_SECRET", "HIDDEN_URL_SECRET"] {
            guard !rendered.contains(secret) else { throw PerchError("HTML leaked synthetic field: \(secret)") }
        }
        for url in ["https://fixture.invalid/relative?page=2&sort=new", "https://target.invalid/item",
                    "https://fixture.invalid/assets/chart.png", "https://fixture.invalid/assets/small.png",
                    "https://fixture.invalid/assets/large.png", "https://fixture.invalid/dynamic?from=rendered"] {
            guard (renderedJSON["urls"] as! [String]).contains(url) else { throw PerchError("HTML fixture missing URL: \(url)") }
        }
        _ = try await browser.webView.callAsyncJavaScript("""
        const range = document.createRange(); range.selectNodeContents(document.getElementById('selected'));
        const s = getSelection(); s.removeAllRanges(); s.addRange(range); return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        let (selection, selectedSource) = try await AIController.context(browser)
        precondition(selection.contains("Selected excerpt only") && !selection.contains("Other paragraph") && selectedSource == "选中文字")
        let pageTab = UUID()
        ai.send("summarize fixture", tab: pageTab, browser: browser, usePage: true, origin: .web)
        try await wait { ai.sessions[pageTab]?.requestID == nil }
        precondition(ai.sessions[pageTab]?.error == nil && ai.sessions[pageTab]?.messages.first?.source == "选中文字")
        precondition(ai.sessions[pageTab]?.messages.first?.sentContent?.contains("<page_tool_result>") == false)
        for apiProtocol in AIProtocol.allCases {
            var toolConfig = config
            toolConfig.apiProtocol = apiProtocol
            precondition(ai.save(toolConfig))
            let continued = UUID()
            ai.send("summarize fixture", tab: continued, browser: browser, usePage: true)
            try await wait { ai.sessions[continued]?.requestID == nil }
            ai.send("HTML tool fixture", tab: continued, browser: nil, usePage: false, availablePages: [browser])
            try await wait { ai.sessions[continued]?.requestID == nil }
            guard ai.sessions[continued]?.error == nil && ai.sessions[continued]?.messages.last?.text == "HTML tool verified" else {
                throw PerchError("Previously referenced HTML tool unavailable on follow-up: \(apiProtocol.rawValue)")
            }
            ai.send("HTML followup fixture", tab: continued, browser: nil, usePage: false, availablePages: [browser])
            try await wait { ai.sessions[continued]?.requestID == nil }
            precondition(ai.sessions[continued]?.error == nil)
            ai.saveConversations()
            for targetProtocol in AIProtocol.allCases {
                let restoredTools = AIController(defaults: defaults, conversationDirectory: directory)
                var targetConfig = toolConfig
                targetConfig.apiProtocol = targetProtocol
                precondition(restoredTools.save(targetConfig, key: "synthetic-key"))
                let before = restoredTools.sessions[continued]!.messages.count
                precondition(restoredTools.send("HTML followup fixture", tab: continued, browser: nil, usePage: false, availablePages: [browser]))
                try await wait { restoredTools.sessions[continued]?.requestID == nil }
                precondition(restoredTools.sessions[continued]?.error == nil &&
                             restoredTools.sessions[continued]?.messages.count == before + 2 &&
                             restoredTools.sessions[continued]?.pageReferences?.count == 1)
            }
            for question in ["HTML tool fixture", "HTML bad tool fixture"] {
                let toolTab = UUID()
                ai.send(question, tab: toolTab, browser: browser, usePage: true)
                try await wait { ai.sessions[toolTab]?.requestID == nil }
                guard ai.sessions[toolTab]?.error == nil && ai.sessions[toolTab]?.messages.last?.text == "HTML tool verified" else {
                    throw PerchError("HTML tool \(apiProtocol.rawValue) / \(question): \(ai.sessions[toolTab]?.error ?? ai.sessions[toolTab]?.messages.last?.text ?? "missing")")
                }
                let result = ai.sessions[toolTab]?.messages.last?.toolRounds?.first?.results.first ?? ""
                guard !result.isEmpty,
                      question.contains("bad") ? !result.contains("<h1>") : result.contains("<h1>Readable fixture</h1>") else {
                    throw PerchError("Tool history did not preserve its HTML result: \(apiProtocol.rawValue)")
                }
                if !question.contains("bad") {
                    ai.send("HTML followup fixture", tab: toolTab, browser: nil, usePage: false)
                    try await wait { ai.sessions[toolTab]?.requestID == nil }
                    guard ai.sessions[toolTab]?.error == nil && ai.sessions[toolTab]?.messages.last?.text == "你好，Perch!" else {
                        throw PerchError("HTML follow-up failed: \(apiProtocol.rawValue) / \(ai.sessions[toolTab]?.error ?? "missing text")")
                    }
                }
            }
        }
        precondition(ai.save(config))
        print("PASS: optional HTML tools stream and return results in all three protocols; invalid reference returns an error without HTML")
        let secondPage = Browser(url: URL(string: "about:blank")!, dataStore: .nonPersistent())
        secondPage.webView.loadHTMLString("<html><title>Second page</title><body>SECOND-PAGE-7391</body></html>",
                                         baseURL: URL(string: "https://second.invalid"))
        try await wait { secondPage.webView.title == "Second page" && !secondPage.webView.isLoading }
        let multi = UUID()
        ai.send("multiple pages fixture", tab: multi, browser: nil, usePage: false, pages: [browser, secondPage])
        try await wait { ai.sessions[multi]?.requestID == nil }
        precondition(ai.sessions[multi]?.error == nil && ai.sessions[multi]?.messages.first?.references.count == 2)
        precondition(ai.sessions[multi]?.messages.first?.sentContent?.contains("SECOND-PAGE-7391") == true)
        ai.saveConversations()
        let reloaded = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(reloaded.sessions[multi]?.messages.first?.references.count == 2)
        precondition(reloaded.sessions[attached]?.messages.first?.attachments.first?.data == file.data)
        precondition(reloaded.sessions[multi]?.requestID == nil)
        precondition(reloaded.sessions[multi]?.summaryTitle == ai.sessions[multi]?.summaryTitle)
        precondition(reloaded.sessions[multi]?.messages.first?.sentContent?.contains("https://fixture.invalid/dynamic?from=rendered") == false)
        precondition(reloaded.sessions[pageTab]?.origin == .web && reloaded.sessions[attached]?.origin == .chat)
        let noReferenceTab = UUID()
        let sidebarPage = URL(string: "https://example.com/sidebar?private=value#section")!
        precondition(ai.send("sidebar without page reference", tab: noReferenceTab, browser: nil, usePage: false,
                             origin: .web, sidebarURL: sidebarPage))
        try await wait { ai.sessions[noReferenceTab]?.requestID == nil }
        let noReferenceID = ai.sessions[noReferenceTab]!.id
        ai.clear(noReferenceTab)
        let sourceReload = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(sourceReload.conversations(for: sidebarPage).map(\.id) == [noReferenceID])
        precondition(sourceReload.conversations[noReferenceID]?.webPageURLs == [URL(string: "https://example.com/sidebar")!])
        print("PASS: sidebar history association persists after removing the page reference and closing its tab")
        ai.send("continue web conversation in full Chat", tab: pageTab, browser: nil, usePage: false)
        try await wait { ai.sessions[pageTab]?.requestID == nil }
        precondition(ai.sessions[pageTab]?.origin == .web)
        var legacyConversation = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ai.sessions[pageTab]!)) as! [String: Any]
        legacyConversation.removeValue(forKey: "origin")
        legacyConversation.removeValue(forKey: "summaryTitle")
        let legacySession = try JSONDecoder().decode(AISession.self, from: JSONSerialization.data(withJSONObject: legacyConversation))
        precondition(legacySession.origin == nil && legacySession.summaryTitle == nil && legacySession.messages.count == ai.sessions[pageTab]?.messages.count)
        let legacyArchiveURL = directory.appendingPathComponent("conversations.json")
        try JSONEncoder().encode(AIConversationArchive(conversations: [legacySession.id: legacySession], tabs: [pageTab: legacySession.id])).write(to: legacyArchiveURL)
        let legacyController = AIController(defaults: defaults, conversationDirectory: directory)
        legacyController.classifyWebConversations(owners: [pageTab])
        precondition(legacyController.conversations[legacySession.id]?.origin == .web)
        ai.saveConversations()
        print("PASS: persisted Chat/web folders, legacy conversation migration and preserved web origin in full Chat")
        let archived = ai.sessions[multi]!.id
        ai.clear(multi)
        precondition(ai.sessions[multi] == nil && ai.conversations[archived] != nil)
        ai.resumeConversation(archived, tab: multi)
        precondition(ai.sessions[multi]?.messages.last?.text == "你好，Perch!")
        let attachmentConversation = ai.sessions[attached]!.id
        let roundFork = ai.forkConversation(attachmentConversation, through: ai.sessions[attached]!.messages[0].id)!
        precondition(ai.conversations[roundFork]?.messages.count == 2 && ai.sessions[attached]?.messages.count == 4)
        precondition(ai.conversations[roundFork]?.messages.last?.text == ai.sessions[attached]?.messages[1].text)
        ai.archiveConversations([roundFork])
        let archiveReload = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(archiveReload.archivedConversations.contains { $0.id == roundFork })
        ai.deleteConversations([roundFork])
        ai.drafts[attached] = "Prior unsent draft"
        ai.draftReferences[attached] = [second]
        let beforeEdit = try Data(contentsOf: directory.appendingPathComponent("conversations.json"))
        let secondQuestion = ai.sessions[attached]!.messages[2]
        precondition(ai.editMessage(secondQuestion.id, tab: attached)?.text == secondQuestion.text)
        precondition(ai.sessions[attached]?.messages.count == 4 && ai.drafts[attached] == secondQuestion.text)
        let firstQuestion = ai.sessions[attached]!.messages[0]
        precondition(ai.editMessage(firstQuestion.id, tab: attached)?.attachments.first?.data == file.data)
        precondition(ai.sessions[attached]?.messages.count == 4 && ai.draftFiles[attached]?.first?.data == file.data)
        let editedReload = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(editedReload.conversations[attachmentConversation]?.messages.count == 4)
        precondition(editedReload.sessions[attached]?.id == attachmentConversation)
        let unchangedEditData = try Data(contentsOf: directory.appendingPathComponent("conversations.json"))
        precondition(unchangedEditData == beforeEdit)
        precondition(!ai.send("", tab: attached, browser: nil, usePage: false))
        precondition(ai.pendingEdits[attached] != nil && ai.sessions[attached]?.messages.count == 4)
        ai.cancelEditing(attached)
        precondition(ai.drafts[attached] == "Prior unsent draft" && ai.draftReferences[attached] == [second])
        precondition(ai.sessions[attached]?.messages.count == 4 && ai.pendingEdits[attached] == nil)
        let originalIDs = ai.sessions[attached]!.messages.map(\.id)
        let originalTitle = ai.sessions[attached]!.summaryTitle
        let beforeFork = try Data(contentsOf: directory.appendingPathComponent("conversations.json"))
        _ = ai.editMessage(firstQuestion.id, tab: attached, fork: true)
        precondition(ai.pendingEdits[attached]?.fork == true && ai.draftFiles[attached]?.first?.data == file.data)
        precondition(!ai.send("", tab: attached, browser: nil, usePage: false))
        let pendingForkData = try Data(contentsOf: directory.appendingPathComponent("conversations.json"))
        precondition(pendingForkData == beforeFork && ai.sessions[attached]!.messages.map(\.id) == originalIDs)
        ai.cancelEditing(attached)
        precondition(ai.drafts[attached] == "Prior unsent draft" && ai.draftReferences[attached] == [second])
        _ = ai.editMessage(secondQuestion.id, tab: attached, fork: true)
        precondition(ai.send("Pending fork fixture", tab: attached, browser: nil, usePage: false))
        let pendingForkID = ai.sessions[attached]!.id
        precondition(pendingForkID != attachmentConversation && ai.sessions[attached]!.messages.count == 4)
        precondition(ai.sessions[attached]!.messages[0].id != originalIDs[0])
        precondition(ai.conversations[attachmentConversation]!.messages.map(\.id) == originalIDs)
        try await wait { ai.sessions[attached]?.requestID == nil }
        precondition(ai.sessions[attached]?.error == nil && ai.conversations[attachmentConversation]?.summaryTitle == originalTitle)
        let forkReload = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(forkReload.conversations[attachmentConversation]!.messages.map(\.id) == originalIDs)
        precondition(forkReload.conversations[pendingForkID]?.messages[2].text == "Pending fork fixture")
        ai.resumeConversation(attachmentConversation, tab: attached)
        ai.archiveConversations([pendingForkID]); ai.deleteConversations([pendingForkID])
        ai.drafts[attached] = "Prior unsent draft"; ai.draftReferences[attached] = [second]
        print("PASS: pending Fork leaves original unchanged until accepted send, cancel restores draft, independent branch persists original history")
        _ = ai.editMessage(firstQuestion.id, tab: attached)
        ai.referenceClosed(second, reference: AIPageReference(title: "Closed prior draft page", url: URL(string: "https://closed.invalid/")))
        ai.cancelEditing(attached)
        precondition(ai.draftReferences[attached]?.isEmpty == true && ai.draftClosedReferences[attached]?.last?.title == "Closed prior draft page")
        _ = ai.editMessage(firstQuestion.id, tab: attached)
        precondition(ai.send("Replacement attachment fixture", tab: attached, browser: nil, usePage: false, attachments: [file]))
        precondition(ai.sessions[attached]?.messages.count == 2 && ai.pendingEdits[attached] == nil)
        try await wait { ai.sessions[attached]?.requestID == nil }
        precondition(ai.sessions[attached]?.messages.first?.text == "Replacement attachment fixture")
        let forked = ai.forkConversation(attachmentConversation)!
        let forkSession = ai.conversations[forked]!
        precondition(forkSession.id != attachmentConversation && forkSession.messages.map(\.id) != ai.sessions[attached]!.messages.map(\.id))
        precondition(forkSession.messages.first?.attachments.first?.data == file.data && forkSession.title.hasSuffix("副本"))
        ai.resumeConversation(forked, tab: UUID())
        ai.deleteConversations([forked])
        precondition(ai.conversations[forked] != nil, "Active conversations must be archived before permanent deletion")
        ai.archiveConversations([forked, attachmentConversation])
        precondition(ai.archivedConversations.contains { $0.id == attachmentConversation })
        precondition(!ai.send("Archived cannot send", tab: attached, browser: nil, usePage: false))
        ai.restoreConversations([attachmentConversation])
        precondition(ai.activeConversations.contains { $0.id == attachmentConversation })
        ai.archiveConversations([attachmentConversation])
        ai.deleteConversations([forked, attachmentConversation])
        let deletedReload = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(deletedReload.conversations[forked] == nil && deletedReload.conversations[attachmentConversation] == nil)
        precondition(deletedReload.sessions.values.allSatisfy { $0.id != forked && $0.id != attachmentConversation })
        precondition(ai.editMessage(UUID(), tab: attached) == nil)
        let exportFixture = AISession(messages: [
            AIMessage(role: "user", text: "Export fixture", attachments: [
                AIAttachment(name: "code.txt", data: Data(), text: "```\ncode\n```", mime: nil),
                AIAttachment(name: "image.jpg", data: Data([1, 2, 3]), text: nil, mime: "image/jpeg")
            ], references: [AIPageReference(title: "Fixture [page]", url: URL(string: "https://fixture.invalid/"))]),
            AIMessage(role: "assistant", text: "```mermaid\nflowchart LR\nA --> B\n```", providerName: "Fixture · model")
        ])
        let exportURL = directory.appendingPathComponent("chat-export.md")
        try exportFixture.markdown.write(to: exportURL, atomically: true, encoding: .utf8)
        let exported = try String(contentsOf: exportURL)
        precondition(exported.contains("## 你") && exported.contains("## Fixture · model") &&
                     exported.contains("```mermaid\nflowchart LR") && exported.contains("````text") &&
                     exported.contains("data:image/jpeg;base64,AQID") && exported.contains("Fixture \\[page\\]"))
        print("PASS: edit preserves history until accepted send, cancel restores draft, fork isolates IDs, bulk delete persists and Markdown exports")
        let archiveURL = directory.appendingPathComponent("conversations.json")
        let originalData = try Data(contentsOf: archiveURL)
        precondition(!String(data: originalData, encoding: .utf8)!.contains("synthetic-key"))
        try Data("broken fixture".utf8).write(to: archiveURL)
        let brokenArchive = AIController(defaults: defaults, conversationDirectory: directory)
        brokenArchive.saveConversations()
        let preserved = try Data(contentsOf: archiveURL)
        precondition(preserved == Data("broken fixture".utf8) && brokenArchive.storageError != nil)
        try originalData.write(to: archiveURL)
        let navigation = Store(defaults: defaults)
        navigation.newTab(address: "about:blank")
        let owner = navigation.chatOwner
        navigation.ai.drafts[owner] = "Shared draft"
        navigation.openChat()
        precondition(navigation.isChatPage && navigation.chatOwner == owner && navigation.ai.drafts[navigation.chatOwner] == "Shared draft")
        let chatTab = navigation.tabs.last!
        let savedTab = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(chatTab))
        precondition(savedTab.chatOwner == owner)
        navigation.close(owner)
        precondition(navigation.isChatPage && navigation.chatOwner == owner)
        let recoveredNavigation = Store(defaults: defaults)
        precondition(recoveredNavigation.isChatPage && recoveredNavigation.chatOwner == owner)
        navigation.newTab()
        let count = navigation.tabs.count
        navigation.openChat()
        precondition(navigation.isChatPage && navigation.tabs.count == count)
        print("PASS: multiple explicit page references, disk conversation/attachment restore, archive recovery protection and shared full-page chat")
        _ = try await browser.webView.callAsyncJavaScript("""
        getSelection().removeAllRanges(); document.body.innerHTML = '<p>' + 'x'.repeat(14000) + '</p>'; return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        let (largeBody, largeSource) = try await AIController.context(browser)
        precondition(largeSource.contains("已截断") && largeBody.count < 12200)
        _ = try await browser.webView.evaluateJavaScript("""
        document.body.innerHTML = '<p>' + 'x'.repeat(70000) + '</p><a href="/after-html-limit">Tail link</a>';
        """)
        var snapshots: [Int: [String: Any]] = [:]
        let toolReferences = [(browser, browser.webView.url!)]
        let firstChunk = try await AIController.pageToolResult(AIPageToolCall(id: "1", name: "get_page_html", arguments: "{\"reference_id\":1}"), references: toolReferences, snapshots: &snapshots)
        let firstJSON = try JSONSerialization.jsonObject(with: Data(firstChunk.utf8)) as! [String: Any]
        guard (firstJSON["html"] as? String)?.utf16.count == 64000 && firstJSON["next_offset"] as? Int == 64000 else {
            throw PerchError("First HTML chunk invalid: \(firstJSON["error"] ?? firstJSON["next_offset"] ?? "missing")")
        }
        _ = try await browser.webView.evaluateJavaScript("document.body.innerHTML = '<p>Modified after snapshot</p>'")
        let secondChunk = try await AIController.pageToolResult(AIPageToolCall(id: "2", name: "get_page_html", arguments: "{\"reference_id\":1,\"offset\":64000}"), references: toolReferences, snapshots: &snapshots)
        let secondJSON = try JSONSerialization.jsonObject(with: Data(secondChunk.utf8)) as! [String: Any]
        guard (secondJSON["html"] as? String)?.contains("Tail link") == true && secondJSON["next_offset"] is NSNull,
              !secondChunk.contains("Modified after snapshot") else { throw PerchError("Second HTML chunk did not reuse its snapshot") }
        let stableIDResult = try await AIController.pageToolResult(
            AIPageToolCall(id: "stable", name: "get_page_html", arguments: "{\"reference_id\":\"7\",\"offset\":\"0\"}"),
            references: toolReferences, referenceIDs: [7], snapshots: &snapshots)
        guard stableIDResult.contains("\"reference_id\":7") && !stableIDResult.contains("\"error\"") else {
            throw PerchError("Non-contiguous stable reference ID failed")
        }
        for args in ["{}", "{\"reference_id\":true}", "{\"reference_id\":1,\"offset\":-1}", "{\"reference_id\":1,\"offset\":9999999}", "{\"reference_id\":1,\"url\":\"https://other.invalid\"}"] {
            let result = try await AIController.pageToolResult(AIPageToolCall(id: "3", name: "get_page_html", arguments: args), references: toolReferences, snapshots: &snapshots)
            guard result.contains("\"error\"") && !result.contains("\"html\"") else { throw PerchError("Invalid tool argument accepted: \(args)") }
        }
        let emptyResult = try await AIController.pageToolResult(AIPageToolCall(id: "4", name: "get_page_html", arguments: "{\"reference_id\":1}"), references: [], snapshots: &snapshots)
        guard emptyResult.contains("\"error\"") else { throw PerchError("Tool accepted a page without a reference") }
        let changedResult = try await AIController.pageToolResult(AIPageToolCall(id: "5", name: "get_page_html", arguments: "{\"reference_id\":1}"), references: [(browser, URL(string: "https://changed.invalid")!)], snapshots: &snapshots)
        guard changedResult.contains("\"error\"") && !changedResult.contains("\"html\"") else { throw PerchError("Tool accepted a changed reference URL") }
        _ = try await browser.webView.evaluateJavaScript("""
        document.body.innerHTML = '<p>' + 'x'.repeat(2100000) + '</p><a href="/after-html-limit">Tail link</a>';
        """)
        let largeHTML = try await AIController.htmlContext(browser, expectedURL: browser.webView.url!)
        let largeJSON = try JSONSerialization.jsonObject(with: Data(largeHTML.utf8)) as! [String: Any]
        guard largeJSON["htmlTruncated"] as? Bool == true else { throw PerchError("Oversized HTML missing truncation flag") }
        guard (largeJSON["urls"] as? [String])?.contains("https://fixture.invalid/after-html-limit") == true else {
            throw PerchError("URL collection stopped at HTML truncation")
        }
        _ = try await browser.webView.evaluateJavaScript("""
        document.body.innerHTML = '<img src="/image-only.png" alt="">';
        """)
        let imageOnly = try await AIController.htmlContext(browser, expectedURL: browser.webView.url!)
        guard imageOnly.contains("https://fixture.invalid/image-only.png") else { throw PerchError("Image-only page missing its resource URL") }
        print("PASS: live rendered HTML, dynamic/relative/resource URLs, selected text priority, secret exclusions and URLs beyond HTML truncation")
        print("PASS: AI page/selection extraction, secret exclusions, context truncation, streamed Unicode and tab isolation")

        config.baseURL = baseURL + "/slow"
        precondition(ai.save(config) && ai.ready)
        precondition(ai.save(config, key: "synthetic-key"))
        let slowTab = UUID()
        ai.send("stop fixture", tab: slowTab, browser: nil, usePage: false)
        try await wait { ai.sessions[slowTab]?.messages.last?.text.isEmpty == false }
        ai.stop(slowTab)
        let stoppedText = ai.sessions[slowTab]?.messages.last?.text
        ai.send("restart fixture", tab: slowTab, browser: nil, usePage: false)
        try await wait { ai.sessions[slowTab]?.requestID == nil }
        precondition(ai.sessions[slowTab]?.messages[1].text == stoppedText)
        precondition(ai.sessions[slowTab]?.messages.last?.text == "开始结束")
        let queuedTab = UUID()
        precondition(ai.send("queue start fixture", tab: queuedTab, browser: nil, usePage: false))
        try await wait { ai.sessions[queuedTab]?.messages.last?.text.isEmpty == false }
        precondition(ai.send("queued fixture one", tab: queuedTab, browser: nil, usePage: false))
        precondition(ai.send("queued fixture two", tab: queuedTab, browser: nil, usePage: false))
        precondition(ai.queuedMessages[queuedTab]?.count == 2 && ai.sessions[queuedTab]?.messages.count == 2)
        try await wait { ai.sessions[queuedTab]?.requestID == nil && (ai.queuedMessages[queuedTab] ?? []).isEmpty }
        precondition(ai.sessions[queuedTab]?.error == nil)
        precondition(ai.sessions[queuedTab]?.messages.filter { $0.role == "user" }.map(\.text) ==
                     ["queue start fixture", "queued fixture one", "queued fixture two"])
        precondition(ai.sessions[queuedTab]?.messages.filter { $0.role == "assistant" }.allSatisfy { $0.text == "开始结束" } == true)
        let pausedTab = UUID()
        ai.send("pause queue fixture", tab: pausedTab, browser: nil, usePage: false)
        try await wait { ai.sessions[pausedTab]?.messages.last?.text.isEmpty == false }
        ai.send("resume queue fixture", tab: pausedTab, browser: nil, usePage: false, attachments: [file])
        ai.send("removed queue fixture", tab: pausedTab, browser: nil, usePage: false)
        let removed = ai.queuedMessages[pausedTab]!.last!.id
        ai.removeQueuedMessage(removed, tab: pausedTab)
        ai.stop(pausedTab)
        precondition(ai.pausedQueues.contains(pausedTab) && ai.queuedMessages[pausedTab]?.count == 1)
        precondition(ai.queuedMessages[pausedTab]?.first?.attachments.first?.id == file.id)
        ai.resumeQueue(pausedTab)
        try await wait { ai.sessions[pausedTab]?.requestID == nil && (ai.queuedMessages[pausedTab] ?? []).isEmpty }
        precondition(ai.sessions[pausedTab]?.messages.count == 4 && ai.sessions[pausedTab]?.error == nil)
        let clearedTab = UUID()
        ai.send("clear queue fixture", tab: clearedTab, browser: nil, usePage: false)
        ai.send("never sent fixture", tab: clearedTab, browser: nil, usePage: false)
        ai.clear(clearedTab)
        precondition(ai.queuedMessages[clearedTab] == nil && ai.sessions[clearedTab] == nil)
        print("PASS: queued sends preserve FIFO and completed context; stop pauses, resume retains attachments, removal and new conversation clear pending work")
        let editingStream = UUID()
        ai.send("edit streaming fixture", tab: editingStream, browser: nil, usePage: false)
        try await wait { ai.sessions[editingStream]?.messages.last?.text.isEmpty == false }
        let editingQuestion = ai.sessions[editingStream]!.messages[0]
        _ = ai.editMessage(editingQuestion.id, tab: editingStream)
        precondition(ai.sessions[editingStream]?.requestID != nil && ai.sessions[editingStream]?.messages.count == 2)
        ai.cancelEditing(editingStream)
        precondition(ai.sessions[editingStream]?.requestID != nil && ai.pendingEdits[editingStream] == nil)
        _ = ai.editMessage(editingQuestion.id, tab: editingStream)
        ai.send("revised streaming fixture", tab: editingStream, browser: nil, usePage: false)
        try await wait { ai.sessions[editingStream]?.requestID == nil }
        precondition(ai.sessions[editingStream]?.messages.count == 2 && ai.sessions[editingStream]?.messages.last?.text == "开始结束")
        print("PASS: editing a streaming round cancels the old request and isolates the replacement reply")
        config.baseURL = baseURL + "/broken"
        precondition(ai.save(config, key: "synthetic-key"))
        let failedQueue = UUID()
        ai.send("queue failure fixture", tab: failedQueue, browser: nil, usePage: false)
        ai.send("queue recovery fixture", tab: failedQueue, browser: nil, usePage: false)
        try await wait { ai.sessions[failedQueue]?.requestID == nil }
        precondition(ai.pausedQueues.contains(failedQueue) && ai.queuedMessages[failedQueue]?.count == 1)
        config.baseURL = baseURL + "/v1"
        precondition(ai.save(config, key: "synthetic-key"))
        ai.resumeQueue(failedQueue)
        try await wait { ai.sessions[failedQueue]?.requestID == nil && (ai.queuedMessages[failedQueue] ?? []).isEmpty }
        precondition(ai.sessions[failedQueue]?.error == nil && ai.sessions[failedQueue]?.messages.last?.text == "你好，Perch!")
        print("PASS: failed generation pauses the queue, and corrected provider configuration resumes it")
        for (path, expected) in [("unauthorized", "认证失败"), ("rate", "请求受限"), ("redirect", "重定向"),
                                  ("broken", "连接中断"), ("invalid", "无效"), ("json", "未返回流式响应")] {
            config.baseURL = baseURL + "/" + path
            precondition(ai.save(config, key: "synthetic-key"))
            let id = UUID()
            ai.send("failure fixture", tab: id, browser: nil, usePage: false)
            try await wait { ai.sessions[id]?.requestID == nil }
            precondition(ai.sessions[id]?.error?.contains(expected) == true)
            precondition(ai.sessions[id]?.error?.contains("synthetic-key") == false)
        }
        ai.retainTabs([first])
        precondition(ai.sessions.count == 1 && ai.sessions[first] != nil)
        ai.removeKey(); precondition(!ai.ready)
        let damaged = Data("damaged".utf8)
        defaults.set(damaged, forKey: "aiProviders")
        let protected = AIController(defaults: defaults)
        precondition(!protected.save(config, key: "synthetic-key"))
        precondition(defaults.data(forKey: "aiProviders") == damaged)
        protected.resetConfiguration()
        precondition(protected.save(config, key: "synthetic-key"))
        print("PASS: AI cancellation/restart isolation, Provider-key isolation, HTTP/stream errors, key removal and damaged-config preservation")
        try await chatUI(config: uiConfiguration)
        try await markdown()
    }
    static func markdown() async throws {
        let coordinator = AIMarkdownView.Coordinator(height: .constant(100))
        let web = AIMarkdownView.webView(handler: coordinator)
        web.navigationDelegate = coordinator
        let window = Panel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); web.configuration.userContentController.removeScriptMessageHandler(forName: "markdown") }
        try await wait { coordinator.loaded }
        _ = try await web.callAsyncJavaScript("renderMarkdown(text)", arguments: ["text": """
        ## Markdown fixture
        **Bold** and [link](https://example.com)

        > A reference

        ```swift
        let value = 42
        ```

        | A | B |
        |---|---|
        | 1 | 2 |

        <script>window.unwanted = true</script>
        """], in: nil, contentWorld: .page)
        let result = try await web.callAsyncJavaScript("""
        return !!document.querySelector('h2') && !!document.querySelector('strong') &&
          !!document.querySelector('blockquote') && document.querySelectorAll('pre button').length === 2 &&
          document.querySelectorAll('pre button')[1].textContent === '另存为' &&
          !!document.querySelector('table td') && !window.unwanted &&
          document.querySelector('#content').getBoundingClientRect().height > 100;
        """, arguments: [:], in: nil, contentWorld: .page)
        precondition(result as? Bool == true)
        print("PASS: bundled Markdown heading, bold, citation, code copy, table, HTML sanitization and layout")
        let initialScripts = try await web.callAsyncJavaScript("return {bytes:Array.from(document.scripts).reduce((n,s)=>n+s.textContent.length,0),loaded:!!window.mermaid}", arguments: [:], in: nil, contentWorld: .page) as! [String: Any]
        precondition(initialScripts["loaded"] as? Bool == false && (initialScripts["bytes"] as! Int) < 200000)
        AIMarkdownView.render("""
        ```mermaid
        flowchart LR
        A[开始] --> B[完成]
        ```
        ```mermaid
        sequenceDiagram
        Alice->>Bob: Hello
        Bob-->>Alice: Hi
        ```
        """, web: web)
        try await wait { (web as! AIMarkdownWebView).mermaidLoaded }
        let diagrams = try await web.callAsyncJavaScript("""
        return document.querySelectorAll('#content .mermaid-diagram svg').length === 2 &&
          document.querySelector('#content').textContent.includes('开始') &&
          !document.querySelector('#content foreignObject') &&
          document.querySelector('.mermaid-diagram svg').getBoundingClientRect().width > 0;
        """, arguments: [:], in: nil, contentWorld: .page)
        precondition(diagrams as? Bool == true, "Mermaid flowchart and sequence must render locally under the CSP")
        print("PASS: local Mermaid rendering before inline viewport checks"); fflush(stdout)
        _ = try await web.evaluateJavaScript("""
        window.themeNode = document.querySelector('.mermaid-diagram');
        window.themeSVG = themeNode.querySelector('svg');
        window.themeHeight = document.getElementById('content').getBoundingClientRect().height;
        window.themeTransform = themeSVG.style.transform;
        window.themeIdentity = Math.random();
        """)
        let initialTheme = PerchTheme.shared.selection
        for color in ThemeColor.allCases {
            PerchTheme.shared.selection = color
            PerchTheme.shared.update(web)
            let preserved = try await web.callAsyncJavaScript("""
            return document.documentElement.dataset.perchTheme === name &&
              document.querySelector('.mermaid-diagram') === themeNode &&
              themeNode.querySelector('svg') === themeSVG && themeSVG.style.transform === themeTransform &&
              document.getElementById('content').getBoundingClientRect().height === themeHeight &&
              getComputedStyle(document.documentElement).getPropertyValue('--perch-mint').trim() === mint &&
              getComputedStyle(themeNode.querySelector('.diagram-toolbar')).backgroundColor ===
                (() => {const e=document.createElement('span');e.style.color=sidebar;document.body.append(e);
                  const c=getComputedStyle(e).color;e.remove();return c;})() &&
              typeof window.themeIdentity === 'number';
            """, arguments: ["name": color.rawValue, "mint": color.webColors["mint"]!, "sidebar": color.webColors["sidebar"]!], in: nil, contentWorld: .page)
            precondition(preserved as? Bool == true, "Theme updates must recolor Markdown without replacing SVG, viewport or message height")
        }
        PerchTheme.shared.selection = initialTheme
        PerchTheme.shared.update(web)
        print("PASS: all nine Markdown/diagram palettes change in place, preserving DOM identity, geometry and pan/zoom")
        let interaction = try await web.callAsyncJavaScript("""
        const card = document.querySelector('.mermaid-diagram'), source = card.querySelector('.diagram-source');
        const image = card.querySelector('.diagram-image');
        if (card.querySelector('.diagram-toolbar button').dataset.action !== 'mode' ||
            card.querySelectorAll('.diagram-toolbar button').length !== 1 ||
            card.querySelector('.diagram-toolbar [data-action=copy]') ||
            card.querySelector('[data-action=save]') || card.querySelector('[data-action=open]')) throw new Error('Inline toolbar must only contain image/source');
        if (typeof image.oncontextmenu !== 'function') throw new Error('Image context menu missing');
        if (!source.hidden || image.hidden) throw new Error('Default mode must be image');
        const toggle = card.querySelector('[data-action=mode]'), label = card.querySelector('.diagram-mode-label');
        if (toggle.getAttribute('aria-checked') !== 'false' || label.textContent !== '图片') throw new Error('Default switch state missing');
        toggle.click();
        if (toggle.getAttribute('aria-checked') !== 'true' || label.textContent !== '源码' ||
            label.getBoundingClientRect().left <= toggle.getBoundingClientRect().right) throw new Error('Switch must display its mode to the right');
        if (source.hidden || !image.hidden || !source.textContent.includes('A[开始]')) throw new Error('Source switch failed');
        const code = source.querySelector('code'), copy = source.querySelector('[data-action=copy]');
        if (!copy || copy.getBoundingClientRect().right > source.getBoundingClientRect().right) throw new Error('Source copy must be inside the upper right');
        const start = code.firstChild.textContent.indexOf('开始'), range = document.createRange();
        range.setStart(code.firstChild, start); range.setEnd(code.firstChild, start + 2);
        window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
        if (window.getSelection().toString() !== '开始') throw new Error('Source must permit partial selection');
        card.querySelector('[data-action=copy]').click();
        const png = await diagramPNG(image.querySelector('svg').outerHTML);
        const raster = new Image(); raster.src = png; await raster.decode();
        if (raster.width < 100 || raster.height < 20) throw new Error('PNG dimensions missing');
        const canvas = document.createElement('canvas'); canvas.width = raster.width; canvas.height = raster.height;
        const context = canvas.getContext('2d'); context.drawImage(raster, 0, 0);
        const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
        let ink = 0; for (let i = 0; i < pixels.length; i += 4) if (pixels[i] < 220 || pixels[i+1] < 220 || pixels[i+2] < 220) ink++;
        if (ink < 100) throw new Error('Exported PNG is blank');
        toggle.click();
        if (toggle.getAttribute('aria-checked') !== 'false' || label.textContent !== '图片') throw new Error('Image switch state missing');
        if (image.hidden || !source.hidden) throw new Error('Image switch failed');
        await new Promise(resolve => setTimeout(resolve, 100));
        const reset = image.querySelector('[data-action=reset]'), svg = image.querySelector('svg');
        const fitted = Number(card.dataset.scale), defaultTransform = svg.style.transform, defaultHeight = image.clientHeight;
        if (!reset.hidden) throw new Error('Default image must hide reset');
        const capture = image.setPointerCapture; image.setPointerCapture = () => {};
        image.dispatchEvent(new PointerEvent('pointerdown', {pointerId:2,button:0,clientX:100,clientY:100}));
        image.dispatchEvent(new PointerEvent('pointermove', {pointerId:2,clientX:160,clientY:135}));
        image.dispatchEvent(new PointerEvent('pointerup', {pointerId:2}));
        image.setPointerCapture = capture;
        image.click();
        if (svg.style.transform === defaultTransform || reset.hidden) throw new Error('Inline pan must reveal reset');
        image.dispatchEvent(new WheelEvent('wheel', {deltaY:-30,clientX:150,clientY:100,cancelable:true}));
        if (!(Number(card.dataset.scale) > fitted) || image.clientHeight !== defaultHeight) throw new Error('Inline zoom must keep Chat layout stable');
        const movedTransform = svg.style.transform;
        toggle.click(); toggle.click();
        await new Promise(resolve => setTimeout(resolve, 100));
        if (svg.style.transform !== movedTransform || reset.hidden) throw new Error('Source switching must preserve viewport');
        const corner = reset.getBoundingClientRect(), viewport = image.getBoundingClientRect();
        if (viewport.right - corner.right > 12 || corner.top - viewport.top > 12) throw new Error('Inline reset must be in the upper right');
        reset.click();
        if (!reset.hidden || svg.style.transform !== defaultTransform) throw new Error('Inline reset must restore the default and hide itself');
        return {svg:image.querySelector('svg').outerHTML, source:code.textContent, png};
        """, arguments: [:], in: nil, contentWorld: .page) as! [String: Any]
        let diagramSource = interaction["source"] as! String
        try await wait { NSPasteboard.general.string(forType: .string) == diagramSource }
        precondition(!NSApp.windows.contains { $0.title == "Mermaid 图表" && $0.isVisible },
                     "Dragging or resetting inline must not open the diagram window")
        try await wait { !(web as! AIMarkdownWebView).diagramRects.isEmpty }
        print("PASS: inline Mermaid pan, wheel zoom, stable height, mode preservation, conditional corner reset and drag click suppression")
        let png = AIDiagram.pngData(interaction["png"] as! String)!
        precondition((NSBitmapImageRep(data: png)?.pixelsWide ?? 0) > 100)
        precondition(AIDiagram.pngData("data:image/png;base64,invalid") == nil &&
                     AIDiagram.pngData("data:text/plain;base64,aGVsbG8=") == nil)
        let exported = FileManager.default.temporaryDirectory.appendingPathComponent("perch-diagram-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: exported) }
        try png.write(to: exported, options: .atomic)
        let savedPNG = try Data(contentsOf: exported)
        precondition(savedPNG == png)
        print("PASS: inline PNG disk round trip"); fflush(stdout)
        func savePanelFromImageMenu(_ view: WKWebView, parent: NSWindow) async throws {
            parent.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let menu = AIDiagram.imageMenu(svg: interaction["svg"] as! String, web: view)
            precondition(menu.items.map(\.title) == ["保存为图片…"])
            let save = menu.items[0]
            precondition(NSApp.sendAction(save.action!, to: save.target, from: save))
            try await wait { parent.sheets.first is NSSavePanel }
            let panel = parent.sheets.first as! NSSavePanel
            precondition(panel.allowedContentTypes == [.png] && panel.nameFieldStringValue == "Mermaid.png")
            // The system's remote save button needs real input; PNG bytes and disk round-trip are checked above.
            panel.cancel(nil)
            try await wait { parent.sheets.isEmpty }
        }
        try await savePanelFromImageMenu(web, parent: window)
        print("PASS: inline native image menu opens and cancels PNG save panel"); fflush(stdout)
        window.level = .floating; window.makeKeyAndOrderFront(nil)
        _ = try await web.callAsyncJavaScript("document.querySelector('.diagram-image').click();",
            arguments: [:], in: nil, contentWorld: .page)
        try await wait { NSApp.windows.contains { $0.title == "Mermaid 图表" && $0.isVisible } }
        let viewerWindow = NSApp.windows.first { $0.title == "Mermaid 图表" && $0.isVisible }!
        precondition(viewerWindow.level == .floating, "The diagram must remain above a pinned conversation")
        let viewerWeb = viewerWindow.contentView as! WKWebView
        defer { if viewerWindow.isVisible { viewerWindow.close() } }
        try await wait { (viewerWeb.navigationDelegate as? AIDiagram)?.loaded == true }
        precondition(!(viewerWeb is AIMarkdownWebView), "Diagram wheels must not use conversation scroll forwarding")
        let viewerInteraction = try await viewerWeb.callAsyncJavaScript("""
        const card = document.querySelector('.diagram-viewer'), image = card.querySelector('.diagram-image');
        // Background WebKit windows can suspend animation frames.
        await new Promise(resolve => setTimeout(resolve, 100));
        card.querySelector('[data-action=reset]').click();
        const fitted = Number(card.dataset.scale);
        card.querySelector('[data-action=zoom-in]').click();
        if (!(Number(card.dataset.scale) > fitted)) throw new Error('Zoom in failed');
        card.querySelector('[data-action=zoom-out]').click();
        if (Math.abs(Number(card.dataset.scale) - fitted) > 0.001) throw new Error('Zoom out failed');
        const svg = image.querySelector('svg'), before = svg.style.transform;
        // Synthetic pointer events cannot own browser pointer capture; verify the drag handlers with capture stubbed.
        const capture = image.setPointerCapture; image.setPointerCapture = () => {};
        image.dispatchEvent(new PointerEvent('pointerdown', {pointerId:1,button:0,clientX:100,clientY:100}));
        image.dispatchEvent(new PointerEvent('pointermove', {pointerId:1,clientX:170,clientY:135}));
        image.dispatchEvent(new PointerEvent('pointerup', {pointerId:1}));
        image.setPointerCapture = capture;
        if (svg.style.transform === before || image.classList.contains('dragging')) throw new Error('Drag failed');
        image.dispatchEvent(new WheelEvent('wheel', {deltaY:-30,cancelable:true}));
        if (!(Number(card.dataset.scale) > fitted)) throw new Error('Wheel zoom failed');
        card.querySelector('[data-action=reset]').click();
        if (Math.abs(Number(card.dataset.scale) - fitted) > 0.001) throw new Error('Reset failed');
        card.querySelector('[data-action=mode]').click();
        if (!image.hidden || card.querySelector('.diagram-source').hidden) throw new Error('Viewer source switch failed');
        const png = await diagramPNG(svg.outerHTML);
        card.querySelector('[data-action=mode]').click();
        return png;
        """, arguments: [:], in: nil, contentWorld: .page) as! String
        precondition(AIDiagram.pngData(viewerInteraction) != nil)
        try await savePanelFromImageMenu(viewerWeb, parent: viewerWindow)
        if let directory = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let snapshot: NSImage = try await withCheckedThrowingContinuation { continuation in
                viewerWeb.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? PerchError("Diagram snapshot failed")) }
                }
            }
            if let bitmap = snapshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("diagram.png"))
            }
        }
        print("PASS: single image/source switch with current mode on the right, selectable source with corner copy, image menu PNG export, click-to-open, drag, zoom and reset")
        _ = try await web.callAsyncJavaScript("return await renderMarkdown(text)", arguments: ["text": "```mermaid\nflowchart LR\nA -->\n```"], in: nil, contentWorld: .page)
        let incomplete = try await web.callAsyncJavaScript("return !!document.querySelector('#content pre code.language-mermaid') && !!document.querySelector('#content pre button')", arguments: [:], in: nil, contentWorld: .page)
        precondition(incomplete as? Bool == true, "Incomplete Mermaid must preserve its source and copy button")
        let replacement = try await web.callAsyncJavaScript("""
        const previous = renderMarkdown('```mermaid\\nflowchart LR\\nA --> B\\n```');
        await renderMarkdown('Updated plain answer'); await previous;
        return document.querySelector('#content').textContent.trim() === 'Updated plain answer' &&
          !document.querySelector('#content svg');
        """, arguments: [:], in: nil, contentWorld: .page)
        precondition(replacement as? Bool == true, "A stale Mermaid render must not overwrite the latest Markdown")
        let independent = try await viewerWeb.callAsyncJavaScript("return !!document.querySelector('.diagram-viewer svg') && !document.querySelector('.diagram-image').hidden",
            arguments: [:], in: nil, contentWorld: .page)
        precondition(independent as? Bool == true, "Replacing the Markdown must not discard the enlarged diagram")
        let menuSuite = "dev.perch.ai.diagram-menu.\(UUID())"
        let menuDefaults = UserDefaults(suiteName: menuSuite)!
        defer { menuDefaults.removePersistentDomain(forName: menuSuite) }
        let menuStore = Store(defaults: menuDefaults)
        menuStore.openChat(owner: AIController.homeID)
        let chatID = menuStore.selected!
        let menuDelegate = AppDelegate(store: menuStore)
        menuDelegate.panel = window
        let previousMenu = NSApp.mainMenu
        menuDelegate.installMenu()
        defer { NSApp.mainMenu = previousMenu }
        NSApp.activate(ignoringOtherApps: true)
        viewerWindow.makeKeyAndOrderFront(nil)
        try await wait { NSApp.keyWindow === viewerWindow }
        func commandW(_ target: NSWindow) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: target.windowNumber, context: nil, characters: "w",
                charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
            return NSApp.mainMenu!.performKeyEquivalent(with: event)
        }
        precondition(commandW(viewerWindow))
        try await wait { !viewerWindow.isVisible }
        precondition(menuStore.tabs.contains { $0.id == chatID }, "Command W in a diagram must leave Chat open")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await wait { NSApp.keyWindow === window }
        precondition(commandW(window))
        precondition(!menuStore.tabs.contains { $0.id == chatID }, "Command W in Chat must still close the selected tab")
        NSApp.mainMenu = previousMenu
        window.level = .normal
        print("PASS: real Command W menu closes the active diagram, preserves Chat, and still closes a tab when Chat is active")
        print("PASS: local Mermaid flowchart/sequence SVG, incomplete-stream code fallback and stale render cancellation")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        scroll.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1500))
        window.contentView = scroll; scroll.documentView = document
        web.frame = NSRect(x: 0, y: 0, width: 300, height: 1500); document.addSubview(web)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600)); scroll.reflectScrolledClipView(scroll.contentView)
        let markdownWeb = web as! AIMarkdownWebView
        let before = scroll.contentView.bounds.origin.y
        let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -90, wheel2: 0, wheel3: 0)!)!
        let overText = NSPoint(x: markdownWeb.visibleRect.midX, y: markdownWeb.visibleRect.midY)
        let visibleImage = NSRect(x: overText.x - 40,
            y: (markdownWeb.isFlipped ? overText.y : markdownWeb.bounds.height - overText.y) - 40, width: 80, height: 80)
        markdownWeb.diagramRects = [visibleImage]
        precondition(!markdownWeb.forwardVerticalScroll(wheel, at: overText), "Image wheels must reach inline zoom")
        precondition(scroll.contentView.bounds.origin.y == before, "Image zoom must not scroll Chat")
        markdownWeb.diagramRects = []
        precondition(markdownWeb.forwardVerticalScroll(wheel, at: overText))
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(abs(scroll.contentView.bounds.origin.y - before) > 10, "Vertical wheels over Markdown text must move the outer conversation")
        let horizontal = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -90, wheel3: 0)!)!
        precondition(!markdownWeb.forwardVerticalScroll(horizontal, at: overText), "Horizontal code/table scrolling must remain in WebKit")
        precondition(!markdownWeb.forwardVerticalScroll(wheel, at: NSPoint(x: -10, y: -10)))
        print("PASS: vertical scrolling over Markdown text reaches the conversation, horizontal wheels and outside regions remain untouched")
    }
    static func keyDisplay(ai: AIController, config: AIConfiguration) async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 780, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AIProviderEditor(ai: ai, openChat: {}, back: {}))
        window.contentView = host; window.orderFront(nil)
        func secureField(_ view: NSView) -> NSSecureTextField? {
            if let field = view as? NSSecureTextField { return field }
            return view.subviews.compactMap(secureField).first
        }
        defer { window.orderOut(nil); window.contentView = nil }
        try await wait { secureField(host)?.stringValue == "••••••••••••" }
        let models = try await ai.models(for: config, key: "")
        precondition(models == ["fixture", "alternate"])
        print("PASS: saved API key displays dots in native secure field without overwriting the credential")
    }

    static func preview() -> NSWindow {
        let defaults = UserDefaults(suiteName: "dev.perch.ai.preview")!
        defaults.removePersistentDomain(forName: "dev.perch.ai.preview")
        let store = Store(defaults: defaults)
        var config = AIConfiguration(provider: .custom, baseURL: "http://127.0.0.1:9999/v1", model: "chat-model")
        config.name = "个人助手"; config.models = ["chat-model", "vision-model", "reasoning-model"]
        precondition(store.ai.save(config, key: "synthetic-key"))
        store.ai.addProvider(.custom)
        var another = store.ai.configuration
        another.name = "工作助手"; another.baseURL = config.baseURL; another.model = "fast-model"; another.models = ["fast-model", "code-model"]
        precondition(store.ai.save(another, key: "synthetic-key"))
        store.ai.select(config.id)
        let window = NSWindow(contentRect: NSRect(x: 150, y: 200, width: 1000, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Perch AI · 隔离预览"
        if CommandLine.arguments.contains("--ai-settings-preview") {
            window.setContentSize(NSSize(width: 780, height: 580))
            window.contentView = NSHostingView(rootView: LibraryView(store: store, page: .ai).defaultAppStorage(defaults))
        } else {
            store.aiVisible = true
            window.setContentSize(NSSize(width: 360, height: 720))
            store.ai.seedPreview()
            store.tabs = [
                Tab(title: "Design notes", address: "https://example.com/notes"),
                Tab(title: "Weekly plan", address: "https://example.com/plan"),
                Tab(title: "Documentation", address: "https://example.com/docs")
            ]
            if CommandLine.arguments.contains("--preview-mentions") { store.ai.drafts[AIController.homeID] = "@" }
            if CommandLine.arguments.contains("--preview-references") { store.ai.draftReferences[AIController.homeID] = store.tabs.map(\.id) }
            if CommandLine.arguments.contains("--preview-chat-page") {
                window.setContentSize(NSSize(width: 1100, height: 720))
                store.openChat(owner: AIController.homeID)
                if CommandLine.arguments.contains("--preview-history") {
                    store.chatHistoryVisible = true
                    store.ai.saveConversations()
                }
                window.contentView = NSHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
            } else {
                window.contentView = NSHostingView(rootView: AIChatSidebar(store: store, ai: store.ai, close: {}).defaultAppStorage(defaults))
            }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        return window
    }
    static func composerReturnChecks() {
        var draft = ""
        var acceptsSend = true
        var sent = 0
        for command in [false, true] {
            let composer = AIComposerInput(text: Binding(get: { draft }, set: { draft = $0 }),
                enabled: true, mentionChanged: { _, _ in }, mentionCommand: { _ in false },
                sendWithCommand: command, send: {
                    guard acceptsSend else { return }
                    sent += 1
                    draft = ""
                })
            let coordinator = AIComposerInput.Coordinator(composer)
            let editor = AIComposerTextView()
            editor.delegate = coordinator
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: command ? [.command] : [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            acceptsSend = true
            editor.string = "快速中文提交"
            precondition(coordinator.handleReturn(event, editor: editor))
            precondition(draft.isEmpty && editor.string.isEmpty && editor.showsPlaceholder,
                         "Accepted Return must clear both draft and native text synchronously")
            editor.didChangeText()
            precondition(draft.isEmpty && editor.string.isEmpty,
                         "A late text-change notification must not restore submitted text")

            acceptsSend = false
            let acceptedCount = sent
            editor.string = "拒绝发送保留草稿"
            precondition(coordinator.handleReturn(event, editor: editor))
            precondition(draft == editor.string && draft == "拒绝发送保留草稿" && sent == acceptedCount)
            editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                 replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            precondition(!coordinator.handleReturn(event, editor: editor))
            precondition(editor.hasMarkedText() && editor.string == "ni" &&
                         draft == "拒绝发送保留草稿" && sent == acceptedCount)
            editor.unmarkText()
        }
        precondition(sent == 2)
        var coordinator: AIComposerInput.Coordinator!
        let submitted = "同步发送触发界面更新"
        draft = ""
        let snapshot = AIComposerInput(text: Binding(get: { submitted }, set: { draft = $0 }),
            enabled: true, mentionChanged: { _, _ in }, mentionCommand: { _ in false })
        let composer = AIComposerInput(text: Binding(get: { draft }, set: { draft = $0 }),
            enabled: true, mentionChanged: { _, _ in }, mentionCommand: { _ in false }, send: {
                // Model a SwiftUI update while the synchronous Keychain helper waits.
                coordinator.parent = snapshot
                draft = ""
            })
        coordinator = AIComposerInput.Coordinator(composer)
        let editor = AIComposerTextView()
        editor.delegate = coordinator
        editor.string = submitted
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 256), timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        precondition(coordinator.handleReturn(event, editor: editor))
        precondition(draft.isEmpty && editor.string.isEmpty,
                     "A reentrant view update must not replace the active send callback or binding")
        editor.didChangeText()
        precondition(draft.isEmpty)
        coordinator.parent = snapshot
        print("PASS: Return preserves its original callback and binding across synchronous view updates")
        print("PASS: Return/Cmd+Return clear native text before late notifications; rejected sends and IME retain drafts")
    }
    static func composerUI(baseURL: String) async throws {
        composerReturnChecks()
        // SwiftUI otherwise leaves its accessibility tree empty without an external screen reader.
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let suite = "dev.perch.ai.composer-ui.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        var config = AIConfiguration(provider: .custom, baseURL: baseURL + "/v1", model: "fixture")
        precondition(store.ai.save(config, key: "synthetic-key"))
        let owner = AIController.homeID
        precondition(store.ai.send("Previous conversation fixture", tab: owner, browser: nil, usePage: false))
        try await wait { store.ai.sessions[owner]?.requestID == nil }
        let previous = store.ai.sessions[owner]!
        store.openChat(owner: owner)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 1000, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AIChatSidebar(store: store, ai: store.ai, fullPage: true, close: {}).defaultAppStorage(defaults))
        window.acceptsMouseMovedEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func table(in view: NSView) -> AIHistoryTable? {
            (view as? AIHistoryTable) ?? view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        func element(in node: Any, label: String) -> NSObject? {
            guard let value = node as? NSObject else { return nil }
            for key in ["accessibilityLabel", "accessibilityTitle"] {
                if value.responds(to: NSSelectorFromString(key)),
                   value.value(forKey: key) as? String == label { return value }
            }
            guard value.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            return (value.value(forKey: "accessibilityChildren") as? [Any] ?? []).lazy.compactMap { element(in: $0, label: label) }.first
        }
        func frame(_ label: String) throws -> NSRect {
            guard let value = element(in: host, label: label),
                  let rect = value.value(forKey: "accessibilityFrame") as? NSValue else {
                throw PerchError("Missing composer control: \(label)")
            }
            return rect.rectValue
        }
        func snapshot(_ name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"] else { return }
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
        }
        try await wait { table(in: host)?.selectedRowIndexes.isEmpty == false }
        let history = table(in: host)!
        func selected() -> Set<UUID> {
            Set(history.selectedRowIndexes.compactMap { history.conversationIDs[$0] })
        }
        precondition(selected() == [previous.id])
        store.newChat()
        try await wait { selected().isEmpty }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(selected().isEmpty, "An empty new conversation must not highlight the old row")
        precondition(store.ai.send("Current conversation fixture", tab: owner, browser: nil, usePage: false))
        let current = store.ai.sessions[owner]!
        try await wait { selected() == [current.id] }
        host.layoutSubtreeIfNeeded()
        precondition(history.visibleRect.intersects(history.rect(ofRow: history.selectedRow)))
        try await wait { store.ai.sessions[owner]?.requestID == nil && store.ai.sessions[owner]?.summaryTitle != nil }
        precondition(selected() == [current.id], "Title updates must retain the active selection")
        let previousRow = history.conversationIDs.firstIndex(of: previous.id)!
        history.choose(previousRow, modifiers: .command)
        precondition(store.ai.send("Followup conversation fixture", tab: owner, browser: nil, usePage: false))
        try await wait { store.ai.sessions[owner]?.requestID == nil }
        precondition(selected() == [previous.id, current.id], "Refreshing the current conversation must preserve manual multi-selection")
        store.ai.resumeConversation(previous.id, tab: owner)
        try await wait { selected() == [previous.id] }
        store.ai.resumeConversation(current.id, tab: owner)
        try await wait { selected() == [current.id] }
        print("PASS: new/empty/first-message selection, title refresh, manual multi-selection and conversation switching")

        config.baseURL = baseURL + "/slow"
        precondition(store.ai.save(config))
        for fullPage in [true, false] {
            host.rootView = AIChatSidebar(store: store, ai: store.ai, fullPage: fullPage, close: {}).defaultAppStorage(defaults)
            window.setContentSize(NSSize(width: fullPage ? 1000 : 360, height: 650))
            store.ai.drafts[owner] = "native queue start fixture"
            do {
                try await wait {
                    host.layoutSubtreeIfNeeded()
                    return element(in: host, label: "发送") != nil && element(in: host, label: "选择模型") != nil
                }
            } catch {
                try snapshot("missing-controls")
                throw PerchError("Composer controls unavailable: ready=\(store.ai.ready(for: owner)), busy=\(store.ai.sessions[owner]?.requestID != nil), error=\(store.ai.sessions[owner]?.error ?? "none")")
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            let labels = ["添加附件", "联网搜索", "选择模型"]
            let before = try labels.map(frame)
            let send = try frame("发送")
            let inputRect = try frame("向 AI 提问，输入 @ 引用标签页")
            for rect in before + [send] {
                precondition(!inputRect.contains(NSPoint(x: rect.midX, y: rect.midY)),
                             "Icon controls must remain outside the text input")
            }
            let prefix = fullPage ? "full" : "sidebar"
            try snapshot(prefix + "-idle")
            precondition(store.ai.send(store.ai.drafts[owner]!, tab: owner, browser: nil, usePage: false))
            store.ai.drafts[owner] = ""
            try await wait { element(in: host, label: "停止生成") != nil && element(in: host, label: "发送") == nil }
            for _ in 0..<12 {
                try await Task.sleep(nanoseconds: 20_000_000)
                host.layoutSubtreeIfNeeded()
                let after = try labels.map(frame)
                for (a, b) in zip(before, after) {
                    precondition(abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 &&
                                 abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1,
                                 "Starting generation must not move or resize the composer controls: \(a) -> \(b)")
                }
                let stop = try frame("停止生成")
                precondition(abs(send.midX - stop.midX) < 1 && abs(send.midY - stop.midY) < 1,
                             "Send and stop must occupy the same position")
            }
            try snapshot(prefix + "-busy")
            try await wait { store.ai.sessions[owner]?.requestID == nil }
            try await wait { element(in: host, label: "发送") != nil && element(in: host, label: "停止生成") == nil }
            host.layoutSubtreeIfNeeded()
            for (a, b) in zip(before, try labels.map(frame)) {
                precondition(abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1)
            }
            print("PASS: \(prefix) composer control frames remain stable before, during rotation and after generation")
        }
        config.nativeSearch = .standard
        precondition(store.ai.save(config))
        let settings = NSHostingView(rootView: AIProviderEditor(ai: store.ai, openChat: {}, back: {}))
        window.contentView = settings
        window.setContentSize(NSSize(width: 780, height: 580))
        try await wait { element(in: settings, label: "联网搜索") != nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        settings.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"],
           let bitmap = settings.bitmapImageRepForCachingDisplay(in: settings.bounds) {
            settings.cacheDisplay(in: settings.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("model-settings.png"))
        }
    }

    static func chatUI(config: AIConfiguration) async throws {
        let suite = "dev.perch.ai.chat-ui.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        let restoredWeb = Tab(title: "Web fixture", address: "about:blank")
        let duplicateChats = [Tab(title: "Chat", address: "", chatOwner: UUID()),
                              Tab(title: "Chat", address: "", chatOwner: UUID())]
        defaults.set(try JSONEncoder().encode([restoredWeb] + duplicateChats), forKey: "tabs")
        defaults.set(duplicateChats[1].id.uuidString, forKey: "selectedTab")
        let restoredStore = Store(defaults: defaults)
        precondition(restoredStore.tabs.filter { $0.chatOwner != nil }.map(\.id) == [duplicateChats[1].id])
        precondition(restoredStore.selected == duplicateChats[1].id)
        precondition(restoredStore.chatHistoryVisible, "Restoring Chat must open its history sidebar")
        let singletonID = restoredStore.selected
        restoredStore.chatHistoryVisible = false
        restoredStore.selected = restoredWeb.id
        restoredStore.activate(singletonID!)
        precondition(restoredStore.chatHistoryVisible, "Switching back to Chat must open its history sidebar")
        restoredStore.chatHistoryVisible = false
        restoredStore.openChat(owner: UUID())
        precondition(restoredStore.chatHistoryVisible, "Opening the existing Chat must open its history sidebar")
        restoredStore.openChat(owner: UUID())
        precondition(restoredStore.selected == singletonID && restoredStore.tabs.count == 2)
        restoredStore.close(singletonID!)
        restoredStore.openChat(owner: UUID())
        let reopenedID = restoredStore.selected
        restoredStore.reopen()
        precondition(restoredStore.tabs.filter { $0.chatOwner != nil }.count == 1 && restoredStore.selected == reopenedID)
        print("PASS: globally unique Chat tab, duplicate restore keeps selected Chat, different owners and reopening reuse the same tab")
        precondition(store.ai.save(config, key: "synthetic-key"))
        let legacySettings = try JSONDecoder().decode(BrowserSettings.self, from: Data("{}".utf8))
        precondition(!legacySettings.aiSendWithCommand)
        var shortcutSettings = legacySettings
        shortcutSettings.aiSendWithCommand = true
        let restoredShortcutSettings = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(shortcutSettings))
        precondition(restoredShortcutSettings.aiSendWithCommand)
        let firstPage = Tab(title: "First page", address: "https://example.com/first")
        let secondPage = Tab(title: "Second page", address: "https://example.com/second")
        store.tabs = [firstPage, secondPage]; store.selected = firstPage.id
        store.aiVisible = true
        precondition(store.ai.draftReferences[firstPage.id] == [firstPage.id])
        store.ai.drafts[firstPage.id] = "unfinished question"
        store.selected = secondPage.id
        precondition(!store.aiVisible)
        store.aiVisible = true
        precondition(store.ai.draftReferences[secondPage.id] == [secondPage.id])
        store.selected = firstPage.id
        precondition(store.aiVisible && store.ai.drafts[firstPage.id] == "unfinished question")
        store.aiVisible = false; store.selected = secondPage.id
        precondition(store.aiVisible)
        store.selected = firstPage.id; store.aiVisible = true; store.newChat()
        precondition(store.ai.draftReferences[firstPage.id] == [firstPage.id])
        let sidebarRecord = AISession(messages: [AIMessage(role: "user", text: "sidebar")], origin: .web,
                                      webPageURLs: [URL(string: firstPage.address)!])
        let referencedRecord = AISession(messages: [AIMessage(role: "user", text: "chat reference",
                                        references: [AIPageReference(title: "First", url: URL(string: firstPage.address))])], origin: .chat)
        let unrelatedRecord = AISession(messages: [AIMessage(role: "user", text: "unrelated")], origin: .web,
                                        webPageURLs: [URL(string: secondPage.address)!])
        let archivedRecord = AISession(messages: [AIMessage(role: "user", text: "archived")], isArchived: true,
                                       webPageURLs: [URL(string: firstPage.address)!])
        let legacyRecord = AISession(messages: [AIMessage(role: "user", text: "legacy", sourceURL: URL(string: firstPage.address))])
        let historyDirectory = URL(fileURLWithPath: "/tmp").appendingPathComponent("perch-page-history-\(UUID())")
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let records = [sidebarRecord, referencedRecord, unrelatedRecord, archivedRecord, legacyRecord]
        let historyArchive = AIConversationArchive(conversations: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), tabs: [:])
        try JSONEncoder().encode(historyArchive).write(to: historyDirectory.appendingPathComponent("conversations.json"))
        let historyController = AIController(defaults: defaults, conversationDirectory: historyDirectory)
        precondition(Set(historyController.conversations(for: URL(string: firstPage.address + "?secret=ignored#fragment")).map(\.id)) ==
                     Set([sidebarRecord.id, referencedRecord.id, legacyRecord.id]))
        let roundTrip = try JSONDecoder().decode(AISession.self, from: JSONEncoder().encode(sidebarRecord))
        precondition(roundTrip.webPageURLs == sidebarRecord.webPageURLs && roundTrip.readingPosition == nil)
        let persistedStore = Store(defaults: defaults)
        precondition(persistedStore.tabs.first { $0.id == firstPage.id }?.aiSidebarOpen == true)
        precondition(persistedStore.tabs.first { $0.id == secondPage.id }?.aiSidebarOpen == true)
        store.ai.drafts = [:]; store.ai.draftReferences = [:]
        store.selected = nil
        print("PASS: per-tab sidebar state, current-page reference, filtered history and legacy settings migration")
        store.tabs = [Tab(title: "First fixture", address: "about:blank"), Tab(title: "Second fixture", address: "about:blank")]
        let host = NSHostingView(rootView: AIChatSidebar(store: store, ai: store.ai, close: {}).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 200, width: 350, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        try await wait { editor(in: host) != nil }
        let input = editor(in: host)!
        var sendCount = 0
        var selectMention = false
        var composerText = "question"
        var composer = AIComposerInput(text: Binding(get: { composerText }, set: { composerText = $0 }),
                                       enabled: true, mentionChanged: { _, _ in }, mentionCommand: { _ in selectMention },
                                       send: { sendCount += 1 })
        let coordinator = AIComposerInput.Coordinator(composer)
        let shortcutEditor = AIComposerTextView()
        shortcutEditor.delegate = coordinator
        func pressReturn(_ flags: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                        isARepeat: false, keyCode: 36)!
            _ = coordinator.handleReturn(event, editor: shortcutEditor)
        }
        shortcutEditor.string = "question"; pressReturn([])
        precondition(sendCount == 1 && composerText == "question")
        pressReturn(.shift); precondition(sendCount == 1 && shortcutEditor.string.contains("\n"))
        composer.sendWithCommand = true; coordinator.parent = composer
        pressReturn([]); precondition(sendCount == 1)
        pressReturn(.command); precondition(sendCount == 2)
        shortcutEditor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        pressReturn(.command); precondition(sendCount == 2 && shortcutEditor.hasMarkedText())
        shortcutEditor.unmarkText()
        selectMention = true; composer.sendWithCommand = false; coordinator.parent = composer
        pressReturn([]); precondition(sendCount == 2)
        print("PASS: Return sends, configurable Cmd+Return, Shift+Return newline, IME and mention selection")
        window.makeFirstResponder(input)
        input.insertText("帮我看看@Second", replacementRange: NSRange(location: 0, length: 0))
        try await wait { store.ai.drafts[AIController.homeID] == "帮我看看@Second" }
        let selected = input.delegate?.textView?(input, doCommandBy: NSSelectorFromString("insertNewline:"))
        precondition(selected == true)
        try await wait { store.ai.draftReferences[AIController.homeID] == [store.tabs[1].id] }
        precondition(store.ai.drafts[AIController.homeID] == "帮我看看" && store.selected == nil)
        window.setContentSize(NSSize(width: 1000, height: 650))
        let root = NSHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        window.contentView = root
        try await wait { editor(in: root) != nil }
        let sideInput = editor(in: root)!
        root.layoutSubtreeIfNeeded()
        let closedX = sideInput.convert(sideInput.bounds, to: root).minX
        store.aiVisible = true
        var samples: [CGFloat] = []
        for _ in 0..<18 {
            try await Task.sleep(nanoseconds: 20_000_000)
            root.layoutSubtreeIfNeeded()
            samples.append(sideInput.convert(sideInput.bounds, to: root).minX)
        }
        let openedX = samples.last!
        precondition(closedX - openedX > 250)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(samples.contains { $0 > openedX + 5 && $0 < closedX - 5 }, "AI sidebar must pass through intermediate positions")
        }
        store.aiVisible = false
        try await wait { sideInput.convert(sideInput.bounds, to: root).minX > closedX - 2 }
        print("PASS: native right sidebar animated intermediate positions and closing layout")
        store.ai.drafts[AIController.homeID] = "Continue here"
        store.openChat(owner: AIController.homeID)
        window.contentView = NSHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        try await wait { editor(in: window.contentView!)?.string == "Continue here" }
        precondition(store.chatOwner == AIController.homeID && store.ai.draftReferences[store.chatOwner]?.count == 1)
        let fullInput = editor(in: window.contentView!) as! AIComposerTextView
        func composers(in view: NSView) -> Int {
            (view is AIComposerTextView ? 1 : 0) + view.subviews.reduce(0) { $0 + composers(in: $1) }
        }
        precondition(composers(in: window.contentView!) == 1, "Full Chat must not construct a duplicate hidden composer")
        precondition(store.ai.searchRoute(for: store.chatOwner) == .off)
        func addressFields(in view: NSView) -> Int {
            let current = (view as? NSTextField)?.delegate is AddressTextField.Coordinator ? 1 : 0
            return current + view.subviews.reduce(0) { $0 + addressFields(in: $1) }
        }
        precondition(addressFields(in: window.contentView!) == 0, "Full Chat must hide its address row")
        if let directory = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let root = window.contentView!
            root.layoutSubtreeIfNeeded()
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("chat.png"))
            }
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        fullInput.pasteboard = board
        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.lockFocus(); NSColor.systemGreen.setFill(); NSRect(x: 0, y: 0, width: 40, height: 30).fill(); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        for (type, format) in [(NSPasteboard.PasteboardType.png, NSBitmapImageRep.FileType.png),
                               (.tiff, .tiff), (NSPasteboard.PasteboardType("public.jpeg"), .jpeg)] {
            board.clearContents()
            board.setData(bitmap.representation(using: format, properties: [:])!, forType: type)
            let menu = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
            precondition(fullInput.validateUserInterfaceItem(menu), "Image-only clipboard must enable Paste")
            window.makeFirstResponder(fullInput)
            fullInput.paste(nil)
            try await wait { (store.ai.draftFiles[store.chatOwner] ?? []).count > 0 }
        }
        precondition(store.ai.draftFiles[store.chatOwner]?.count == 3 && fullInput.string == "Continue here")
        precondition(store.ai.draftFiles[store.chatOwner]?.allSatisfy { $0.mime == "image/jpeg" && NSImage(data: $0.data) != nil } == true)
        for _ in 0..<3 { fullInput.paste(nil) }
        precondition(store.ai.draftFiles[store.chatOwner]?.count == 5, "Paste must respect attachment count limits")
        window.makeFirstResponder(fullInput)
        fullInput.setSelectedRange(NSRange(location: fullInput.string.utf16.count, length: 0))
        fullInput.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
        store.ai.draftFiles[store.chatOwner] = []
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(fullInput.hasMarkedText() && fullInput.string == "Continue heren")
        precondition(fullInput.delegate?.textView?(fullInput, doCommandBy: NSSelectorFromString("insertNewline:")) != true)
        fullInput.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await wait { store.ai.drafts[store.chatOwner] == "Continue here你" }
        let historyRoot = window.contentView!
        historyRoot.layoutSubtreeIfNeeded()
        func accessibilityElement(in node: Any, label: String) -> NSObject? {
            // SwiftUI's AccessibilityNode exposes selectors without declaring NSAccessibility conformance.
            guard let element = node as? NSObject else { return nil }
            if element.responds(to: NSSelectorFromString("accessibilityLabel")),
               element.value(forKey: "accessibilityLabel") as? String == label { return element }
            guard element.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            for child in element.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
                if let found = accessibilityElement(in: child, label: label) { return found }
            }
            return nil
        }
        func accessibilityFrame(_ element: NSObject) -> NSRect {
            (element.value(forKey: "accessibilityFrame") as! NSValue).rectValue
        }
        func click(_ element: NSObject) {
            // Use the native accessibility action instead of targeting a cached symbol frame.
            let press = NSSelectorFromString("accessibilityPerformPress")
            if element.responds(to: press) {
                typealias Action = @convention(c) (AnyObject, Selector) -> Bool
                let action = unsafeBitCast(element.method(for: press), to: Action.self)
                if action(element, press) { return }
            }
            let frame = accessibilityFrame(element)
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            }
        }
        precondition(store.chatHistoryVisible, "Entering full Chat must show history by default")
        try await wait {
            historyRoot.layoutSubtreeIfNeeded()
            return accessibilityElement(in: historyRoot, label: "收起历史侧栏") != nil &&
                accessibilityElement(in: historyRoot, label: "查看已归档对话") != nil
        }
        guard let collapse = accessibilityElement(in: historyRoot, label: "收起历史侧栏"),
              let archived = accessibilityElement(in: historyRoot, label: "查看已归档对话") else {
            throw PerchError("Chat footer controls are missing")
        }
        precondition(accessibilityElement(in: historyRoot, label: "AI 功能设置") == nil, "Chat must not have a settings shortcut")
        guard let export = accessibilityElement(in: historyRoot, label: "导出 Markdown"),
              let newChat = accessibilityElement(in: historyRoot, label: "新对话"),
              let pin = accessibilityElement(in: historyRoot, label: "窗口置顶") else {
            throw PerchError("Chat toolbar controls are missing")
        }
        guard let globe = accessibilityElement(in: historyRoot, label: "联网搜索"),
              let modelPicker = accessibilityElement(in: historyRoot, label: "选择模型") else {
            throw PerchError("Chat search and model controls are missing")
        }
        precondition(!accessibilityFrame(globe).intersects(accessibilityFrame(modelPicker)),
                     "Search menu must not overlap the model picker")
        print("PASS: native globe search menu is accessible beside the model picker without overlap")
        let toolbarFrames = [export, newChat, pin].map(accessibilityFrame)
        precondition(toolbarFrames[0].maxX < toolbarFrames[1].minX &&
                     toolbarFrames[1].maxX < toolbarFrames[2].minX, "Export and new chat must sit immediately before pin")
        // SwiftUI reports the symbol outline here, not the shared 28pt button frame.
        precondition(toolbarFrames.allSatisfy { abs($0.midY - toolbarFrames[2].midY) < 1 } &&
                     abs(toolbarFrames[1].midX - toolbarFrames[0].midX - 31) < 2 &&
                     abs(toolbarFrames[2].midX - toolbarFrames[1].midX - 31) < 2,
                     "Chat toolbar buttons must share the 28pt layout, 3pt spacing and alignment")
        print("PASS: Chat export and new conversation share the pin button layout and sit immediately before it")
        let expandedFrame = accessibilityFrame(collapse)
        precondition(abs(expandedFrame.midY - accessibilityFrame(archived).midY) < 2,
                     "Collapse must align with the archive link")
        let expandedInputX = fullInput.convert(fullInput.bounds, to: historyRoot).minX
        click(collapse)
        try await wait {
            historyRoot.layoutSubtreeIfNeeded()
            return !store.chatHistoryVisible && abs(fullInput.convert(fullInput.bounds, to: historyRoot).minX - (expandedInputX - 201)) < 2
        }
        guard let expand = accessibilityElement(in: historyRoot, label: "展开历史侧栏") else {
            throw PerchError("Collapsed Chat must keep an expand button")
        }
        let collapsedFrame = accessibilityFrame(expand)
        precondition(abs(collapsedFrame.midY - expandedFrame.midY) < 2, "Both sidebar controls must use the same footer height")
        precondition(abs(expandedFrame.minX - collapsedFrame.minX - 188) < 2,
                     "Expand must sit just right of the tab divider")
        precondition(collapsedFrame.maxX < window.convertToScreen(fullInput.convert(fullInput.bounds, to: nil)).minX,
                     "Expand must not overlap the composer")
        let gutterPoint = window.convertPoint(fromScreen: NSPoint(x: collapsedFrame.midX, y: collapsedFrame.maxY + 80))
        let gutterInRoot = historyRoot.convert(gutterPoint, from: nil)
        let gutterBitmap = historyRoot.bitmapImageRepForCachingDisplay(in: historyRoot.bounds)!
        historyRoot.cacheDisplay(in: historyRoot.bounds, to: gutterBitmap)
        let gutterColor = gutterBitmap.colorAt(
            x: Int(gutterInRoot.x * CGFloat(gutterBitmap.pixelsWide) / historyRoot.bounds.width),
            y: Int((historyRoot.isFlipped ? gutterInRoot.y : historyRoot.bounds.height - gutterInRoot.y) * CGFloat(gutterBitmap.pixelsHigh) / historyRoot.bounds.height))!
            .usingColorSpace(.deviceRGB)!
        precondition(abs(gutterColor.redComponent - 0.98) < 0.015 &&
                     abs(gutterColor.greenComponent - 0.98) < 0.015 &&
                     abs(gutterColor.blueComponent - 0.96) < 0.015,
                     "Collapsed history gutter must match the warm paper background")
        click(expand)
        do {
            try await wait {
                historyRoot.layoutSubtreeIfNeeded()
                return store.chatHistoryVisible && abs(fullInput.convert(fullInput.bounds, to: historyRoot).minX - expandedInputX) < 2
            }
        } catch {
            throw PerchError("Reopening history failed: visible=\(store.chatHistoryVisible), inputX=\(fullInput.convert(fullInput.bounds, to: historyRoot).minX), expected=\(expandedInputX)")
        }
        print("PASS: collapsed history background and footer reopen layout")
        func historyResizeHandle(in view: NSView) -> SidebarResizeHandle.ResizeView? {
            if let handle = view as? SidebarResizeHandle.ResizeView { return handle }
            return view.subviews.compactMap { historyResizeHandle(in: $0) }.max {
                $0.convert($0.bounds, to: historyRoot).midX < $1.convert($1.bounds, to: historyRoot).midX
            }
        }
        let historyHandle = historyResizeHandle(in: historyRoot)!
        precondition(abs(historyHandle.bounds.width - 7) < 0.5)
        for y in [CGFloat(2), historyHandle.bounds.midY, historyHandle.bounds.height - 2] {
            let point = historyHandle.convert(NSPoint(x: historyHandle.bounds.midX, y: y), to: historyRoot.superview)
            precondition(historyRoot.hitTest(point) === historyHandle, "History divider must receive events across its full height")
        }
        func dragHistory(_ delta: CGFloat) {
            let handle = historyResizeHandle(in: historyRoot)!
            let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + delta, y: start.y),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!,
                    atStart: false)
            }
            handle.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
        }
        dragHistory(80)
        do {
            try await wait {
                historyRoot.layoutSubtreeIfNeeded()
                return abs(defaults.double(forKey: "chatHistoryWidth") - 320) < 1
                    && abs(fullInput.convert(fullInput.bounds, to: historyRoot).minX - expandedInputX - 80) < 2
            }
        } catch {
            throw PerchError("Dragging history failed: width=\(defaults.double(forKey: "chatHistoryWidth")), inputX=\(fullInput.convert(fullInput.bounds, to: historyRoot).minX), expected=\(expandedInputX + 80)")
        }
        print("PASS: native history drag saves 320pt width")
        click(accessibilityElement(in: historyRoot, label: "收起历史侧栏")!)
        do {
            try await wait {
                historyRoot.layoutSubtreeIfNeeded()
                return !store.chatHistoryVisible && abs(fullInput.convert(fullInput.bounds, to: historyRoot).minX - (expandedInputX - 201)) < 2
            }
        } catch {
            throw PerchError("Collapsing resized history failed: visible=\(store.chatHistoryVisible), inputX=\(fullInput.convert(fullInput.bounds, to: historyRoot).minX), expected=\(expandedInputX - 201)")
        }
        click(accessibilityElement(in: historyRoot, label: "展开历史侧栏")!)
        do {
            try await wait {
                historyRoot.layoutSubtreeIfNeeded()
                return store.chatHistoryVisible && abs(fullInput.convert(fullInput.bounds, to: historyRoot).minX - expandedInputX - 80) < 2
            }
        } catch {
            throw PerchError("Restoring resized history failed: visible=\(store.chatHistoryVisible), width=\(defaults.double(forKey: "chatHistoryWidth")), inputX=\(fullInput.convert(fullInput.bounds, to: historyRoot).minX), expected=\(expandedInputX + 80)")
        }
        print("PASS: resized history width survives collapse and reopen")
        dragHistory(10000)
        try await wait { abs(defaults.double(forKey: "chatHistoryWidth") - 360) < 1 }
        print("PASS: history maximum width")
        dragHistory(-10000)
        try await wait { abs(defaults.double(forKey: "chatHistoryWidth") - 180) < 1 }
        print("PASS: history minimum width")
        dragHistory(60)
        try await wait {
            historyRoot.layoutSubtreeIfNeeded()
            return abs(fullInput.convert(fullInput.bounds, to: historyRoot).minX - expandedInputX) < 2
        }
        print("PASS: Chat toolbar buttons precede pin with matching frames, warm gutter pixels, native history dragging and persistent width limits")
        store.chatHistoryVisible = false
        print("PASS: Chat defaults open, footer collapse aligns with archive, expand keeps its height and clears the composer, and the top settings shortcut is absent")
        print("PASS: full Chat PNG/TIFF/JPEG clipboard paste, attachment limits, IME redraw and left history sidebar layout")
        print("PASS: native composer @ filtering, keyboard reference selection and full-page draft/reference continuity")
        store.ai.drafts[store.chatOwner] = ""
        try await wait { fullInput.string.isEmpty }
        guard fullInput.showsPlaceholder else { throw PerchError("Empty composer did not show placeholder; marked=\(fullInput.hasMarkedText())") }
        fullInput.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
        guard fullInput.hasMarkedText() && !fullInput.showsPlaceholder else {
            throw PerchError("First IME letter placeholder state invalid; marked=\(fullInput.hasMarkedText()), placeholder=\(fullInput.showsPlaceholder)")
        }
        guard store.ai.drafts[store.chatOwner]?.isEmpty == true else { throw PerchError("First IME letter prematurely changed the draft") }
        store.ai.draftFiles[store.chatOwner] = []
        try await Task.sleep(nanoseconds: 150_000_000)
        guard fullInput.string == "a" && fullInput.hasMarkedText() && !fullInput.showsPlaceholder else {
            throw PerchError("IME redraw changed composition: text=\(fullInput.string), marked=\(fullInput.hasMarkedText())")
        }
        fullInput.setMarkedText("adai", selectedRange: NSRange(location: 4, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
        guard !fullInput.showsPlaceholder else { throw PerchError("Placeholder visible during longer composition") }
        fullInput.insertText("阿黛", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await wait { store.ai.drafts[store.chatOwner] == "阿黛" }
        guard !fullInput.showsPlaceholder else { throw PerchError("Placeholder visible after composition commit") }
        fullInput.insertText("", replacementRange: NSRange(location: 0, length: fullInput.string.utf16.count))
        try await wait { fullInput.showsPlaceholder && store.ai.drafts[store.chatOwner]?.isEmpty == true }
        fullInput.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
        fullInput.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
        fullInput.unmarkText()
        guard fullInput.showsPlaceholder else { throw PerchError("Placeholder did not return after composition cancellation: \(fullInput.string)") }
        print("PASS: placeholder hides on the first IME letter, survives redraw, and returns after deletion or composition cancellation")
        func markdownViews(in view: NSView) -> [AIMarkdownWebView] {
            (view as? AIMarkdownWebView).map { [$0] } ?? view.subviews.flatMap { markdownViews(in: $0) }
        }
        store.ai.seedPreview()
        store.ai.saveConversations()
        try await wait { markdownViews(in: historyRoot).contains { $0.visibleRect.width > 20 && $0.visibleRect.height > 20 && $0.bounds.height > 300 } }
        let initialAnswer = markdownViews(in: historyRoot).first { $0.bounds.height > 300 }!
        var scrollAncestor = initialAnswer.superview
        while scrollAncestor != nil && !(scrollAncestor is NSScrollView) { scrollAncestor = scrollAncestor?.superview }
        let editScroll = scrollAncestor as! NSScrollView
        editScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editScroll.documentView!.bounds.height - editScroll.contentSize.height)))
        editScroll.reflectScrolledClipView(editScroll.contentView)
        precondition(editScroll.contentView.bounds.origin.y > 50)
        let editOwner = store.chatOwner
        let editMessage = store.ai.sessions[editOwner]!.messages[0]
        let preservedIDs = store.ai.sessions[editOwner]!.messages.map(\.id)
        let priorDraft = store.ai.drafts[editOwner]
        _ = store.ai.editMessage(editMessage.id, tab: editOwner)
        try await wait { fullInput.string == editMessage.text }
        try await Task.sleep(nanoseconds: 100_000_000)
        try await wait { editScroll.contentView.bounds.origin.y < 30 }
        window.makeFirstResponder(fullInput)
        let escaped = fullInput.delegate?.textView?(fullInput, doCommandBy: NSSelectorFromString("cancelOperation:"))
        precondition(escaped == true)
        try await wait { store.ai.pendingEdits[editOwner] == nil && fullInput.string == priorDraft }
        precondition(store.ai.sessions[editOwner]!.messages.map(\.id) == preservedIDs)
        _ = store.ai.editMessage(editMessage.id, tab: editOwner, fork: true)
        try await wait { fullInput.string == editMessage.text }
        precondition(store.ai.pendingEdits[editOwner]?.fork == true && store.ai.sessions[editOwner]!.messages.map(\.id) == preservedIDs)
        window.makeFirstResponder(fullInput)
        precondition(fullInput.delegate?.textView?(fullInput, doCommandBy: NSSelectorFromString("cancelOperation:")) == true)
        try await wait { store.ai.pendingEdits[editOwner] == nil && fullInput.string == priorDraft }
        func historyTables(in view: NSView) -> [AIHistoryTable] {
            (view as? AIHistoryTable).map { [$0] } ?? view.subviews.flatMap { historyTables(in: $0) }
        }
        store.chatHistoryVisible = true
        try await wait {
            Set(historyTables(in: historyRoot).first?.conversationIDs.compactMap { $0 } ?? []) ==
                Set(store.ai.activeConversations.map(\.id))
        }
        let table = historyTables(in: historyRoot).first!
        table.scrollRowToVisible(0)
        let originalHistoryIDs = table.conversationIDs
        let webGroupRow = originalHistoryIDs.dropFirst().firstIndex(of: nil)!
        let chatGroupCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! AIHistoryCell
        guard chatGroupCell.disclosure?.shape.path != nil else { throw PerchError("History group chevron missing") }
        table.choose(0, modifiers: [])
        guard table.conversationIDs == [nil] + Array(originalHistoryIDs[webGroupRow...]),
              table.numberOfRows == table.conversationIDs.count else {
            throw PerchError("History collapse rows: \(originalHistoryIDs) → \(table.conversationIDs), count=\(table.numberOfRows)")
        }
        guard table.view(atColumn: 0, row: 0, makeIfNecessary: true) === chatGroupCell else {
            throw PerchError("History collapse replaced its header")
        }
        // Reverse while the native row transition is still running.
        table.choose(0, modifiers: [])
        table.choose(0, modifiers: [])
        table.choose(0, modifiers: [])
        try await Task.sleep(nanoseconds: 300_000_000)
        guard table.conversationIDs == originalHistoryIDs, table.numberOfRows == originalHistoryIDs.count else {
            throw PerchError("History reversal rows: \(table.conversationIDs), count=\(table.numberOfRows)")
        }
        guard abs(chatGroupCell.disclosure!.shape.transform.m12 + 1) < 0.01 else {
            throw PerchError("History reversal chevron rotation")
        }
        let headerLabel = chatGroupCell.subviews.compactMap { $0 as? NSTextField }.first!
        guard abs(chatGroupCell.disclosure!.frame.midY - headerLabel.frame.midY) < 1 else {
            throw PerchError("History chevron must remain beside its title")
        }
        print("PASS: history group chevrons, collapse/reopen and rapid reversal preserve both groups and conversation")
        let conversationRows = table.conversationIDs.indices.filter { table.conversationIDs[$0] != nil }
        let selectionIDs = Array(conversationRows.prefix(2).compactMap { table.conversationIDs[$0] })
        let firstHoverRow = table.rowView(atRow: conversationRows[0], makeIfNecessary: true) as! AIHistoryRow
        let nextHoverRow = table.rowView(atRow: conversationRows[1], makeIfNecessary: true) as! AIHistoryRow
        let hoverMove = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        firstHoverRow.setHovered(false, animated: false)
        nextHoverRow.setHovered(false, animated: false)
        let firstHoverCell = table.view(atColumn: 0, row: conversationRows[0], makeIfNecessary: true) as! AIHistoryCell
        firstHoverRow.mouseEntered(with: hoverMove)
        precondition(firstHoverRow.hovered && firstHoverCell.archiveButton!.isEnabled)
        firstHoverRow.mouseExited(with: hoverMove)
        nextHoverRow.mouseEntered(with: hoverMove)
        precondition(!firstHoverRow.hovered && nextHoverRow.hovered && !firstHoverCell.archiveButton!.isEnabled)
        try await Task.sleep(nanoseconds: 220_000_000)
        precondition(firstHoverCell.archiveButton!.alphaValue == 0)
        nextHoverRow.mouseExited(with: hoverMove)
        print("PASS: history hover follows rows and archive fade-out immediately disables its click target")
        table.deselectAll(nil)
        // Native mouseDown handles Control before AppKit can turn it into a context click.
        for id in selectionIDs {
            guard let row = table.conversationIDs.firstIndex(of: id) else { throw PerchError("History selection fixture disappeared") }
            let point = table.convert(NSPoint(x: 20, y: table.rect(ofRow: row).midY), to: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .control,
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 1, clickCount: 1, pressure: 1)!
            table.mouseDown(with: event)
        }
        guard table.selectedRowIndexes.count == 2 && store.chatOwner == editOwner else {
            throw PerchError("History Ctrl selection: expected 2 rows without changing owner, got \(table.selectedRowIndexes), ownerUnchanged=\(store.chatOwner == editOwner)")
        }
        guard let menuRow = table.conversationIDs.firstIndex(of: selectionIDs[0]),
              let menu = table.contextMenu(at: menuRow) else { throw PerchError("History context menu missing") }
        precondition(menu.items.last?.title == "归档 2 个对话" && table.selectedRowIndexes.count == 2)
        let copy = menu.items.first!
        let chatTabBeforeFork = store.selected
        let tabsBeforeFork = store.tabs.count
        _ = copy.target?.perform(copy.action!)
        try await wait { store.ai.recentConversations.count == 4 && store.chatOwner != editOwner }
        try await wait { Set(table.conversationIDs.compactMap { $0 }) == Set(store.ai.activeConversations.map(\.id)) }
        precondition(store.selected == chatTabBeforeFork && store.tabs.count == tabsBeforeFork &&
                     store.tabs.filter { $0.chatOwner != nil }.count == 1)
        let forkOwner = store.chatOwner
        precondition(store.ai.sessions[editOwner]!.messages.map(\.id) == preservedIDs)
        let allRows = table.conversationIDs.indices.filter { table.conversationIDs[$0] != nil }
        table.deselectAll(nil)
        table.choose(allRows.first!, modifiers: .control)
        table.choose(allRows[1], modifiers: .shift)
        precondition(table.selectedRowIndexes.count == 2)
        let deleteMenu = table.contextMenu(at: allRows[1])!
        let selectedIDs = Set(table.selectedRowIndexes.compactMap { table.conversationIDs[$0] })
        let remove = deleteMenu.items.last!
        _ = remove.target?.perform(remove.action!)
        try await wait { selectedIDs.allSatisfy { store.ai.conversations[$0]?.isArchived == true } }
        precondition(store.ai.activeConversations.allSatisfy { !selectedIDs.contains($0.id) })
        let archiveController = AIHistoryList(conversations: store.ai.archivedConversations, active: UUID(), open: { _ in },
                                            delete: { store.ai.deleteConversations($0) }, fork: { _ in }, archived: true,
                                            restore: { store.ai.restoreConversations($0) }).makeCoordinator()
        let archiveTable = AIHistoryTable()
        archiveController.table = archiveTable; archiveTable.dataSource = archiveController; archiveTable.delegate = archiveController
        archiveTable.makeMenu = { archiveController.menu($0) }; archiveController.refresh()
        let archiveRow = archiveTable.conversationIDs.firstIndex(where: { $0 != nil })!
        let archivedMenu = archiveTable.contextMenu(at: archiveRow)!
        precondition(archivedMenu.items.last?.title == "彻底删除对话")
        let restoreItem = archivedMenu.items.first { $0.title == "恢复对话" }!
        _ = restoreItem.target?.perform(restoreItem.action!)
        precondition(store.ai.archivedConversations.count == selectedIDs.count - 1)
        store.ai.deleteConversations(Set(store.ai.archivedConversations.map(\.id)))
        precondition(store.ai.archivedConversations.isEmpty)
        precondition(store.ai.sessions[editOwner]!.messages.map(\.id) == preservedIDs)
        try await wait { Set(table.conversationIDs.compactMap { $0 }) == Set(store.ai.activeConversations.map(\.id)) }
        table.scrollRowToVisible(0)
        let groupCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)!
        let plus = groupCell.subviews.compactMap { $0 as? NSButton }.first!
        historyRoot.layoutSubtreeIfNeeded()
        groupCell.layoutSubtreeIfNeeded()
        precondition(groupCell.bounds.contains(plus.frame), "Chat group plus must fit completely inside its row")
        precondition(abs(plus.frame.maxX - groupCell.bounds.maxX + 10) < 1, "Plus must remain on the right of Chat group")
        try await wait {
            historyRoot.layoutSubtreeIfNeeded()
            return table.visibleRect.contains(plus.convert(plus.bounds, to: table))
        }
        let plusPoint = plus.convert(NSPoint(x: plus.bounds.midX, y: plus.bounds.midY), to: groupCell.superview)
        let plusHit = groupCell.hitTest(plusPoint)
        precondition(plusHit === plus,
                     "Chat group plus must receive the click")
        let tabCountBeforeNew = store.tabs.count
        let tabBeforeNew = store.selected
        plus.performClick(nil)
        try await wait { store.ai.sessions[store.chatOwner] == nil }
        precondition(store.chatOwner == forkOwner && store.tabs.count == tabCountBeforeNew && store.selected == tabBeforeNew)
        precondition(store.ai.drafts[forkOwner] == "" && store.ai.pendingEdits[forkOwner] == nil)
        precondition(store.ai.sessions[editOwner]!.messages.map(\.id) == preservedIDs)
        let hoverRow = table.conversationIDs.firstIndex { $0 == store.ai.sessions[editOwner]?.id }!
        let hoverCell = table.view(atColumn: 0, row: hoverRow, makeIfNecessary: true) as! AIHistoryCell
        hoverCell.layoutSubtreeIfNeeded()
        let hoveredID = table.conversationIDs[hoverRow]!
        let hoverEvent = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        let hoverRowView = table.rowView(atRow: hoverRow, makeIfNecessary: true) as! AIHistoryRow
        hoverRowView.mouseEntered(with: hoverEvent)
        try await Task.sleep(nanoseconds: 220_000_000)
        precondition(hoverCell.archiveButton?.alphaValue == 1 && hoverCell.archiveButton?.isEnabled == true)
        let archiveButton = hoverCell.archiveButton!
        table.scrollRowToVisible(hoverRow)
        try await wait {
            historyRoot.layoutSubtreeIfNeeded()
            return table.visibleRect.contains(archiveButton.convert(archiveButton.bounds, to: table))
        }
        let archivePoint = archiveButton.convert(NSPoint(x: archiveButton.bounds.midX, y: archiveButton.bounds.midY), to: hoverCell.superview)
        let archiveHit = hoverCell.hitTest(archivePoint)
        precondition(archiveHit === archiveButton)
        hoverCell.archiveButton!.performClick(nil)
        try await wait { store.ai.conversations[hoveredID]?.isArchived == true }
        precondition(store.selected == tabBeforeNew && store.chatOwner == forkOwner, "Hover archive must not activate a conversation")
        store.ai.restoreConversations([hoveredID])
        store.openChat(owner: editOwner)
        store.chatHistoryVisible = false
        let closedPage = Tab(title: "Reopen fixture", address: "https://reopen.invalid/article")
        store.tabs.append(closedPage)
        store.ai.draftReferences[editOwner] = [closedPage.id]
        store.close(closedPage.id)
        precondition(store.ai.draftClosedReferences[editOwner]?.last?.title == "Reopen fixture")
        let selectedChat = store.selected
        let restored = store.restoreReference(store.ai.draftClosedReferences[editOwner]!.last!)
        precondition(restored != nil && store.selected == selectedChat && store.chatOwner == editOwner)
        let tabsAfterReopen = store.tabs.count
        precondition(store.restoreReference(store.ai.draftClosedReferences[editOwner]!.last!) === restored && store.tabs.count == tabsAfterReopen)
        precondition(store.restoreReference(AIPageReference(title: "invalid", url: URL(string: "file:///tmp"))) == nil)
        precondition(forkOwner != editOwner)
        print("PASS: rewind/Fork preview and native Esc, Ctrl/Shift selection, same-tab new conversation, contained plus, hover archive and reference recovery")
        try await wait { markdownViews(in: historyRoot).contains { $0.visibleRect.width > 20 && $0.visibleRect.height > 20 && $0.bounds.height > 300 } }
        let answer = markdownViews(in: historyRoot).first { $0.visibleRect.width > 20 && $0.visibleRect.height > 20 && $0.bounds.height > 300 }!
        var ancestor = answer.superview
        while ancestor != nil && !(ancestor is NSScrollView) { ancestor = ancestor?.superview }
        let conversationScroll = ancestor as! NSScrollView
        let offset = conversationScroll.contentView.bounds.origin.y
        let scrollEvent = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: offset > 50 ? 90 : -90, wheel2: 0, wheel3: 0)!)!
        answer.scrollWheel(with: scrollEvent)
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(abs(conversationScroll.contentView.bounds.origin.y - offset) > 10, "The actual full Chat view must scroll when the wheel is over an answer")
        print("PASS: real full Chat hierarchy scrolls over rendered answer text")
        var queueConfig = config
        queueConfig.baseURL = config.baseURL.replacingOccurrences(of: "/v1", with: "/slow")
        precondition(store.ai.save(queueConfig, key: "synthetic-key"))
        let queueOwner = store.chatOwner
        store.ai.cancelEditing(queueOwner)
        store.ai.draftReferences[queueOwner] = []; store.ai.draftClosedReferences[queueOwner] = []
        store.ai.draftFiles[queueOwner] = []
        store.ai.drafts[queueOwner] = ""
        precondition(store.ai.send("native queue start fixture", tab: queueOwner, browser: nil, usePage: false))
        try await wait { store.ai.sessions[queueOwner]?.messages.last?.text.isEmpty == false }
        try await wait { fullInput.isEditable }
        fullInput.string = "queued fixture native"
        let returnEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        precondition(fullInput.returnKey?(returnEvent) == true)
        fullInput.didChangeText()
        guard store.ai.queuedMessages[queueOwner]?.count == 1 && store.ai.drafts[queueOwner]?.isEmpty == true &&
              fullInput.string.isEmpty else {
            throw PerchError("Native Return did not queue and clear the busy composer")
        }
        if let directory = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"] {
            try await Task.sleep(nanoseconds: 100_000_000)
            let root = window.contentView!
            root.layoutSubtreeIfNeeded()
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("queue.png"))
            }
        }
        store.ai.stop(queueOwner)
        precondition(store.ai.pausedQueues.contains(queueOwner))
        store.ai.removeQueuedMessage(store.ai.queuedMessages[queueOwner]!.first!.id, tab: queueOwner)
        print("PASS: busy native composer remains editable; Return queues the message and clears the draft")
        try await readingUI(config: config)
        if let directory = ProcessInfo.processInfo.environment["PERCH_LAYOUT_EVIDENCE"] {
            let settingsAI = AIController(defaults: defaults, conversationDirectory: URL(fileURLWithPath: "/tmp/Perch/Conversations"))
            window.contentView = NSHostingView(rootView: AISettingsPage(ai: settingsAI, openChat: {}))
            try await Task.sleep(nanoseconds: 150_000_000)
            let root = window.contentView!
            root.layoutSubtreeIfNeeded()
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings.png"))
            }
        }
    }
    static func readingUI(config: AIConfiguration) async throws {
        let suite = "dev.perch.ai.reading-ui.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("perch-reading-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var record = AISession(origin: .chat)
        for index in 0..<8 {
            record.messages.append(AIMessage(role: "user", text: "Question \(index)"))
            record.messages.append(AIMessage(role: "assistant", text: "## Answer \(index)\n\n" +
                (0..<70).map { "Paragraph \($0): a long answer that wraps differently in the sidebar and full Chat." }.joined(separator: "\n\n")))
        }
        let other = AISession(messages: [AIMessage(role: "user", text: "Another conversation")], origin: .chat)
        let archive = AIConversationArchive(conversations: [record.id: record, other.id: other], tabs: [AIController.homeID: record.id])
        try JSONEncoder().encode(archive).write(to: directory.appendingPathComponent("conversations.json"))
        let ai = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(ai.save(config, key: "synthetic-key"))
        let store = Store(defaults: defaults)
        store.openChat(owner: AIController.homeID)
        let window = NSWindow(contentRect: NSRect(x: 160, y: 150, width: 850, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: AIChatSidebar(store: store, ai: ai, fullPage: true, close: {}))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func answers(in view: NSView) -> [AIMarkdownWebView] {
            (view as? AIMarkdownWebView).map { [$0] } ?? view.subviews.flatMap { answers(in: $0) }
        }
        func lastAnswer() -> AIMarkdownWebView? {
            answers(in: window.contentView!).first {
                ($0.navigationDelegate as? AIMarkdownView.Coordinator)?.text.hasPrefix("## Answer 7") == true
            }
        }
        func outer(_ answer: NSView) -> NSScrollView {
            var view = answer.superview
            while !(view is NSScrollView) { view = view?.superview }
            return view as! NSScrollView
        }
        do {
            try await wait(timeout: 15) {
                window.contentView!.layoutSubtreeIfNeeded()
                return lastAnswer().map { $0.bounds.height > 1800 && $0.visibleRect.height > 100 } == true
            }
        } catch { throw PerchError("Reading initial layout: heights=\(answers(in: window.contentView!).map { $0.bounds.height }), ready=\(ai.ready(for: AIController.homeID)), owner=\(store.chatOwner)") }
        var initialLayout: [CGFloat] = []
        var stableSince = Date()
        try await wait(timeout: 15) {
            window.contentView!.layoutSubtreeIfNeeded()
            guard let answer = lastAnswer() else { return false }
            let scroll = outer(answer)
            let layout = [answer.bounds.height, answer.convert(answer.bounds, to: scroll.documentView).minY,
                          scroll.contentView.bounds.minY, scroll.documentView!.bounds.height]
            if layout != initialLayout { initialLayout = layout; stableSince = Date() }
            return Date().timeIntervalSince(stableSince) > 0.3
        }
        let last = lastAnswer()!
        let scroll = outer(last)
        let top = last.convert(last.bounds, to: scroll.documentView).minY
        let distance = Int32((scroll.contentView.bounds.minY - top - 170).rounded())
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: distance, wheel2: 0, wheel3: 0)!
        wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(NSEvent.Phase.began.rawValue))
        last.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        try await Task.sleep(nanoseconds: 400_000_000)
        do {
            try await wait {
                guard let value = ai.readingPosition(for: record.id) else { return false }
                return value.messageID == record.messages.last!.id && value.offset >= 170 && value.offset < 300
            }
        } catch { throw PerchError("Reading capture: saved=\(String(describing: ai.readingPosition(for: record.id))), y=\(scroll.contentView.bounds.minY), answer top=\(last.convert(last.bounds, to: scroll.documentView).minY)") }
        let bookmark = ai.readingPosition(for: record.id)!
        guard let currentAnswer = lastAnswer() else { throw PerchError("Reading capture lost its rendered answer") }
        let visibleOffset = currentAnswer.convert(currentAnswer.bounds, to: scroll.documentView).minY - scroll.contentView.bounds.minY
        guard abs(visibleOffset + 170) < 2 else {
            throw PerchError("Reading capture viewport moved: offset=\(visibleOffset), bookmark=\(bookmark), initial renderer attached=\(last.window != nil)")
        }
        precondition(scroll.documentView!.bounds.height - scroll.contentSize.height - scroll.contentView.bounds.minY > 500)
        ai.saveConversations()
        let reloaded = AIController(defaults: defaults, conversationDirectory: directory)
        precondition(reloaded.readingPosition(for: record.id) == bookmark)
        precondition(reloaded.save(config, key: "synthetic-key"))
        window.contentView = NSHostingView(rootView: AIChatSidebar(store: store, ai: reloaded, fullPage: true, close: {}))
        func restored() -> Bool {
            window.contentView!.layoutSubtreeIfNeeded()
            guard let answer = lastAnswer(), answer.bounds.height > 1800 else { return false }
            let scroll = outer(answer)
            return abs(answer.convert(answer.bounds, to: scroll.documentView).minY - scroll.contentView.bounds.minY - visibleOffset) < 2
        }
        do { try await wait(timeout: 20, restored) }
        catch {
            let current = lastAnswer().map { answer -> String in
                let scroll = outer(answer)
                return "height=\(answer.bounds.height), top=\(answer.convert(answer.bounds, to: scroll.documentView).minY), y=\(scroll.contentView.bounds.minY), doc=\(scroll.documentView!.bounds.height)"
            } ?? "target not mounted"
            throw PerchError("Reading restart restore: \(current), saved=\(String(describing: reloaded.readingPosition(for: record.id)))")
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(restored(), "Delayed Markdown layout must retain the saved viewport")
        reloaded.resumeConversation(other.id, tab: AIController.homeID)
        try await wait { answers(in: window.contentView!).isEmpty }
        reloaded.resumeConversation(record.id, tab: AIController.homeID)
        try await wait(timeout: 20, restored)
        // Match the previous 350pt chat viewport after collapsing the 240pt history sidebar.
        store.chatHistoryVisible = false
        window.setContentSize(NSSize(width: 390, height: 600))
        try await wait(timeout: 20) {
            lastAnswer().map { $0.bounds.width < 330 && $0.bounds.height > 3000 } == true
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        try await wait(timeout: 20, restored)
        let conversationScroll = outer(lastAnswer()!)
        func wheelScroll(_ delta: Int32) async throws {
            let event = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!)!
            if let answer = answers(in: window.contentView!).first(where: { $0.bounds.intersection($0.visibleRect).height > 100 }) {
                answer.scrollWheel(with: event)
            } else { conversationScroll.scrollWheel(with: event) }
            try await Task.sleep(nanoseconds: 40_000_000)
            try await wait(timeout: 3) {
                window.contentView!.layoutSubtreeIfNeeded()
                return answers(in: window.contentView!).contains { $0.bounds.intersection($0.visibleRect).height > 100 }
            }
        }
        let beforeWheel = conversationScroll.contentView.bounds.minY
        try await wheelScroll(120)
        guard conversationScroll.contentView.bounds.minY < beforeWheel - 60 else {
            throw PerchError("Phase-less wheel was overridden: \(beforeWheel) → \(conversationScroll.contentView.bounds.minY)")
        }
        for _ in 0..<60 { try await wheelScroll(700) }
        precondition(conversationScroll.contentView.bounds.minY < 2, "Continuous upward scrolling must reach the first message")
        for _ in 0..<60 { try await wheelScroll(-700) }
        let bottomGap = conversationScroll.documentView!.bounds.height -
            conversationScroll.contentSize.height - conversationScroll.contentView.bounds.minY
        precondition(abs(bottomGap) < 4, "Continuous downward scrolling must reach the last message")
        print("PASS: phase-less mouse wheels and continuous scrolling across every long answer without a blank viewport"); fflush(stdout)
        try await wheelScroll(700)
        try await Task.sleep(nanoseconds: 400_000_000)
        let growing = lastAnswer()!
        let originalHeight = growing.bounds.height
        let originalOffset = growing.convert(growing.bounds, to: conversationScroll.documentView).minY -
            conversationScroll.contentView.bounds.minY
        let originalText = (growing.navigationDelegate as! AIMarkdownView.Coordinator).text
        AIMarkdownView.render(originalText + "\n\n" + String(repeating: "A newly streamed long paragraph with more content.\n\n", count: 100), web: growing)
        try await wait { growing.bounds.height > originalHeight + 1500 }
        try await Task.sleep(nanoseconds: 400_000_000)
        let grownOffset = growing.convert(growing.bounds, to: conversationScroll.documentView).minY -
            conversationScroll.contentView.bounds.minY
        precondition(abs(grownOffset - originalOffset) < 2, "A new long block must not move a reader who left the bottom")
        precondition(answers(in: window.contentView!).count <= 3, "Offscreen answers must release their WebKit renderers")
        print("PASS: new long Markdown block retains the reader's position; offscreen renderers are released"); fflush(stdout)
        let saved = reloaded.readingPosition(for: record.id)!
        reloaded.saveConversations()
        let fork = reloaded.forkConversation(record.id)!
        precondition(reloaded.readingPosition(for: fork) == nil)
        precondition(reloaded.readingPosition(for: record.id) == saved)
        print("PASS: conversation viewport persisted and restored after restart, same-owner history switch, delayed Markdown and sidebar width; Fork has an independent bookmark")
    }

    static func keychain() throws {
        let store = AIKeyStore(memoryOnly: false, service: "dev.perch.synthetic-ai.\(UUID())")
        let account = "fixture|https://fixture.invalid/v1/chat/completions"
        defer { try? store.write(nil, account: account) }
        let absent = try store.read(account)
        precondition(absent == nil)
        try store.write("synthetic-key-one", account: account)
        let first = try store.read(account)
        precondition(first == "synthetic-key-one")
        try store.write("synthetic-key-two", account: account)
        let second = try store.read(account)
        precondition(second == "synthetic-key-two")
        try store.write(nil, account: account)
        let removed = try store.read(account)
        precondition(removed == nil)
        print("PASS: stable AI Keychain helper, synthetic write/read/update/delete without prompts")
    }
    // Only invoked explicitly, with a caller-supplied endpoint and credential variable.
    static func connection() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["PERCH_AI_TEST_URL"], let variable = environment["PERCH_AI_TEST_KEY_VARIABLE"] else {
            throw PerchError("Provide the connectivity check endpoint and credential variable through the environment.")
        }
        let key = try await Task.detached { try AIEnvironment.key(variable) }.value
        let suite = "dev.perch.ai.connection.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ai = AIController(defaults: defaults)
        var config = AIConfiguration(provider: .custom, baseURL: base, model: "pending")
        if let name = environment["PERCH_AI_TEST_PROTOCOL"], let value = AIProtocol(rawValue: name) { config.apiProtocol = value }
        let models = try await ai.models(for: config, key: key)
        config.model = environment["PERCH_AI_TEST_MODEL"] ?? models[0]
        guard models.contains(config.model) else { throw PerchError("Requested model was not discovered.") }
        config.models = [config.model]
        guard ai.save(config, key: key) else { throw PerchError("Unable to configure the isolated connectivity check.") }
        let tab = UUID()
        var files: [AIAttachment] = []
        if let path = environment["PERCH_AI_TEST_FILE"] { files = [try AIAttachment.read(URL(fileURLWithPath: path))] }
        ai.send(files.isEmpty ? "Reply with exactly OK." : "Read the attached file and reply with its verification code only.", tab: tab, browser: nil, usePage: false, attachments: files)
        try await wait(timeout: 90) { ai.sessions[tab]?.requestID == nil }
        guard ai.sessions[tab]?.error == nil, ai.sessions[tab]?.messages.last?.text.isEmpty == false else {
            throw PerchError(ai.sessions[tab]?.error ?? "No response received.")
        }
        if let expected = environment["PERCH_AI_TEST_EXPECTED"] {
            guard ai.sessions[tab]?.messages.last?.text.contains(expected) == true else { throw PerchError("Model response did not contain the file verification code.") }
        }
        print("PASS: environment Key import, \(models.count) models, real \(config.model) stream and \(files.count) attachment(s); no production configuration changed")
    }
}
