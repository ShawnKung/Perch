import AppKit
import SwiftUI
import Carbon
import ServiceManagement
import WebKit

enum ThemeColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, cyan, blue, purple, pink, white
    var name: String {
        switch self {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .cyan: return "青"
        case .blue: return "蓝"
        case .purple: return "紫"
        case .pink: return "粉"
        case .white: return "白"
        }
    }
    private var rgb: (Double, Double, Double) {
        switch self {
        case .red: return (0.57, 0.34, 0.35)
        case .orange: return (0.57, 0.39, 0.22)
        case .yellow: return (0.50, 0.46, 0.12)
        case .green: return (0.13, 0.39, 0.32)
        case .cyan: return (0.20, 0.43, 0.47)
        case .blue: return (0.28, 0.39, 0.60)
        case .purple: return (0.43, 0.36, 0.55)
        case .pink: return (0.53, 0.36, 0.47)
        case .white: return (0.37, 0.40, 0.39)
        }
    }
    private func tint(_ amount: Double) -> NSColor {
        let (r, g, b) = rgb
        return NSColor(srgbRed: 1 - (1 - r) * amount, green: 1 - (1 - g) * amount,
                       blue: 1 - (1 - b) * amount, alpha: 1)
    }
    var accent: NSColor { tint(1) }
    var mint: NSColor {
        self == .green ? NSColor(srgbRed: 0.88, green: 0.94, blue: 0.90, alpha: 1) : tint(0.17)
    }
    var sample: NSColor {
        self == .white ? NSColor(srgbRed: 0.88, green: 0.89, blue: 0.88, alpha: 1) : tint(0.32)
    }
    var sidebar: NSColor {
        self == .green ? NSColor(srgbRed: 0.94, green: 0.96, blue: 0.93, alpha: 1) :
            self == .white ? NSColor(srgbRed: 0.975, green: 0.975, blue: 0.97, alpha: 1) : tint(0.075)
    }
    var line: NSColor {
        self == .green ? NSColor(srgbRed: 0.86, green: 0.89, blue: 0.86, alpha: 1) : tint(0.23)
    }
    var webColors: [String: String] {
        func hex(_ color: NSColor) -> String {
            String(format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()),
                   Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        }
        return ["accent": hex(accent), "mint": hex(mint), "sidebar": hex(sidebar), "line": hex(line)]
    }
}

final class PerchTheme: ObservableObject {
    static let shared = PerchTheme()
    @Published var selection: ThemeColor = .blue {
        didSet {
            guard oldValue != selection else { return }
            updateRegisteredWebViews()
        }
    }
    @Published var chatFontSize = BrowserSettings.defaultChatFontSize {
        didSet {
            guard oldValue != chatFontSize else { return }
            updateRegisteredWebViews()
        }
    }
    var chatScale: Double { chatFontSize / BrowserSettings.defaultChatFontSize }
    func chatFontSize(relativeTo size: Double) -> Double { size * chatScale }
    var chatDetailFontSize: Double { chatFontSize(relativeTo: 12) }
    private func updateRegisteredWebViews() {
        webViews.removeAll { $0.value == nil }
        for entry in webViews { if let web = entry.value { update(web) } }
    }
    private final class WeakWeb {
        weak var value: WKWebView?
        init(_ value: WKWebView) { self.value = value }
    }
    private var webViews: [WeakWeb] = []
    func register(_ web: WKWebView) {
        webViews.removeAll { $0.value == nil }
        webViews.append(WeakWeb(web))
        let script = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        web.configuration.userContentController.addUserScript(script)
    }
    func update(_ web: WKWebView) {
        web.evaluateJavaScript(script, completionHandler: nil)
    }
    private var script: String {
        let colors = selection.webColors
        return """
        (() => {
          const root = document.documentElement;
          root.dataset.perchTheme = '\(selection.rawValue)';
          root.style.setProperty('--perch-chat-font-size', '\(chatFontSize)px');
          \(colors.sorted { $0.key < $1.key }.map { "root.style.setProperty('--perch-\($0.key)', '\($0.value)');" }.joined())
        })();
        """
    }
}

