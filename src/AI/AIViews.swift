import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AISearchMenu: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var ai: AIController
    let tab: UUID
    var body: some View {
        let native = ai.provider(for: tab).nativeSearch.definition(protocol: ai.provider(for: tab).apiProtocol) != nil
        let choice = ai.searchChoice(for: tab)
        let enabled = ai.searchEnabled(for: tab)
        HStack(spacing: 2) {
            Button {
                ai.setSearchEnabled(!enabled, tab: tab)
            } label: {
                ZStack {
                    Circle().fill(enabled ? Style.accent : Color.gray.opacity(0.16))
                    Image(systemName: "globe").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(enabled ? Color.white : Color.gray)
                    if !enabled {
                        Rectangle().fill(Color.gray).frame(width: 21, height: 2)
                            .rotationEffect(.degrees(-45))
                    }
                }.frame(width: 28, height: 28).contentShape(Circle())
            }.buttonStyle(.plain)
                .accessibilityLabel("联网搜索")
                .accessibilityValue(enabled ? "开启" : "关闭")
                .help(enabled ? "联网已开启 · 点击关闭" : "联网已关闭 · 点击开启")
            Menu {
                Picker("联网方式", selection: Binding(get: { choice }, set: { ai.setSearchSource($0, tab: tab) })) {
                    Text("自动").tag(AISearchChoice.automatic)
                    Text(native ? "模型原生搜索" : "模型原生搜索（未启用）")
                        .tag(AISearchChoice.native).disabled(!native)
                    if let search = ai.searchConfiguration {
                        Text("独立搜索 · \(search.name)").tag(AISearchChoice.deepSeek).disabled(!ai.searchHasKey)
                    } else if choice == .deepSeek {
                        Text("独立搜索（未配置）").tag(AISearchChoice.deepSeek).disabled(true)
                    }
                }.pickerStyle(.inline).labelsHidden()
                if choice == .automatic {
                    Divider()
                    Text(native ? "自动选择：模型原生搜索" :
                         ai.searchHasKey ? "自动选择：\(ai.searchConfiguration?.name ?? "独立搜索")" :
                         "暂无可用的联网方式").disabled(true)
                }
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.gray).frame(width: 18, height: 28).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("选择联网方式")
                .help("选择自动、模型原生搜索或独立搜索供应商")
        }
    }
}

struct AIActivityHeader: View {
    @ObservedObject private var theme = PerchTheme.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let symbol: String
    @Binding var expanded: Bool
    var active = false
    var expandable = true
    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                if expandable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                Image(systemName: symbol).frame(width: 18, height: 18)
                Text(title).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if active {
                    if reduceMotion {
                        Image(systemName: "hourglass").frame(width: 14, height: 14)
                    } else {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    }
                }
            }
            .font(.system(size: theme.chatDetailFontSize, weight: .medium)).foregroundStyle(Style.muted)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).arrowCursor().accessibilityLabel(title)
        .accessibilityValue(expanded ? "已展开" : "已收起")
        .disabled(!expandable)
        .zIndex(1)
    }
}

