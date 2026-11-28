import AppKit
import SwiftUI
import Carbon
import ServiceManagement
import WebKit
import Combine

enum SettingsRoute: String, CaseIterable {
    case general, appearance, ai, bookmarks, passwords, importer, about

    var url: URL {
        URL(string: "perch://settings" + (self == .general ? "" : "/\(rawValue)"))!
    }

    init?(_ url: URL?) {
        guard let url, url.scheme?.lowercased() == "perch", url.host?.lowercased() == "settings",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
        if path.isEmpty || path == "/" { self = .general }
        else if let route = Self.allCases.first(where: { path == "/\($0.rawValue)" }) { self = route }
        else { return nil }
    }
}

@MainActor
final class SettingsPageBridge: NSObject, WKScriptMessageHandler {
    weak var web: WKWebView?
    weak var store: Store?
    private var subscriptions = Set<AnyCancellable>()
    var onRouteChanged: ((URL) -> Void)?
    private var activeURL: URL?
    var errors: [SettingsRoute: String] = [:]
    var error: String {
        get { SettingsRoute(web?.url).flatMap { errors[$0] } ?? "" }
        set { if let route = SettingsRoute(web?.url) { errors[route] = newValue } }
    }
    let recorder = KeyRecorder()
    lazy var imports = SettingsImportController()
    var discoveredModels: [String] = []
    var discoveryID = ""
    var modelTask: Task<Void, Never>?
    var passwordLoaded = false
    private var revealSheet: NSWindow?
    private var previewingTheme = false

    func revealPassword(_ password: String, origin: String, in window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = origin
        let value = NSTextField(labelWithString: password)
        value.isSelectable = true
        value.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        alert.accessoryView = value
        alert.addButton(withTitle: "完成")
        revealSheet = alert.window
        alert.beginSheetModal(for: window) { [weak self] _ in
            value.stringValue = ""
            self?.revealSheet = nil
        }
    }

    func deactivate(clearSecrets: Bool = true) {
        recorder.stop()
        endThemePreview()
        if clearSecrets, let web, [.ai, .passwords].contains(SettingsRoute(web.url)) {
            web.callAsyncJavaScript("window.perchClearSettingsSecrets?.()", arguments: [:], in: nil,
                                    in: .defaultClient, completionHandler: nil)
        }
        if let sheet = revealSheet, let window = sheet.sheetParent { window.endSheet(sheet) }
    }

    private func endThemePreview() {
        guard previewingTheme else { return }
        previewingTheme = false
        if let store { PerchTheme.shared.selection = store.settings.theme }
    }

    func stop() {
        deactivate()
        modelTask?.cancel(); modelTask = nil
        discoveredModels = []; discoveryID = ""
        subscriptions.removeAll(); errors.removeAll(); passwordLoaded = false; activeURL = nil
    }
    func start() {
        guard let store else { return }
        guard let web, let url = web.url, let route = SettingsRoute(url) else { return }
        if let activeURL, activeURL != url {
            deactivate(clearSecrets: false)
            onRouteChanged?(url)
        }
        activeURL = url
        if !passwordLoaded, route == .passwords, store.browser?.webView === web {
            passwordLoaded = true
            do { try store.passwords.load() } catch { self.error = error.localizedDescription }
        }
        if subscriptions.isEmpty {
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
                .sink { [weak self] _ in self?.deactivate() }.store(in: &subscriptions)
            // Read the committed values after the publisher's will-change notification.
            for publisher in [store.$settings.map { _ in () }.eraseToAnyPublisher(),
                              store.$checkingUpdate.map { _ in () }.eraseToAnyPublisher(),
                              store.$availableUpdate.map { _ in () }.eraseToAnyPublisher(),
                              store.$sites.map { _ in () }.eraseToAnyPublisher(),
                              store.$tabGroups.map { _ in () }.eraseToAnyPublisher(),
                              store.$bookmarkFolders.map { _ in () }.eraseToAnyPublisher(),
                              store.$importedBookmarks.map { _ in () }.eraseToAnyPublisher(),
                              store.passwords.objectWillChange.eraseToAnyPublisher(),
                              store.ai.$keyedProviders.map { _ in () }.eraseToAnyPublisher(),
                              store.ai.$searchHasKey.map { _ in () }.eraseToAnyPublisher(),
                              store.ai.$providers.map { _ in () }.eraseToAnyPublisher(),
                              store.ai.$searchConfiguration.map { _ in () }.eraseToAnyPublisher()] {
                publisher.sink { [weak self] in
                    DispatchQueue.main.async { self?.update() }
                }.store(in: &subscriptions)
            }
        }
        update()
    }