struct Tab: Identifiable, Codable {
    var id = UUID()
    var title: String
    var address: String
    var pinned = false
    var chatOwner: UUID?
    var aiOwner: UUID?
    var aiSidebarOpen: Bool?
}

struct Visit: Identifiable, Codable {
    var id = UUID()
    var title: String
    var address: String
    var date: Date
}

enum LibraryPage: String, Identifiable, CaseIterable {
    case settings = "常规", ai = "AI", bookmarks = "书签与历史", passwords = "密码", importer = "导入导出"
    var id: String { rawValue }
}

struct PerchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct Shortcut: Codable, Equatable {
    var code: UInt32
    var modifiers: UInt32
    var label: String
    var singleKeyLabel: String {
        switch code {
        case 58, 61: return "⌥"
        case 59, 62: return "⌃"
        case 56, 60: return "⇧"
        case 55, 54: return "⌘"
        default: return label
        }
    }
}

struct BrowserSettings: Codable, Equatable {
    static let defaultChatFontSize = 13.0
    static let chatFontSizeRange = 11.0...22.0
    var chatFontSize = Self.defaultChatFontSize
    var uaMode = "safari"
    var customUA = ""
    var openKey: Shortcut? = Shortcut(code: 35, modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘P")
    var closeKey: Shortcut? = Shortcut(code: 13, modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘W")
    var toggleKey: Shortcut? = Shortcut(code: 7, modifiers: UInt32(cmdKey | controlKey), label: "⌃⌘X")
    var searchEngine = "google"
    var customSearchURL = "https://www.google.com/search?q={query}"
    var savePasswords = true
    var linkPreviewEnabled = true
    var linkPreviewKey = Shortcut(code: 58, modifiers: 0, label: "⌥ Alt")
    var linkPreviewDelay = 1.0
    var aiSendWithCommand = false
    var theme: ThemeColor = .blue
    var showWindowOnLaunch = false
    var followMouseOnShow = false
    var historyRecordingEnabled = true
    private var shortcutDefaultsVersion = 1

    init() {}
    enum CodingKeys: String, CodingKey {
        case uaMode, customUA, openKey, closeKey, toggleKey, searchEngine, customSearchURL, savePasswords
        case linkPreviewEnabled, linkPreviewKey, linkPreviewDelay, aiSendWithCommand, theme, showWindowOnLaunch
        case historyRecordingEnabled, shortcutDefaultsVersion, chatFontSize, followMouseOnShow
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uaMode = try c.decodeIfPresent(String.self, forKey: .uaMode) ?? "safari"
        customUA = try c.decodeIfPresent(String.self, forKey: .customUA) ?? ""
        openKey = try c.decodeIfPresent(Shortcut.self, forKey: .openKey)
        closeKey = try c.decodeIfPresent(Shortcut.self, forKey: .closeKey)
        toggleKey = try c.decodeIfPresent(Shortcut.self, forKey: .toggleKey)
        if !c.contains(.shortcutDefaultsVersion) && !c.contains(.toggleKey) {
            let defaultToggle = Shortcut(code: 7, modifiers: UInt32(cmdKey | controlKey), label: "⌃⌘X")
            if ![openKey, closeKey].compactMap({ $0 }).contains(where: {
                $0.code == defaultToggle.code && $0.modifiers == defaultToggle.modifiers
            }) { toggleKey = defaultToggle }
        }
        shortcutDefaultsVersion = 1
        searchEngine = try c.decodeIfPresent(String.self, forKey: .searchEngine) ?? "google"
        customSearchURL = try c.decodeIfPresent(String.self, forKey: .customSearchURL) ?? customSearchURL
        savePasswords = try c.decodeIfPresent(Bool.self, forKey: .savePasswords) ?? true
        linkPreviewEnabled = try c.decodeIfPresent(Bool.self, forKey: .linkPreviewEnabled) ?? true
        linkPreviewKey = try c.decodeIfPresent(Shortcut.self, forKey: .linkPreviewKey) ?? linkPreviewKey
        linkPreviewDelay = try c.decodeIfPresent(Double.self, forKey: .linkPreviewDelay) ?? 1
        aiSendWithCommand = try c.decodeIfPresent(Bool.self, forKey: .aiSendWithCommand) ?? false
        theme = try c.decodeIfPresent(ThemeColor.self, forKey: .theme) ?? .green
        showWindowOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .showWindowOnLaunch) ?? false
        followMouseOnShow = try c.decodeIfPresent(Bool.self, forKey: .followMouseOnShow) ?? false
        historyRecordingEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyRecordingEnabled) ?? true
        chatFontSize = try c.decodeIfPresent(Double.self, forKey: .chatFontSize) ?? Self.defaultChatFontSize
        guard chatFontSize.isFinite, Self.chatFontSizeRange.contains(chatFontSize) else {
            throw DecodingError.dataCorruptedError(forKey: .chatFontSize, in: c, debugDescription: "Chat font size must be between 11 and 22.")
        }
        if !linkPreviewDelay.isFinite || linkPreviewDelay < 0 { linkPreviewDelay = 1 }
        if linkPreviewKey.code > 127 || linkPreviewKey.code == 53 || linkPreviewKey.modifiers != 0 {
            linkPreviewKey = Shortcut(code: 58, modifiers: 0, label: "⌥ Alt")
        }
    }
    var searchURL: String {
        switch searchEngine {
        case "bing": return "https://www.bing.com/search?q={query}"
        case "duckduckgo": return "https://duckduckgo.com/?q={query}"
        case "custom": return customSearchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return "https://www.google.com/search?q={query}"
        }
    }