struct AISearchEvidence: View {
    @ObservedObject private var theme = PerchTheme.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: AIMessage
    let openURL: (URL) -> Void
    @State private var expanded = false
    static func isVisible(_ message: AIMessage) -> Bool {
        if message.searchSources?.isEmpty == false { return true }
        guard let status = message.searchStatus else { return false }
        return !["已允许联网，等待模型调用", "本轮未调用搜索"].contains(status)
    }
    var body: some View {
        if Self.isVisible(message) {
            VStack(alignment: .leading, spacing: 6) {
                AIActivityHeader(title: "\(message.searchStatus ?? "联网搜索")\((message.searchSources ?? []).isEmpty ? "" : " · \(message.searchSources!.count) 个来源")",
                                 symbol: "globe", expanded: $expanded)
                if expanded {
                VStack(alignment: .leading, spacing: 6) {
                ForEach(message.searchSources ?? []) { source in
                    Button { openURL(source.url) } label: {
                        Text(source.title).font(.system(size: theme.chatFontSize(relativeTo: 11))).foregroundStyle(Style.muted)
                            .underline(true, pattern: .dash, color: Style.muted.opacity(0.65))
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).tint(Style.muted)
                    .background(AICitationHoverAnchor(source: source, openURL: openURL))
                }
                if message.searchSources?.isEmpty != false {
                    Text("暂无搜索来源").font(.system(size: theme.chatFontSize(relativeTo: 11))).foregroundStyle(Style.muted)
                }
                }.transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: expanded)
        }
    }
}

struct AIModelPicker: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var ai: AIController
    let tab: UUID
    let dismiss: () -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func models(_ value: AIConfiguration) -> [String] {
        value.models.filter { query.isEmpty || value.name.localizedCaseInsensitiveContains(query) || $0.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索模型…", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
                .font(.system(size: theme.chatFontSize))
                .accessibilityLabel("搜索模型")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        Color.clear.frame(height: 0).id("top")
                        ForEach(ai.providers) { value in
                            if !models(value).isEmpty {
                                Text(value.name).font(.system(size: theme.chatFontSize(relativeTo: 10), weight: .medium)).foregroundStyle(Style.muted)
                                    .padding(.top, 8).padding(.horizontal, 8)
                                ForEach(models(value), id: \.self) { model in
                                    let selected = ai.provider(for: tab).id == value.id && ai.model(for: tab) == model
                                    Button {
                                        ai.selectModel(model, provider: value.id, tab: tab); dismiss()
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text(model).lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 6)
                                            if selected { Image(systemName: "checkmark").foregroundStyle(Style.accent) }
                                        }.font(.system(size: theme.chatFontSize)).padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(selected ? Style.mint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain).help("\(value.name) · \(model)")
                                }
                            }
                        }
                        if ai.providers.allSatisfy({ models($0).isEmpty }) {
                            Text(query.isEmpty ? "请先在 AI 设置中添加模型。" : "没有匹配的模型")
                                .font(.system(size: theme.chatDetailFontSize)).foregroundStyle(Style.muted).padding(10)
                        }
                    }
                }.onChange(of: search) { _ in proxy.scrollTo("top", anchor: .top) }
            }
        }.padding(12).frame(width: 290, height: 350).background(Style.paper)
        .onAppear { searchFocused = true }
    }
}

final class AIReasoningTextView: NSTextView {
    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event)
    }
}

extension NSScrollView {
    func useTransientScrollers() {
        scrollerStyle = .overlay
        autohidesScrollers = true
        verticalScroller?.controlSize = .small
        horizontalScroller?.controlSize = .small
    }
    // AppKit may discard momentum delivered to a new target midway through a gesture.
    func scrollAIWheelContents(with event: NSEvent) {
        guard let document = documentView else { return }
        let maximum = max(0, document.bounds.height - contentSize.height)
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : verticalLineScroll)
        let y = contentView.bounds.minY + (document.isFlipped ? -delta : delta)
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: min(maximum, max(0, y))))
        reflectScrolledClipView(contentView)
        flashScrollers()
    }
}