    func update(receipt: Int? = nil) {
        guard let store, let web, let route = SettingsRoute(web.url) else { return }
        let settings = store.settings
        let login = SMAppService.mainApp.status
        PerchTheme.shared.update(web)
        var state: [String: Any] = [
            "route": route.rawValue, "error": error, "values": [
                "showWindowOnLaunch": settings.showWindowOnLaunch, "followMouseOnShow": settings.followMouseOnShow,
                "login": login == .enabled || login == .requiresApproval, "savePasswords": settings.savePasswords,
                "linkPreviewEnabled": settings.linkPreviewEnabled, "linkPreviewDelay": settings.linkPreviewDelay,
                "searchEngine": settings.searchEngine, "customSearchURL": settings.customSearchURL,
                "uaMode": settings.uaMode, "customUA": settings.customUA, "theme": settings.theme.rawValue,
                "chatFontSize": settings.chatFontSize, "aiSendWithCommand": settings.aiSendWithCommand
            ] as [String: Any],
            "themes": ThemeColor.allCases.map { ["id": $0.rawValue, "name": $0.name, "color": $0.webColors["line"]!] },
            "loginNote": login == .requiresApproval ? "等待系统批准，请在登录项设置中允许 Perch。" : "",
            "userAgent": settings.userAgent ?? "使用 macOS WebKit 的默认 UA",
            "shortcuts": ["open": settings.openKey?.label ?? "", "close": settings.closeKey?.label ?? "",
                          "toggle": settings.toggleKey?.label ?? "", "preview": settings.linkPreviewKey.singleKeyLabel],
            "recording": recorder.target ?? "",
            "version": UpdateCheck.currentVersion, "checking": store.checkingUpdate,
            "update": store.availableUpdate ?? "", "updateMessage": store.updateCheckMessage ?? ""
        ]
        if let receipt { state["receipt"] = receipt }
        switch route {
        case .ai: state["ai"] = aiState(store.ai)
        case .bookmarks: state["library"] = bookmarkState(store)
        case .passwords:
            state["passwords"] = store.passwords.entries.map {
                ["id": $0.id.uuidString, "origin": $0.origin, "username": $0.username]
            }
        case .importer:
            state["imports"] = imports.state
            state["importing"] = store.importing
        default: break
        }
        InternalPage.update(state, web: web)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let web, let route = SettingsRoute(web.url),
              InternalPage.accepts(message, web: web, matches: { SettingsRoute($0) == route }),
              let store, let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        if action == "ready" { start(); return }
        guard let window = web.window, window.attachedSheet == nil, store.browser?.webView === web, !store.adding else { return }
        error = ""
        do {
            switch (route, action) {
            case (.general, "loginItems"): SMAppService.openSystemSettingsLoginItems()
            case (.ai, "chat"): store.openChat()
            case (.about, "check"): store.checkForUpdates(manual: true)
            case (.about, "source"): NSWorkspace.shared.open(UpdateCheck.repositoryURL)
            case (.about, "release"):
                if store.availableUpdate != nil { NSWorkspace.shared.open(UpdateCheck.releaseURL) }
            case (.appearance, "previewTheme"):
                if let raw = body["theme"] as? String, let color = ThemeColor(rawValue: raw) {
                    previewingTheme = true
                    PerchTheme.shared.selection = color
                } else { endThemePreview() }
            case (_, "change"):
                guard let key = body["key"] as? String else { return }
                let value = body["value"]
                var next = store.settings
                switch (route, key, value) {
                case (.general, "showWindowOnLaunch", let v as Bool): next.showWindowOnLaunch = v
                case (.general, "followMouseOnShow", let v as Bool): next.followMouseOnShow = v
                case (.general, "login", let v as Bool): try LaunchAtLogin.set(v); update(); return
                case (.general, "linkPreviewEnabled", let v as Bool): next.linkPreviewEnabled = v
                case (.general, "linkPreviewDelay", let v as Double): next.linkPreviewDelay = v
                case (.general, "searchEngine", let v as String): next.searchEngine = v
                case (.general, "customSearchURL", let v as String) where v.count <= 2048: next.customSearchURL = v
                case (.general, "uaMode", let v as String) where ["safari", "chrome", "system", "custom"].contains(v):
                    next.uaMode = v
                    if v == "custom", next.customUA.isEmpty {
                        next.customUA = store.settings.userAgent ?? BrowserSettings().userAgent ?? ""
                    }
                case (.general, "customUA", let v as String) where v.count <= 1024: next.customUA = v
                case (.appearance, "theme", let v as String):
                    guard let theme = ThemeColor(rawValue: v) else { return }
                    endThemePreview()
                    next.theme = theme
                case (.appearance, "chatFontSize", let v as Double): next.chatFontSize = v
                case (.ai, "aiSendWithCommand", let v as Bool): next.aiSendWithCommand = v
                case (.passwords, "savePasswords", let v as Bool): next.savePasswords = v
                default: return
                }
                if next != store.settings { try store.saveSettings(next) }
            case (.general, "record"), (.general, "clearShortcut"):
                try shortcut(action, body: body, store: store)
            case (.ai, _): try aiAction(action, body: body, store: store)
            case (.bookmarks, _): try bookmarkAction(action, body: body, store: store)
            case (.passwords, _): try passwordAction(action, body: body, store: store)
            case (.importer, _): imports.handle(action, body: body, store: store, update: { [weak self] in self?.update() })
            default: return
            }
        } catch { self.error = error.localizedDescription }
        update(receipt: body["request"] as? Int)
    }
}

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