    static func version(_ path: String, fallback: String) -> String {
        guard let bundle = Bundle(path: path),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              version.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil else { return fallback }
        return version
    }

    static let safariVersion = version("/Applications/Safari.app", fallback: "26.0")
    static let chromeVersion = version("/Applications/Google Chrome.app", fallback: "142.0.0.0")
    var userAgent: String? {
        switch uaMode {
        case "system": return nil
        case "custom": return customUA.trimmingCharacters(in: .whitespaces)
        case "chrome":
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chromeVersion) Safari/537.36"
        default:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(Self.safariVersion) Safari/605.1.15"
        }
    }

    func validate() throws {
        guard chatFontSize.isFinite, Self.chatFontSizeRange.contains(chatFontSize) else {
            throw PerchError("Chat 字体大小需在 11–22 pt 之间。")
        }
        guard linkPreviewDelay.isFinite, linkPreviewDelay >= 0,
              linkPreviewKey.code <= 127, linkPreviewKey.code != 53, linkPreviewKey.modifiers == 0 else {
            throw PerchError("链接预览等待时间需为非负秒数（0 立即触发），触发键需为 Esc 以外的单个按键。")
        }
        guard ["google", "bing", "duckduckgo", "custom"].contains(searchEngine),
              URLInput.validSearchTemplate(searchURL) else {
            throw PerchError("搜索网址需要包含一个 {query}，例如 https://www.google.com/search?q={query}。")
        }
        if uaMode == "custom" {
            guard let ua = userAgent, !ua.isEmpty, ua.utf8.count <= 1024,
                  ua.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) else {
                throw PerchError("自定义 UA 必须是 1–1024 字节的 ASCII 文本，不能含换行。")
            }
        }
        let keys = [openKey, closeKey, toggleKey].compactMap({ $0 })
        for shortcut in keys {
            guard shortcut.modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
                throw PerchError("全局快捷键需要包含 ⌘、⌃ 或 ⌥。")
            }
        }
        if Set(keys.map { "\($0.code):\($0.modifiers)" }).count != keys.count {
            throw PerchError("打开、收起与切换窗口不能使用相同快捷键。")
        }
    }
}