final class AIReasoningScrollView: NSScrollView {
    let editor = AIReasoningTextView()
    var active = false
    private(set) var followsBottom = false
    private var applyingLayout = false
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, !self.isHiddenOrHasHiddenAncestor,
                  abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return event }
            let screenPoint = NSEvent.mouseLocation
            let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
            guard number == window.windowNumber else { return event }
            let point = window.convertPoint(fromScreen: screenPoint)
            guard let content = window.contentView,
                  let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else {
                return event
            }
            let hitRect = self.bounds.intersection(self.visibleRect)
            if hitRect.contains(self.convert(point, from: nil)),
               hit === self || hit.isDescendant(of: self) {
                self.scrollWheel(with: event)
                return nil
            }
            // A trackpad gesture can retain its original target after the pointer moves away.
            if let eventWindow = event.window, eventWindow !== window { return event }
            let originalPoint = event.window == nil
                ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
            guard hitRect.contains(self.convert(originalPoint, from: nil)) else { return event }
            var parent = self.superview
            while let view = parent {
                if let scroll = view as? NSScrollView,
                   hit === scroll || hit.isDescendant(of: scroll),
                   scroll.bounds.intersection(scroll.visibleRect).contains(scroll.convert(point, from: nil)) {
                    NotificationCenter.default.post(name: .aiChatUserScroll, object: scroll)
                    scroll.scrollAIWheelContents(with: event)
                    return nil
                }
                parent = view.superview
            }
            return event
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false; hasVerticalScroller = true; autohidesScrollers = true
        useTransientScrollers()
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.drawsBackground = false; editor.font = .systemFont(ofSize: 12)
        editor.textColor = NSColor(Style.muted)
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = false
        editor.setAccessibilityLabel("思考内容")
        documentView = editor
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    var bottom: CGFloat { max(0, editor.frame.height - contentSize.height) }
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event); return
        }
        followsBottom = false
        scrollAIWheelContents(with: event)
        scrolled()
    }
    @objc private func scrolled() {
        guard !applyingLayout else { return }
        followsBottom = bottom - contentView.bounds.minY <= 4
    }
    func update(text: String, active: Bool) {
        self.active = active
        if editor.string != text {
            if editor.string.isEmpty { followsBottom = active }
            let selection = editor.selectedRange()
            let origin = contentView.bounds.origin
            applyingLayout = true
            editor.string = text
            let count = (text as NSString).length
            let start = min(selection.location, count)
            editor.setSelectedRange(NSRange(location: start, length: min(selection.length, count - start)))
            contentView.scroll(to: origin)
            applyingLayout = false
        }
        needsLayout = true
    }
    func textHeight(width: CGFloat) -> CGFloat {
        guard let container = editor.textContainer, let manager = editor.layoutManager else { return 20 }
        container.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height) + 2
    }
    override func layout() {
        guard !applyingLayout else { return }
        applyingLayout = true
        defer { applyingLayout = false }
        let origin = contentView.bounds.origin
        super.layout()
        let height = max(contentSize.height, textHeight(width: contentSize.width))
        editor.setFrameSize(NSSize(width: contentSize.width, height: height))
        contentView.scroll(to: NSPoint(x: 0, y: active && followsBottom ? bottom : min(bottom, max(0, origin.y))))
        reflectScrolledClipView(contentView)
    }
}

struct AIReasoningText: NSViewRepresentable {
    @ObservedObject private var theme = PerchTheme.shared
    let text: String
    let active: Bool
    final class Container: NSView {
        let scroll = AIReasoningScrollView(frame: .zero)
        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(scroll)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            scroll.frame = bounds
            scroll.layoutSubtreeIfNeeded()
        }
    }
    func makeNSView(context: Context) -> Container { Container(frame: .zero) }
    func updateNSView(_ view: Container, context: Context) {
        if view.scroll.editor.font?.pointSize != CGFloat(theme.chatDetailFontSize) {
            view.scroll.editor.font = .systemFont(ofSize: theme.chatDetailFontSize)
        }
        view.scroll.update(text: text, active: active)
        view.needsLayout = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: min(220, nsView.scroll.textHeight(width: width)))
    }
}

struct AIReasoningView: View {
    @ObservedObject private var theme = PerchTheme.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    var phase: AIResponsePhase?
    var hasBody = false
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AIActivityHeader(title: phase?.title ?? "思考过程", symbol: "brain", expanded: $expanded,
                             active: phase != nil, expandable: !text.isEmpty)
            if expanded && !text.isEmpty {
            AIReasoningText(text: text, active: phase != nil)
                .frame(maxHeight: 220)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: expanded)
        .onAppear { expanded = !hasBody && phase == .thinking && !text.isEmpty }
        .onChange(of: phase) { if !hasBody && $0 == .thinking && !text.isEmpty { expanded = true } }
        .onChange(of: text.isEmpty) { if !hasBody && !$0 && phase == .thinking { expanded = true } }
        .onChange(of: hasBody) { if $0 { expanded = false } }
    }
}

