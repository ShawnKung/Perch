import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers

private final class AIChatScheme: NSObject, WKURLSchemeHandler {
    static let url = URL(string: "perch-chat://conversation/")!
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard task.request.url == Self.url else { task.didFailWithError(URLError(.unsupportedURL)); return }
        let data = InternalPage.document("chat")
        task.didReceive(URLResponse(url: Self.url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class AIChatWebView: WKWebView {
    weak var controller: AIChatPageController?
    private var hoverTracker: AIWebHoverTracker?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        hoverTracker = window == nil ? nil : AIWebHoverTracker(web: self, world: .defaultClient)
        if window == nil { controller?.suspend() }
        else { controller?.update() }
    }
}

struct AIChatPage: NSViewRepresentable {
    let controller: AIChatPageController
    @ObservedObject var store: Store
    @ObservedObject var ai: AIController
    let owner: UUID
    let fullPage: Bool
    func makeNSView(context: Context) -> WebPageContainer { WebPageContainer() }
    func updateNSView(_ view: WebPageContainer, context: Context) {
        controller.bind(store: store, ai: ai, owner: owner, fullPage: fullPage)
        view.show(controller.web)
        controller.update()
    }
}

// The bridge owns presentation and native actions; requests and drafts remain in AIController.
@MainActor
final class AIChatPageController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var store: Store?
    private var controllerAI: AIController?
    private(set) var owner = AIController.homeID
    private(set) var fullPage = false
    private(set) var web: AIChatWebView!
    private(set) var ready = false
    private var fileTask: Task<Void, Never>?
    private var fileTaskID: UUID?
    private var fileError: String?
    private var mermaidLoaded = false
    private var focusRequest: UUID?
    private var draftRevision = 0
    private var thumbnails: [UUID: String] = [:]
    private var savedFiles: [UUID: URL] = [:]
    let markdown = AIMarkdownView.Coordinator(height: .constant(0))
    private var ai: AIController { controllerAI! }
    private var session: AISession { ai.sessions[owner] ?? AISession(id: owner) }
    private var canEdit: Bool { session.isArchived != true }

    func bind(store: Store, ai: AIController, owner: UUID, fullPage: Bool) {
        if self.owner != owner {
            cancelFiles(); fileError = nil
            draftRevision = 0; focusRequest = nil
        }
        self.store = store; controllerAI = ai; self.owner = owner; self.fullPage = fullPage
        guard web == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(AIChatScheme(), forURLScheme: "perch-chat")
        for name in ["marked.js", "purify.js", "diagram.js", "tables.js", "chat.js"] {
            let source = (AIMarkdownView.asset(name) ?? "")
                .replacingOccurrences(of: "window.webkit.messageHandlers.markdown.postMessage(", with: "window.perchMarkdown(")
            config.userContentController.addUserScript(WKUserScript(source: source,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        InternalPage.install("chat", handler: self, in: config)
        web = AIChatWebView(frame: .zero, configuration: config)
        web.controller = self; web.navigationDelegate = self
        PerchTheme.shared.register(web)
        web.load(URLRequest(url: AIChatScheme.url))
        markdown.openURL = { [weak store] in store?.openReferencedPage($0) }
    }
    deinit { fileTask?.cancel() }
    func suspend() {
        markdown.citationPreview.close()
        web?.callAsyncJavaScript("window.perchSuspend?.()", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
    }
    private func encoded<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return object
    }
    func update() {
        guard ready, let store, let web, web.window != nil else { return }
        PerchTheme.shared.update(web)
        let value = session
        let provider = ai.provider(for: owner)
        let messages: [[String: Any]] = value.messages.map { message in
            var result: [String: Any] = [
                "id": message.id.uuidString, "role": message.role, "text": message.text,
                "providerName": message.providerName ?? provider.name, "quote": encoded(message.quote),
                "references": encoded(message.references), "source": message.source ?? "",
                "sourceURL": message.sourceURL?.absoluteString ?? "", "reasoning": message.reasoning ?? "",
                "searchSources": encoded(message.searchSources ?? []), "searchStatus": message.searchStatus ?? "",
                "generatedFiles": encoded(message.generatedFiles ?? []), "clarification": encoded(message.clarification),
                "followups": message.followups ?? []
            ]
            result["attachments"] = message.attachments.map { ["id": $0.id.uuidString, "name": $0.name, "image": $0.isImage] as [String: Any] }
            result["timestamp"] = message.timestamp?.formatted(date: .numeric, time: .standard) ?? ""
            result["searchVisible"] = AISearchEvidence.isVisible(message)
            result["phase"] = value.requestID != nil && message.id == value.messages.last?.id ? (value.phase ?? .waiting).title : ""
            result["versions"] = Dictionary(uniqueKeysWithValues: (message.generatedFiles ?? []).map {
                ($0.id.uuidString, encoded(value.fileVersions(name: $0.name, through: message.id)))
            })
            return result
        }
        if !mermaidLoaded && value.messages.contains(where: { $0.text.contains("mermaid") }) {
            mermaidLoaded = true
            web.evaluateJavaScript(AIMarkdownView.asset("mermaid.js") ?? "", in: nil, in: .defaultClient) { [weak self] _ in self?.update() }
        }
        markdown.sources = value.messages.flatMap { $0.searchSources ?? [] }
        let pages = store.tabs.filter { !$0.address.isEmpty && !$0.isChat }
        let files: [[String: Any]] = (ai.draftFiles[owner] ?? []).map {
            var item: [String: Any] = ["id": $0.id.uuidString, "name": $0.name]
            if $0.isImage {
                if thumbnails[$0.id] == nil, let image = NSImage(data: $0.data), image.size.width > 0, image.size.height > 0 {
                    let scale = min(1, 76 / max(image.size.width, image.size.height))
                    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                    let thumbnail = NSImage(size: size, flipped: false) { rect in
                        image.draw(in: rect); return true
                    }
                    thumbnails[$0.id] = InternalPage.icon(thumbnail)
                }
                item["image"] = thumbnails[$0.id]
            }
            return item
        }
        let fileIDs = Set((ai.draftFiles[owner] ?? []).map(\.id))
        thumbnails = thumbnails.filter { fileIDs.contains($0.key) }
        let native = provider.nativeSearch.definition(protocol: provider.apiProtocol) != nil
        let sources: [[String: Any]] = [
            ["id": AISearchChoice.automatic.rawValue, "title": "自动", "enabled": true],
            ["id": AISearchChoice.native.rawValue, "title": native ? "模型原生搜索" : "模型原生搜索（未启用）", "enabled": native],
            ["id": AISearchChoice.deepSeek.rawValue, "title": ai.searchConfiguration.map { "独立搜索 · \($0.name)" } ?? "独立搜索（未配置）", "enabled": ai.searchHasKey]
        ]
        if let request = ai.composerFocusRequests[owner] {
            focusRequest = request
            DispatchQueue.main.async { [weak self] in
                guard let self, self.ai.composerFocusRequests[self.owner] == request else { return }
                self.ai.composerFocusRequests[self.owner] = nil
            }
        }
        var state: [String: Any] = ["owner": owner.uuidString, "conversation": value.id.uuidString]
        state["fullPage"] = fullPage
        state["ready"] = ai.ready(for: owner)
        state["provider"] = provider.name
        state["busy"] = value.requestID != nil
        state["archived"] = value.isArchived == true
        state["messages"] = messages
        state["error"] = value.error ?? ""
        state["storageError"] = ai.storageError ?? ""
        state["fileError"] = fileError ?? ""
        state["loadingFiles"] = fileTask != nil
        state["draft"] = ai.drafts[owner] ?? ""
        state["draftRevision"] = draftRevision
        if let selection = ai.composerSelections[owner] {
            state["selection"] = ["start": selection.start, "end": selection.end,
                                  "scroll": selection.scroll, "focused": selection.focused] as [String: Any]
        }
        state["quote"] = encoded(ai.draftQuotes[owner])
        state["files"] = files
        state["references"] = (ai.draftReferences[owner] ?? []).map(\.uuidString)
        state["closedReferences"] = encoded(ai.draftClosedReferences[owner] ?? [])
        state["pages"] = pages.map { ["id": $0.id.uuidString, "title": $0.title, "address": $0.address] }
        state["edit"] = ai.pendingEdits[owner]?.messageID.uuidString ?? ""
        state["fork"] = ai.pendingEdits[owner]?.fork == true
        state["queue"] = (ai.queuedMessages[owner] ?? []).map {
            ["id": $0.id.uuidString, "question": $0.question, "files": $0.attachments.count] as [String: Any]
        }
        state["paused"] = ai.pausedQueues.contains(owner)
        state["reading"] = encoded(ai.readingPosition(for: value.id))
        state["focus"] = focusRequest?.uuidString ?? ""
        state["sendWithCommand"] = store.settings.aiSendWithCommand
        state["providers"] = ai.providers.map { ["id": $0.id.uuidString, "name": $0.name, "models": $0.models] as [String: Any] }
        state["providerID"] = provider.id.uuidString
        state["model"] = ai.model(for: owner)
        state["searchEnabled"] = ai.searchEnabled(for: owner)
        state["searchSource"] = ai.searchChoice(for: owner).rawValue
        state["searchSources"] = sources
        state["colors"] = PerchTheme.shared.selection.webColors
        InternalPage.update(state, web: web)
    }
    private func focus() { focusRequest = UUID() }
    private func cancelFiles() { fileTask?.cancel(); fileTask = nil; fileTaskID = nil }
    private func fail(_ error: Error) { fileError = (error as? PerchError)?.message ?? error.localizedDescription; update() }
    func newChat() {
        guard let store else { return }
        cancelFiles(); fileError = nil
        store.newChat()
        ai.composerFocusRequests[store.chatOwner] = UUID()
    }
    func exportMarkdown() {
        guard store != nil else { return }
        let value = session.markdown, panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        let name = session.title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r")).joined(separator: "-")
        panel.nameFieldStringValue = (name.isEmpty ? "Chat" : name) + ".md"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try value.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.fail(error) }
        }
    }
    private func addFiles(_ added: [AIAttachment], owner: UUID) throws {
        let files = (ai.draftFiles[owner] ?? []) + added
        guard files.count <= 5, files.reduce(0, { $0 + $1.data.count }) <= 12 * 1024 * 1024 else {
            throw PerchError("最多添加 5 个文件，总大小不能超过 12 MB。")
        }
        ai.draftFiles[owner] = files; fileError = nil
    }
    private func attach() {
        guard canEdit, fileTask == nil else { return }
        let panel = NSOpenPanel(), owner = owner, conversation = session.id
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "添加文本、代码、PDF 或图片（最多 5 个文件，共 12 MB）"
        panel.begin { [weak self] response in
            guard let self, response == .OK, self.owner == owner, self.session.id == conversation else { return }
            let urls = panel.urls, taskID = UUID()
            self.fileTaskID = taskID
            self.fileTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { if self.fileTaskID == taskID { self.fileTask = nil; self.fileTaskID = nil; self.update() } }
                do {
                    let added = try await Task.detached { try urls.map(AIAttachment.read) }.value
                    guard !Task.isCancelled, self.owner == owner, self.session.id == conversation, self.canEdit,
                          let store = self.store,
                          owner == AIController.homeID || owner == store.fullChatOwner || store.tabs.contains(where: { $0.id == owner || $0.aiOwner == owner }) else { return }
                    try self.addFiles(added, owner: owner)
                } catch { if !Task.isCancelled { self.fail(error) } }
            }
            self.update()
        }
    }
    private func send() {
        guard let store, canEdit, ai.ready(for: owner), fileTask == nil else { return }
        let text = ai.drafts[owner] ?? "", files = ai.draftFiles[owner] ?? []
        guard text.count <= 8000, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        let references = ai.draftReferences[owner] ?? []
        var pages = references.compactMap { store.referenceBrowser($0) }
        guard pages.count == references.count else { fail(PerchError("引用的标签页无法读取，请重试。")); return }
        for reference in ai.draftClosedReferences[owner] ?? [] {
            guard let browser = store.restoreReference(reference) else {
                fail(PerchError("无法恢复引用「\(reference.title)」，请移除或重新选择后发送。")); return
            }
            if !pages.contains(where: { $0 === browser }) { pages.append(browser) }
        }
        if ai.send(text, tab: owner, browser: nil, usePage: false, attachments: files, pages: pages,
                   availablePageProvider: { [weak store] in store?.loadedReferencePages ?? [] },
                   origin: !fullPage && store.browser != nil ? .web : .chat,
                   sidebarURL: fullPage ? nil : store.currentPageURL, quote: ai.draftQuotes[owner]) {
            ai.drafts[owner] = ""; ai.draftFiles[owner] = []; ai.draftReferences[owner] = []
            ai.draftClosedReferences[owner] = []; ai.draftQuotes[owner] = nil; fileError = nil
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard InternalPage.accepts(message, web: web, matches: { $0 == AIChatScheme.url }),
              let body = message.body as? [String: Any], let action = body["action"] as? String, let store else { return }
        if action == "ready" {
            ready = true
            web.callAsyncJavaScript("window.perchDiagramStyle(css)", arguments: ["css": AIDiagram.assets.style],
                                    in: nil, in: .defaultClient, completionHandler: nil)
            update(); return
        }
        guard body["owner"] as? String == owner.uuidString,
              body["conversation"] as? String == session.id.uuidString else { return }
        let id = (body["id"] as? String).flatMap(UUID.init(uuidString:))
        if action == "inputState", let start = body["start"] as? Int, let end = body["end"] as? Int,
           let scroll = body["scroll"] as? Double, start >= 0, end >= start, scroll.isFinite {
            ai.composerSelections[owner] = (start, end, max(0, scroll), body["focused"] as? Bool == true)
            return
        }
        if action == "reading", let id, let offset = body["offset"] as? Double, offset.isFinite {
            ai.rememberReadingPosition(AIReadingPosition(messageID: id, offset: offset), conversation: session.id)
            return
        }
        guard web.window != nil else { return }
        switch action {
        case "draft", "send":
            guard canEdit, let text = body["text"] as? String, let revision = body["revision"] as? Int,
                  revision >= draftRevision else { return }
            draftRevision = revision; ai.drafts[owner] = text
            if action == "send" { send() }
        case "stop": ai.stop(owner)
        case "attach": attach()
        case "pasteImage":
            guard canEdit else { return }
            do { if let file = try AIAttachment.pasteImage(.general) { try addFiles([file], owner: owner) } }
            catch { fail(error) }
        case "removeFile": if canEdit { ai.draftFiles[owner]?.removeAll { $0.id == id } }
        case "removeReference": if canEdit { ai.draftReferences[owner]?.removeAll { $0 == id }; ai.draftClosedReferences[owner]?.removeAll { $0.id == id } }
        case "removeQuote":
            guard canEdit else { return }
            if let expected = body["text"] as? String {
                guard let quote = ai.draftQuotes[owner], quote.messageID == id, quote.text == expected else { return }
            }
            ai.draftQuotes[owner] = nil
        case "reference":
            guard canEdit, let id, store.tabs.contains(where: { $0.id == id && !$0.address.isEmpty && !$0.isChat }) else { return }
            if !(ai.draftReferences[owner] ?? []).contains(id) { ai.draftReferences[owner, default: []].append(id) }
            _ = store.referenceBrowser(id)
        case "edit", "fork":
            guard let id, ai.editMessage(id, tab: owner, fork: action == "fork") != nil else { return }
            cancelFiles(); fileError = nil; focus()
        case "cancelEdit": cancelFiles(); ai.cancelEditing(owner); fileError = nil; focus()
        case "copy":
            guard let value = session.messages.first(where: { $0.id == id })?.text else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        case "quote":
            let range = body["range"] as? [String: Int]
            let sourceRange = range.flatMap { value -> AIQuote.SourceRange? in
                guard let start = value["start"], let end = value["end"] else { return nil }
                return AIQuote.SourceRange(start: start, end: end)
            }
            guard let id, let text = body["text"] as? String,
                  ai.quoteSelection(text, messageID: id, tab: owner, sourceRange: sourceRange) else { return }
            focus()
        case "followup", "fillFollowup":
            guard let id, let text = body["text"] as? String else { return }
            if action == "fillFollowup" { ai.fillFollowup(text, messageID: id, tab: owner); focus() }
            else {
                _ = ai.sendFollowup(text, messageID: id, tab: owner,
                    availablePages: { [weak store] in store?.loadedReferencePages ?? [] },
                    origin: !fullPage && store.browser != nil ? .web : .chat, sidebarURL: fullPage ? nil : store.currentPageURL)
            }
        case "clarify":
            if let id, let answers = body["answers"] as? [String] {
                _ = ai.answerClarification(answers, messageID: id, tab: owner, availablePages: { [weak store] in store?.loadedReferencePages ?? [] })
            }
        case "restore": ai.restoreConversations([session.id])
        case "resumeQueue": ai.resumeQueue(owner)
        case "removeQueue": if let id { ai.removeQueuedMessage(id, tab: owner) }
        case "model":
            if let id, let model = body["model"] as? String { ai.selectModel(model, provider: id, tab: owner) }
        case "searchEnabled": ai.setSearchEnabled(!ai.searchEnabled(for: owner), tab: owner)
        case "searchSource":
            if let raw = body["source"] as? String, let source = AISearchChoice(rawValue: raw) { ai.setSearchSource(source, tab: owner) }
        case "settings": ai.select(ai.provider(for: owner).id); store.library = .ai
        case "open":
            if let raw = body["url"] as? String, let url = URLInput.parse(raw, search: false) { store.openReferencedPage(url) }
        case "file": fileAction(body)
        case "markdown":
            // Share native exports, table/diagram viewers and citation previews with the existing renderer.
            if let payload = body["payload"] as? [String: Any] {
                if let id, let message = session.messages.first(where: { $0.id == id }) {
                    markdown.sources = message.searchSources ?? []
                }
                markdown.handle(payload, web: web)
            }
            return
        default: break
        }
        update()
    }
    private func fileAction(_ body: [String: Any]) {
        guard let raw = body["message"] as? String, let messageID = UUID(uuidString: raw),
              let card = body["card"] as? String, let cardID = UUID(uuidString: card),
              let current = session.messages.first(where: { $0.id == messageID })?.generatedFiles?.first(where: { $0.id == cardID }),
              let rawID = body["id"] as? String, let id = UUID(uuidString: rawID),
              let file = session.fileVersions(name: current.name, through: messageID).first(where: { $0.id == id }) else { return }
        let complete: (Result<URL, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            var state: [String: Any] = ["id": id.uuidString]
            switch result {
            case .success(let url): self.savedFiles[id] = url; state["saved"] = true
            case .failure(let error): state["error"] = error.localizedDescription
            }
            self.web.callAsyncJavaScript("window.perchFileResult?.(state)", arguments: ["state": state], in: nil, in: .defaultClient, completionHandler: nil)
        }
        switch body["operation"] as? String {
        case "download":
            do {
                let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                complete(.success(try file.download(to: directory)))
            } catch { complete(.failure(error)) }
        case "save": file.saveAs(window: web.window, completion: complete)
        case "copy": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.content, forType: .string)
        case "reveal": if let url = savedFiles[id] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case "diff":
            let versions = session.fileVersions(name: file.name, through: messageID)
            guard let index = versions.firstIndex(where: { $0.id == id }), index > 0 else { return }
            let text = String(AIFileDifference.text(from: versions[index - 1].content, to: file.content).characters)
            web.callAsyncJavaScript("window.perchFileDifference?.(id,text)", arguments: ["id": id.uuidString, "text": text], in: nil, in: .defaultClient, completionHandler: nil)
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true {
            decisionHandler(action.request.url == AIChatScheme.url ? .allow : .cancel)
        } else {
            decisionHandler(action.navigationType == .other && action.request.url?.absoluteString == "about:srcdoc" ? .allow : .cancel)
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; mermaidLoaded = false; markdown.citationPreview.close(); webView.reload()
    }
}