struct Tab: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var address: String
    var customTitle: String?
    var pinned = false
    var chatOwner: UUID?
    var aiOwner: UUID?
    var aiSidebarOpen: Bool?
    var groupID: UUID?
    var isChat: Bool { ChatPage.matches(URL(string: address)) || chatOwner != nil }
    var isHome: Bool { address.isEmpty || HomeHistoryPage.matches(URL(string: address)) }
    var displayTitle: String { customTitle ?? title }
    mutating func migrateChat() {
        guard chatOwner != nil else { return }
        address = ChatPage.url.absoluteString; title = "AI 聊天"; chatOwner = nil
    }
}

enum TabGroupColor: String, Codable, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, cyan, gray
    var color: NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch self {
        case .blue: rgb = (0.26, 0.42, 0.85)
        case .purple: rgb = (0.62, 0.22, 0.96)
        case .pink: rgb = (0.78, 0.00, 0.65)
        case .red: rgb = (0.89, 0.06, 0.16)
        case .orange: rgb = (1.00, 0.56, 0.19)
        case .yellow: rgb = (1.00, 0.81, 0.18)
        case .green: rgb = (0.09, 0.50, 0.16)
        case .cyan: rgb = (0.00, 0.48, 0.51)
        case .gray: rgb = (0.38, 0.40, 0.42)
        }
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
    var foreground: NSColor { self == .yellow || self == .orange ? .black : .white }
    var name: String {
        switch self {
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .pink: return "粉色"
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .cyan: return "青色"
        case .gray: return "灰色"
        }
    }
}

struct TabGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "新分组"
    var color: TabGroupColor = .blue
    var collapsed = false
    // Only hidden groups own stored tabs; visible groups use Store.tabs as their source of truth.
    var hiddenTabs: [Tab]?
    var hidden: Bool { hiddenTabs != nil }

    static func validateStoredTabs(_ groups: [TabGroup]) throws {
        guard groups.count <= 50000 else { throw PerchError("保存的标签组过多。") }
        var groupIDs = Set<UUID>(), tabIDs = Set<UUID>(), count = groups.count
        for group in groups {
            guard groupIDs.insert(group.id).inserted else { throw PerchError("标签组 ID 重复。") }
            guard let members = group.hiddenTabs else { continue }
            count += members.count
            guard !members.isEmpty, count <= 50000 else { throw PerchError("保存的标签组为空或标签过多。") }
            for tab in members {
                guard tabIDs.insert(tab.id).inserted, !tab.pinned, tab.groupID == group.id,
                      tab.address.isEmpty || tab.address == "about:blank" || URLInput.parseNavigation(tab.address, search: false) != nil else {
                    throw PerchError("保存的标签 ID、网址或分组归属无效。")
                }
            }
        }
    }
}

enum TabListRow: Equatable {
    case tab(UUID), group(UUID)
    var id: UUID {
        switch self { case .tab(let id), .group(let id): return id }
    }
    static func rows(tabs: [Tab], groups: [TabGroup], selected: UUID? = nil, draggingGroup: UUID? = nil) -> [TabListRow] {
        let groups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var result: [TabListRow] = []
        for tab in tabs {
            if let id = tab.groupID, let group = groups[id] {
                if seen.insert(id).inserted {
                    result.append(.group(id))
                    // The active page stays visible outside its collapsed group without changing membership.
                    if group.collapsed, draggingGroup != id,
                       let active = tabs.first(where: { $0.id == selected && $0.groupID == id }) {
                        result.append(.tab(active.id))
                    }
                }
                if group.collapsed || draggingGroup == id { continue }
            }
            result.append(.tab(tab.id))
        }
        return result
    }
}

struct Visit: Identifiable, Codable {
    var id = UUID()
    var title: String
    var address: String
    var date: Date
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