@MainActor
final class Hotkeys {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var current: [UInt32: Shortcut] = [:]
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    var action: ((UInt32) -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let owner = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            owner.action?(id.id)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        // Also handle events delivered directly to our app (including accessibility key events).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            var mods: UInt32 = 0
            for (flag, mask) in [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey), (.control, controlKey), (.shift, shiftKey)] {
                if event.modifierFlags.contains(flag) { mods |= UInt32(mask) }
            }
            if let id = self.current.first(where: { $0.value.code == UInt32(event.keyCode) && $0.value.modifiers == mods })?.key {
                if !event.isARepeat { self.action?(id) }
                return nil
            }
            return event
        }
    }

    func apply(_ settings: BrowserSettings) throws {
        try settings.validate()
        let desired = Dictionary(uniqueKeysWithValues: [(UInt32(1), settings.openKey), (UInt32(2), settings.closeKey), (UInt32(3), settings.toggleKey)]
            .compactMap { id, key in key.map { (id, $0) } })
        if current == desired { return }
        let previous = current
        unregister()
        do {
            try register(desired)
        } catch {
            unregister()
            do { try register(previous) }
            catch { throw PerchError("快捷键注册失败，旧快捷键也无法恢复。请重新设置。") }
            throw error
        }
    }

    private func register(_ keys: [UInt32: Shortcut]) throws {
        for (id, key) in keys {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(key.code, key.modifiers, EventHotKeyID(signature: 0x50524348, id: id),
                                            GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else {
                throw PerchError("快捷键 \(key.label) 无法注册，可能已被其他应用占用（\(status)）。")
            }
            refs[id] = reference
        }
        current = keys
    }

    private func unregister() { refs.values.forEach { UnregisterEventHotKey($0) }; refs.removeAll(); current.removeAll() }
    func suspend() { unregister() }
    deinit {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}

@MainActor
final class KeyRecorder: ObservableObject {
    @Published var target: String?
    var recordingChanged: ((Bool) -> Void)?
    private var monitor: Any?
    func start(_ target: String, receive: @escaping (Shortcut) -> Void) {
        stop()
        self.target = target
        recordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    if event.keyCode == 53 { self.stop(); return nil }
                    let flags = event.modifierFlags
                    guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
                    var mods: UInt32 = 0
                    var label = ""
                    for (flag, mask, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"),
                                                 (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
                        if flags.contains(flag) { mods |= UInt32(mask); label += symbol }
                    }
                    let key = event.characters(byApplyingModifiers: flags.intersection(.shift))?.uppercased() ?? ""
                    label += key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }) && !key.isEmpty
                        ? key : "键\(event.keyCode)"
                    receive(Shortcut(code: UInt32(event.keyCode), modifiers: mods, label: label))
                    self.stop()
                    return nil
        }
    }
    func stop() {
        let wasRecording = target != nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; target = nil
        if wasRecording { recordingChanged?(false) }
    }
    func startHoldKey(receive: @escaping (Shortcut) -> Void) {
        stop()
        target = "linkPreview"
        recordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(); return nil }
            let key: Shortcut
            if event.type == .flagsChanged {
                guard let flag = LinkPreviewController.modifier(UInt32(event.keyCode)),
                      event.modifierFlags.contains(flag) else { return event }
                let values: (UInt32, String)
                switch flag {
                case .option: values = (58, "⌥ Alt")
                case .control: values = (59, "⌃ Control")
                case .shift: values = (56, "⇧ Shift")
                default: values = (55, "⌘ Command")
                }
                key = Shortcut(code: values.0, modifiers: 0, label: values.1)
            } else {
                guard event.modifierFlags.intersection([.option, .control, .shift, .command]).isEmpty else { return nil }
                let text = event.charactersIgnoringModifiers?.uppercased() ?? ""
                let label = !text.isEmpty && text.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 })
                    ? text : "键 \(event.keyCode)"
                key = Shortcut(code: UInt32(event.keyCode), modifiers: 0, label: label)
            }
            receive(key); self.stop()
            return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

struct ShortcutRecorder: View {
    @ObservedObject private var theme = PerchTheme.shared
    @Binding var shortcut: Shortcut?
    @ObservedObject var recorder: KeyRecorder
    let target: String
    var body: some View {
        HStack {
            Button(recorder.target == target ? "请按组合键 · Esc 取消" : shortcut?.label ?? "点击录制") {
                recorder.start(target) { shortcut = $0 }
            }.frame(minWidth: 150)
            Button("清除") { recorder.stop(); shortcut = nil }.disabled(shortcut == nil)
        }
    }
}