struct AIChatSidebar: View {
    @StateObject private var page = AIChatPageController()
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    @ObservedObject var ai: AIController
    var fullPage = false
    var owner: UUID? = nil
    let close: () -> Void
    @State private var showArchived = false
    @State private var confirmClearArchive = false
    @AppStorage(LayoutPreference.chatHistoryWidth.rawValue) private var historyWidth = 240.0
    @State private var historyDragWidth: Double?
    @State private var liveHistoryWidth: Double?
    private var tab: UUID { owner ?? (fullPage ? store.fullChatOwner : store.chatOwner) }
    private var session: AISession { ai.sessions[tab] ?? AISession() }

    var body: some View {
        VStack(spacing: 0) {
            if !fullPage { header; Divider() }
            GeometryReader { geometry in
            HStack(spacing: 0) {
                if fullPage && store.chatHistoryVisible {
                    history.frame(width: liveHistoryWidth ?? Self.historySize(historyWidth, available: geometry.size.width))
                        .background(Style.sidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    SidebarResizeHandle(changed: { translation in
                        if historyDragWidth == nil {
                            historyDragWidth = Self.historySize(historyWidth, available: geometry.size.width)
                        }
                        liveHistoryWidth = Self.historySize(historyDragWidth! + translation, available: geometry.size.width)
                    }, ended: {
                        if let width = liveHistoryWidth { historyWidth = width }
                        liveHistoryWidth = nil; historyDragWidth = nil
                    })
                        .frame(width: 7, height: geometry.size.height).padding(.horizontal, -3)
                        .background(Style.sidebar)
                        .overlay(Style.line.frame(width: 1).allowsHitTesting(false))
                        .zIndex(20)
                        .accessibilityLabel("会话历史栏宽度")
                }
                chatContent
                    .padding(.leading, fullPage && !store.chatHistoryVisible ? 40 : 0)
                    .background(Style.paper)
                    .overlay(alignment: .bottomLeading) {
                        if fullPage && !store.chatHistoryVisible {
                            VStack(spacing: 8) {
                                GlyphButton(symbol: "square.and.arrow.up", label: "导出 Markdown", size: 24, action: exportMarkdown)
                                    .disabled(session.messages.isEmpty)
                                GlyphButton(symbol: "square.and.pencil", label: "新对话", size: 24, action: newChat)
                                historyToggle
                            }.padding(.leading, 8).padding(.bottom, 14)
                        }
                    }
            }.clipped()
                .transaction { if historyDragWidth != nil { $0.animation = nil; $0.disablesAnimations = true } }
            }
        }.font(.system(size: theme.chatFontSize)).clipped()
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22), value: store.chatHistoryVisible)
    }
    static func historySize(_ width: Double, available: Double) -> Double {
        min(max(width.isFinite ? width : 240, 180), min(360, max(180, available - 285)))
    }
    private var header: some View {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Style.accent)
                Text("AI 聊天").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if !fullPage {
                    Button(action: newChat) { Image(systemName: "square.and.pencil") }.help("新对话")
                        .accessibilityLabel("新对话")
                    Menu {
                        let records = ai.conversations(for: store.currentPageURL)
                        if records.isEmpty { Text("此网页暂无历史对话") }
                        ForEach(records) { record in
                            Button {
                                guard record.id != session.id else { return }
                                store.openSidebarConversation(record.id)
                            } label: {
                                if record.id == session.id { Label(record.title, systemImage: "checkmark") }
                                else { Text(record.title) }
                            }
                        }
                        Divider()
                        Button("全部历史对话…") { store.openChat(owner: tab) }
                    } label: { Image(systemName: "clock") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("历史对话").accessibilityLabel("历史对话")
                }
                if !fullPage {
                    Button { store.openChat(owner: tab) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("打开完整 Chat")
                    Button(action: close) { Image(systemName: "sidebar.right") }.help("收起 AI 侧栏")
                }
            }.buttonStyle(.plain).padding(.horizontal, 12)
                .frame(minHeight: 40).background(Style.paper).zIndex(10)
    }
    private var chatContent: some View {
        AIChatPage(controller: page, store: store, ai: ai, owner: tab, fullPage: fullPage)
            .onAppear {
                ai.classifyWebConversations(owners: Set(store.tabs.filter { !$0.address.isEmpty && !$0.isChat }.map { $0.aiOwner ?? $0.id }))
            }
    }
    private func newChat() {
        showArchived = false
        page.newChat()
    }
    private func exportMarkdown() {
        page.exportMarkdown()
    }
    private var historyToggle: some View {
        Button { ai.saveConversations(); store.chatHistoryVisible.toggle() } label: {
            Image(systemName: store.chatHistoryVisible ? "chevron.left" : "chevron.right")
                .font(.system(size: 13, weight: .semibold, design: .rounded)).frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Style.muted).arrowCursor()
            .help(store.chatHistoryVisible ? "收起历史侧栏" : "展开历史侧栏")
            .accessibilityLabel(store.chatHistoryVisible ? "收起历史侧栏" : "展开历史侧栏")
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label { Text("AI 聊天") } icon: { Image(systemName: "sparkles").foregroundStyle(Style.accent) }
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                GlyphButton(symbol: "square.and.arrow.up", label: "导出 Markdown", size: 24, action: exportMarkdown)
                    .disabled(session.messages.isEmpty)
                GlyphButton(symbol: "square.and.pencil", label: "新对话", size: 24, action: newChat)
            }.padding(.bottom, 8)
            AIHistoryList(conversations: showArchived ? ai.archivedConversations : ai.activeConversations, active: ai.sessions[tab]?.id,
                          open: { store.openChat(conversation: $0) },
                          delete: { if showArchived { ai.deleteConversations($0) } else { ai.archiveConversations($0) } },
                          fork: { if let id = ai.forkConversation($0) { store.openChat(conversation: id) } },
                          archived: showArchived, restore: { ai.restoreConversations($0) },
                          newChat: newChat,
                          rename: { ai.renameConversation($0, title: $1) },
                          pin: { ai.pinConversations($0, pinned: $1) })
                .id(showArchived)
            HStack {
                Button(showArchived ? "返回历史对话" : "已归档对话") { showArchived.toggle() }
                    .buttonStyle(.plain).font(.system(size: theme.chatFontSize(relativeTo: 10))).accessibilityLabel(showArchived ? "返回历史对话" : "查看已归档对话")
                Spacer()
                if showArchived {
                    Button("清空归档") { confirmClearArchive = true }.buttonStyle(.plain).font(.system(size: theme.chatFontSize(relativeTo: 10)))
                        .disabled(ai.archivedConversations.isEmpty)
                }
                historyToggle
            }.frame(minHeight: 24)
        }.padding(14).frame(maxHeight: .infinity)
            .alert("彻底删除全部已归档对话？", isPresented: $confirmClearArchive) {
                Button("取消", role: .cancel) {}
                Button("全部删除", role: .destructive) { ai.deleteConversations(Set(ai.archivedConversations.map(\.id))) }
            } message: { Text("此操作无法撤销。") }
    }
}