struct SettingsFocusDismissal: NSViewRepresentable {
    func makeNSView(context: Context) -> DismissView { DismissView() }
    func updateNSView(_ view: DismissView, context: Context) {}
    final class DismissView: NSView {
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let window else { return }
            window.initialFirstResponder = self
            window.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                      !editor.visibleRect.contains(editor.convert(event.locationInWindow, from: nil)) else { return event }
                window.makeFirstResponder(nil)
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct SettingsPage: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    var openPasswords: () -> Void = {}
    @State private var draft = BrowserSettings()
    @State private var message = ""
    @State private var login = false
    @State private var loginStatus = ""
    @State private var pendingSave: Task<Void, Never>?
    @State private var themePreview: Task<Void, Never>?
    @State private var hoveredTheme: ThemeColor?
    @State private var clearHistory = false
    @StateObject private var recorder = KeyRecorder()
    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录 Mac 时启动 Perch", isOn: Binding(get: { login }, set: { enabled in
                    do {
                        try LaunchAtLogin.set(enabled)
                    } catch { message = error.localizedDescription }
                    refreshLogin()
                }))
                Toggle("启动 Perch 时打开主窗口", isOn: $draft.showWindowOnLaunch)
                if !loginStatus.isEmpty {
                    Text(loginStatus).font(.caption).foregroundStyle(.secondary)
                }
                Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
            }
            Section("窗口") {
                Toggle("主窗口跟随鼠标显示", isOn: $draft.followMouseOnShow)
                    .accessibilityLabel("主窗口跟随鼠标显示")
                    .help("每次唤出主窗口时显示在鼠标附近，并保持在屏幕可用区域内。")
            }
            Section("外观") {
                HStack {
                    Text("主题色")
                    Spacer()
                    ForEach(ThemeColor.allCases, id: \.self) { color in
                        Button { draft.theme = color } label: {
                            Circle().fill(Color(color.sample))
                                .overlay(Circle().stroke(Color(color.line), lineWidth: 1))
                                .overlay {
                                    if draft.theme == color {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color(color.accent))
                                    }
                                }.frame(width: 28, height: 28).padding(.vertical, 2)
                        }.buttonStyle(.plain).accessibilityLabel("\(color.name)色主题")
                            .accessibilityValue(draft.theme == color ? "已选择" : "未选择")
                            .onHover { preview(color, entered: $0) }
                    }
                }
                chatFontSetting
            }
            Section("搜索引擎") {
                Picker("默认搜索", selection: $draft.searchEngine) {
                    Text("Google").tag("google")
                    Text("Bing").tag("bing")
                    Text("DuckDuckGo").tag("duckduckgo")
                    Text("自定义").tag("custom")
                }
                if draft.searchEngine == "custom" {
                    TextField("https://example.com/search?q={query}", text: $draft.customSearchURL)
                        .textFieldStyle(.roundedBorder)
                    Text("用 {query} 代表搜索关键词。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("历史记录") {
                Toggle("记录历史记录", isOn: $draft.historyRecordingEnabled)
                HStack {
                    Button("清除全部历史记录") { clearHistory = true }
                    Button("查看历史记录") { store.openBookmarks(history: true) }
                }
            }
            Section("密码") {
                Toggle("询问是否保存网站密码", isOn: $draft.savePasswords)
                Button("管理已保存的密码", action: openPasswords)
            }
            Section("AI 聊天") {
                Picker("发送消息", selection: $draft.aiSendWithCommand) {
                    Text("回车").tag(false)
                    Text("Command + 回车").tag(true)
                }
            }
            Section("链接临时预览") {
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text("由")
                        Button {
                            recorder.startHoldKey { draft.linkPreviewKey = $0 }
                        } label: {
                            Text(recorder.target == "linkPreview" ? "…" : draft.linkPreviewKey.singleKeyLabel)
                                .frame(minWidth: 28)
                        }
                        .help("点击设置触发键，Esc 取消").accessibilityLabel("设置触发键")
                        Text("键在")
                        TextField("等待时间", value: $draft.linkPreviewDelay, format: .number)
                            .labelsHidden().textFieldStyle(.plain)
                            .multilineTextAlignment(.center).monospacedDigit()
                            .foregroundStyle(Style.accent).frame(width: 56).padding(.vertical, 4)
                            .background(Style.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("等待秒数")
                        Text("秒触发")
                    }.disabled(!draft.linkPreviewEnabled)
                    Spacer()
                    Toggle("链接预览", isOn: $draft.linkPreviewEnabled).labelsHidden()
                        .accessibilityLabel("启用链接预览")
                }
            }
            Section("浏览器标识 · User-Agent") {
                Picker("使用标识", selection: $draft.uaMode) {
                    Text("Safari \(BrowserSettings.safariVersion)（推荐）").tag("safari")
                    Text("Chrome \(BrowserSettings.chromeVersion) 兼容标识").tag("chrome")
                    Text("系统 WebKit").tag("system")
                    Text("自定义").tag("custom")
                }
                if draft.uaMode == "custom" { TextField("User-Agent", text: $draft.customUA).textFieldStyle(.roundedBorder) }
                Text(draft.userAgent ?? "使用 macOS WebKit 的默认 UA").font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("全局快捷键") {
                HStack { Text("打开窗口"); Spacer(); ShortcutRecorder(shortcut: $draft.openKey, recorder: recorder, target: "open") }
                HStack { Text("收起窗口"); Spacer(); ShortcutRecorder(shortcut: $draft.closeKey, recorder: recorder, target: "close") }
                HStack { Text("隐藏 / 展示窗口"); Spacer(); ShortcutRecorder(shortcut: $draft.toggleKey, recorder: recorder, target: "toggle") }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(Style.muted)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .alert("清除全部历史记录？", isPresented: $clearHistory) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) { store.deleteHistory() }
            } message: { Text("此操作不可撤销。书签和 Cookie 不受影响。") }
            .background(Style.paper).background(SettingsFocusDismissal()).onAppear {
            draft = store.settings; refreshLogin(); recorder.recordingChanged = store.shortcutRecording
        }.onChange(of: draft) { value in
            pendingSave?.cancel()
            if (value.uaMode == "custom" && value.customUA != store.settings.customUA) ||
                (value.searchEngine == "custom" && value.customSearchURL != store.settings.customSearchURL) {
                pendingSave = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    apply(value)
                }
            } else { apply(value) }
        }.onDisappear {
            pendingSave?.cancel()
            themePreview?.cancel()
            theme.selection = store.settings.theme
            recorder.stop()
            apply(draft)
        }
    }

    private var chatFontSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Chat字号")
                Slider(value: $draft.chatFontSize, in: BrowserSettings.chatFontSizeRange, step: 1)
                    .accessibilityLabel("Chat字号")
                    .accessibilityValue("\(Int(draft.chatFontSize)) pt")
                Text("\(Int(draft.chatFontSize)) pt").monospacedDigit().frame(width: 42, alignment: .trailing)
                Button("恢复默认") { draft.chatFontSize = BrowserSettings.defaultChatFontSize }
                    .disabled(draft.chatFontSize == BrowserSettings.defaultChatFontSize)
            }
        }
    }

    private func apply(_ value: BrowserSettings) {
        guard value != store.settings else { message = ""; return }
        do { try store.saveSettings(value); message = "" }
        catch { message = "尚未生效，保留上次设置：\(error.localizedDescription)" }
    }

    private func preview(_ color: ThemeColor, entered: Bool) {
        themePreview?.cancel()
        if entered {
            hoveredTheme = color
            themePreview = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, hoveredTheme == color else { return }
                theme.selection = color
            }
        } else if hoveredTheme == color {
            hoveredTheme = nil
            themePreview = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, hoveredTheme == nil else { return }
                theme.selection = draft.theme
            }
        }
    }

    private func refreshLogin() {
        let status = SMAppService.mainApp.status
        login = status == .enabled || status == .requiresApproval
        switch status {
        case .enabled: loginStatus = ""
        case .requiresApproval: loginStatus = "等待系统批准，请到登录项设置中允许 Perch。"
        case .notFound: loginStatus = "系统未找到此应用。请把 Perch.app 放到固定位置后重试。"
        default: loginStatus = "未启用；建议先将应用移到 /Applications，避免移动后失效。"
        }
    }
}