final class AIComposerTextView: NSTextView {
    var pasteboard = NSPasteboard.general
    var pasteImage: ((NSPasteboard) -> Bool)?
    var returnKey: ((NSEvent) -> Bool)?
    var showsPlaceholder: Bool { string.isEmpty && !hasMarkedText() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsPlaceholder {
            NSAttributedString(string: "输入问题，@ 引用标签页", attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(Style.muted)
            ]).draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                               y: textContainerInset.height))
        }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }
    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if isEditable, !hasMarkedText(), [36, 76].contains(event.keyCode), returnKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func paste(_ sender: Any?) {
        if isEditable, pasteImage?(pasteboard) == true { return }
        super.paste(sender)
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, NSImage.canInit(with: pasteboard) { return true }
        return super.validateUserInterfaceItem(item)
    }
}

struct AIComposerInput: NSViewRepresentable {
    @ObservedObject private var theme = PerchTheme.shared
    @Binding var text: String
    let enabled: Bool
    let mentionChanged: (NSRange?, String) -> Void
    let mentionCommand: (Selector) -> Bool
    var pasteImage: (NSPasteboard) -> Bool = { _ in false }
    var focusRequest: UUID?
    var cancel: () -> Bool = { false }
    var sendWithCommand = false
    var send: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = AIComposerTextView()
        editor.isRichText = false; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: theme.chatFontSize); editor.textColor = NSColor(Style.ink)
        editor.textContainerInset = NSSize(width: 0, height: 8)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.pasteImage = { [weak coordinator = context.coordinator] board in coordinator?.parent.pasteImage(board) ?? false }
        editor.returnKey = { [weak coordinator = context.coordinator, weak editor] event in
            guard let coordinator, let editor else { return false }
            return coordinator.handleReturn(event, editor: editor)
        }
        editor.setAccessibilityLabel("向 AI 提问，输入 @ 引用标签页")
        scroll.documentView = editor; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.useTransientScrollers()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.font?.pointSize != CGFloat(theme.chatFontSize) {
            editor.font = .systemFont(ofSize: theme.chatFontSize)
            editor.needsDisplay = true
        }
        editor.isEditable = enabled
        editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, editor.frame.height)))
        if let focusRequest, context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.isEditable else { return }
                editor.window?.makeFirstResponder(editor)
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            }
        }
        if !editor.hasMarkedText(), editor.string != text {
            let cursor = editor.string.isEmpty ? (text as NSString).length : editor.selectedRange().location
            context.coordinator.updating = true
            editor.string = text
            editor.needsDisplay = true
            editor.setSelectedRange(NSRange(location: min(cursor, (text as NSString).length), length: 0))
            context.coordinator.updating = false
            DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
                if let editor { coordinator?.updateMention(editor) }
            }
        }
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIComposerInput
        var updating = false
        var focusRequest: UUID?
        init(_ parent: AIComposerInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            parent.text = editor.string
            updateMention(editor)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            updateMention(editor)
        }
        func updateMention(_ editor: NSTextView) {
            guard !editor.hasMarkedText() else { return }
            let string = editor.string as NSString
            let caret = min(editor.selectedRange().location, string.length)
            let prefix = string.substring(to: caret) as NSString
            let range = prefix.range(of: "@", options: .backwards)
            if range.location != NSNotFound {
                let query = prefix.substring(from: range.location + 1)
                if !query.contains(where: \.isNewline) {
                    parent.mentionChanged(NSRange(location: range.location, length: caret - range.location), query)
                    return
                }
            }
            parent.mentionChanged(nil, "")
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if parent.mentionCommand(commandSelector) { return true }
            return NSStringFromSelector(commandSelector) == "cancelOperation:" && parent.cancel()
        }
        func handleReturn(_ event: NSEvent, editor: NSTextView) -> Bool {
            guard !editor.hasMarkedText() else { return false }
            // Keychain waits can run SwiftUI updates that replace parent during this callback.
            let composer = parent
            defer { withExtendedLifetime(composer) {} }
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if flags.isEmpty, composer.mentionCommand(NSSelectorFromString("insertNewline:")) { return true }
            let shouldSend = flags == (composer.sendWithCommand ? [.command] : [])
            if shouldSend {
                let submitted = editor.string
                composer.text = submitted
                composer.send()
                // Clear before a late native notification can publish the submitted text again.
                if composer.text.isEmpty, editor.string == submitted, !editor.string.isEmpty {
                    updating = true
                    editor.string = ""
                    editor.setSelectedRange(NSRange(location: 0, length: 0))
                    editor.needsDisplay = true
                    updating = false
                }
            } else {
                // Explicitly insert a newline so Cmd+Return cannot fall through to a window shortcut.
                editor.insertText("\n", replacementRange: editor.selectedRange())
            }
            return true
        }
    }
}
