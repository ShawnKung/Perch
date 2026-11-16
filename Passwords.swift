import AppKit
import SwiftUI
import Security
import LocalAuthentication
import WebKit

struct SavedPassword: Identifiable, Codable, Equatable {
    var id = UUID()
    var origin: String
    var username: String
    var password: String

    static func origin(for address: String) -> String? {
        guard let url = URLInput.parse(address, search: false),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""; components.query = nil; components.fragment = nil
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) { components.port = nil }
        return components.string
    }
    func validated() throws -> SavedPassword {
        guard let normalized = Self.origin(for: origin), !password.isEmpty,
              password.utf8.count <= 16384, username.utf8.count <= 1024 else {
            throw PerchError("请输入有效的 HTTP / HTTPS 网站和非空密码。")
        }
        var result = self; result.origin = normalized
        return result
    }
}

enum PasswordCSV {
    static func read(_ data: Data) throws -> (items: [SavedPassword], skipped: Int) {
        guard var text = String(data: data, encoding: .utf8) else { throw PerchError("密码 CSV 需要使用 UTF-8 编码。") }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, atStart = true
        let chars = Array(text)
        var index = 0
        func finishField() { row.append(field); field = ""; closed = false; atStart = true }
        func finishRow() { finishField(); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = [] }
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(char) }
            } else if char == "," { finishField() }
            else if char == "\n" || char == "\r\n" || char == "\r" {
                if char == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
                finishRow()
            } else if char == "\"" && atStart { quoted = true; atStart = false }
            else {
                guard !closed, char != "\"" else { throw PerchError("密码 CSV 引号格式不正确，未导入。") }
                field.append(char); atStart = false
            }
            index += 1
        }
        guard !quoted else { throw PerchError("密码 CSV 引号未闭合，未导入。") }
        if !field.isEmpty || !row.isEmpty || closed { finishRow() }
        guard let header = rows.first else { throw PerchError("密码 CSV 为空。") }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let urlIndex = names.firstIndex(of: "url") ?? names.firstIndex(of: "website"),
              let userIndex = names.firstIndex(of: "username"),
              let passwordIndex = names.firstIndex(of: "password") else {
            throw PerchError("密码 CSV 需要 URL、Username、Password 列，支持 Chrome、Firefox 和 Safari 导出的格式。")
        }
        guard rows.count <= 10001 else { throw PerchError("密码 CSV 超过 10,000 条，未导入。") }
        var result: [SavedPassword] = [], skipped = 0
        for values in rows.dropFirst() {
            guard values.count == header.count else { throw PerchError("密码 CSV 列数不一致，未导入。") }
            if let item = try? SavedPassword(origin: values[urlIndex], username: values[userIndex],
                                             password: values[passwordIndex]).validated() { result.append(item) }
            else { skipped += 1 }
        }
        return (result, skipped)
    }
}

@MainActor
final class PasswordVault: ObservableObject {
    @Published private(set) var entries: [SavedPassword] = []
    private var loaded = false
    private let memoryOnly: Bool
    private let service: String
    init(memoryOnly: Bool = false, service: String = "dev.perch.menubar.passwords.v2") {
        self.memoryOnly = memoryOnly; self.service = service
    }
    private func request(_ operation: String, data: Data? = nil, allowInteraction: Bool = false) throws -> Data? {
        struct Request: Encodable {
            let operation: String
            let service: String
            let allowInteraction: Bool
            let data: Data?
        }
        struct Response: Decodable { let status: Int32; let data: Data? }
        let process = Process()
        process.executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("PerchVault")
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(try JSONEncoder().encode(
            Request(operation: operation, service: service, allowInteraction: allowInteraction, data: data)))
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let response = try JSONDecoder().decode(Response.self, from: result)
        guard response.status == errSecSuccess else {
            if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(response.status) {
                throw PerchError("旧版钥匙串记录的访问已被拒绝。可直接启用新密码库后重新导入；旧记录仍保留。")
            }
            throw PerchError("密码钥匙串操作失败（\(response.status)）。")
        }
        return response.data
    }
    func cleanupSynthetic() {
        guard service.hasPrefix("dev.perch.synthetic-") else { return }
        _ = try? request("cleanup")
    }
    func initializeWithoutLegacyAuthorization() throws {
        guard service == "dev.perch.menubar.passwords.v2" else { return }
        guard let data = try request("initialize") else { throw PerchError("无法初始化密码库。") }
        entries = try JSONDecoder().decode([SavedPassword].self, from: data).map { try $0.validated() }
        loaded = true
    }
    func load(allowInteraction: Bool = false) throws {
        guard !loaded else { return }
        if memoryOnly { loaded = true; return }
        guard let data = try request("load", allowInteraction: allowInteraction) else { loaded = true; return }
        // A decode failure must never turn into an empty vault that overwrites the original.
        let decoded = try JSONDecoder().decode([SavedPassword].self, from: data)
        entries = try decoded.map { try $0.validated() }; loaded = true
    }
    @discardableResult
    func save(_ values: [SavedPassword]) throws -> Int {
        try load()
        var next = entries
        for value in values {
            let item = try value.validated()
            if let index = next.firstIndex(where: { $0.origin == item.origin && $0.username == item.username }) {
                var updated = item; updated.id = next[index].id; next[index] = updated
            } else { next.append(item) }
        }
        guard next.count <= 10000 else { throw PerchError("密码数量超过 10,000 条，未写入。") }
        try write(next)
        return values.count
    }
    func delete(_ id: UUID) throws {
        try load(); try write(entries.filter { $0.id != id })
    }
    private func write(_ values: [SavedPassword]) throws {
        if !memoryOnly {
            let data = try JSONEncoder().encode(values)
            _ = try request("write", data: data)
        }
        entries = values
    }
    static func authenticate() async throws {
        let context = LAContext()
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                               localizedReason: "查看或复制 Perch 保存的密码") else {
            throw PerchError("身份验证未完成。")
        }
    }
}

@MainActor
final class PasswordBridge: NSObject, WKScriptMessageHandler, NSPopoverDelegate {
    var detected: ((SavedPassword) -> Void)?
    var requested: ((String, NSRect, String) -> Void)?
    private(set) var popover: NSPopover?
    private var popoverToken: String?
    private var filling = false
    func dismiss() {
        let previous = popover
        popover = nil; popoverToken = nil
        previous?.close()
    }
    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil; popoverToken = nil
    }
    func show(_ items: [SavedPassword], at rect: NSRect, token: String, in view: WKWebView,
              manage: @escaping () -> Void, failed: @escaping (String) -> Void) {
        // A mouse click produces both focusin and click with the same input token.
        guard popover == nil || popoverToken != token else { return }
        dismiss()
        guard !items.isEmpty, view.window?.isVisible == true, let host = view.window?.contentView else { return }
        let picker = NSPopover()
        picker.delegate = self
        picker.animates = false
        picker.behavior = .transient
        picker.contentViewController = NSHostingController(rootView: PasswordFieldPicker(items: items, select: { [weak self, weak view] item in
            guard let self, let view else { return }
            self.filling = true
            self.dismiss()
            Task { @MainActor in
                defer { self.filling = false }
                do { try await Self.fill(item, in: view, token: token) }
                catch { failed(error.localizedDescription) }
            }
        }, manage: { [weak self] in self?.dismiss(); manage() }))
        let anchor = NSRect(x: rect.minX * view.bounds.width,
                            y: (view.isFlipped ? rect.minY : 1 - rect.maxY) * view.bounds.height,
                            width: rect.width * view.bounds.width, height: rect.height * view.bounds.height)
        guard view.bounds.intersects(anchor) else { return }
        popover = picker
        popoverToken = token
        // Use the hosting view's coordinates and prefer floating above the input.
        picker.show(relativeTo: host.convert(anchor.intersection(view.bounds), from: view),
                    of: host, preferredEdge: .minY)
        // Animate opacity separately so closing during appearance always works.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let window = picker.contentViewController?.view.window {
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                window.animator().alphaValue = 1
            }
        }
    }
    static let script = """
    (() => {
      let last = '', suppress = false;
      let selection = null;
      const uuid = () => {
        const bytes = crypto.getRandomValues(new Uint8Array(16));
        bytes[6] = (bytes[6] & 15) | 64;
        bytes[8] = (bytes[8] & 63) | 128;
        const hex = [...bytes].map(b => b.toString(16).padStart(2,'0')).join('');
        return [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');
      };
      const eligible = p => p instanceof HTMLInputElement && !p.disabled && !p.readOnly &&
                            p.autocomplete !== 'new-password' && p.getClientRects().length;
      const pair = input => {
        if (!eligible(input)) return null;
        const root = input.form || document;
        const passwords = [...root.querySelectorAll('input[type=password]')].filter(eligible);
        const p = input.type === 'password' ? input : passwords.length === 1 ? passwords[0] : null;
        if (!p) return null;
        const inputs = [...root.querySelectorAll('input')].filter(p => eligible(p) && p.type !== 'password');
        const u = inputs.find(p => /username|email/i.test(p.autocomplete)) ||
                  inputs.find(p => /email|user|login|account/i.test(p.name + ' ' + p.id)) ||
                  inputs.find(p => p.type === 'email' || p.type === 'text');
        return input === p || input === u ? {p,u} : null;
      };
      const dismiss = () => {
        selection = null;
        window.webkit.messageHandlers.perchPassword.postMessage({kind:'dismiss'});
      };
      const request = e => {
        if (suppress || !e.isTrusted) return;
        const fields = pair(e.target);
        if (!fields) { dismiss(); return; }
        // Closing a native popup can restore focus to the same field without a new click.
        if (e.type === 'focusin' && selection?.input === e.target) return;
        const r = e.target.getBoundingClientRect();
        const token = selection?.input === e.target ? selection.token : uuid();
        selection = {...fields, input:e.target, token};
        window.webkit.messageHandlers.perchPassword.postMessage({
          kind:'request', token, x:r.x / innerWidth, y:r.y / innerHeight,
          width:r.width / innerWidth, height:r.height / innerHeight
        });
      };
      globalThis.perchFillTarget = token => selection?.token === token &&
        selection.input.isConnected && eligible(selection.input) && eligible(selection.p) &&
        (!selection.u || selection.u.isConnected) ? selection : null;
      globalThis.perchPasswordFocus = p => {
        suppress = true;
        try { p.focus(); } finally { suppress = false; }
      };
      document.addEventListener('focusin',request,true);
      document.addEventListener('click',request,true);
      document.addEventListener('scroll',dismiss,true);
      window.addEventListener('resize',dismiss);
      const capture = (e) => {
        if (!e.isTrusted) return;
        let form = e.target.closest?.('form');
        if (e.type === 'click') {
          const button = e.target.closest?.('button,input[type=submit]');
          if (!button || !(button.type === 'submit' || /登录|log.?in|sign.?in/i.test(button.textContent))) return;
          form = button.form || form;
        }
        if (e.type === 'keydown' && e.key !== 'Enter') return;
        const root = form || document;
        const fields = [...root.querySelectorAll('input[type=password]')].filter(p => !p.disabled);
        if (fields.length !== 1 || fields[0].autocomplete === 'new-password' || !fields[0].value) return;
        const inputs = [...root.querySelectorAll('input')].filter(p => !p.disabled && p.type !== 'password');
        const user = inputs.find(p => /username|email/i.test(p.autocomplete)) ||
                     inputs.find(p => /email|user|login|account/i.test(p.name + ' ' + p.id)) ||
                     inputs.find(p => p.type === 'email' || p.type === 'text');
        const username = user?.value || '';
        const password = fields[0].value;
        if (password.length > 16384 || username.length > 1024) return;
        const key = username + '\\n' + password;
        if (key === last) return;
        last = key;
        window.webkit.messageHandlers.perchPassword.postMessage({username,password});
      };
      document.addEventListener('submit',capture,true);
      document.addEventListener('click',capture,true);
      document.addEventListener('keydown',capture,true);
    })();
    """
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url,
              let origin = SavedPassword.origin(for: url.absoluteString),
              let body = message.body as? [String: Any] else { return }
        let security = message.frameInfo.securityOrigin
        var trusted = URLComponents()
        trusted.scheme = security.protocol; trusted.host = security.host
        if security.port != 0 { trusted.port = security.port }
        guard let source = trusted.string, SavedPassword.origin(for: source) == origin else { return }
        if body["kind"] as? String == "dismiss" { dismiss(); return }
        if body["kind"] as? String == "request" {
            guard !filling, let token = body["token"] as? String, UUID(uuidString: token) != nil,
                  let x = body["x"] as? Double, let y = body["y"] as? Double,
                  let width = body["width"] as? Double, let height = body["height"] as? Double,
                  [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0,
                  x < 1, y < 1, x + width > 0, y + height > 0 else { return }
            requested?(origin, NSRect(x: x, y: y, width: width, height: height), token)
            return
        }
        guard let username = body["username"] as? String, let password = body["password"] as? String,
              let candidate = try? SavedPassword(origin: origin, username: username, password: password).validated() else { return }
        detected?(candidate)
    }
    static func fill(_ item: SavedPassword, in view: WKWebView, token: String? = nil) async throws {
        guard let url = view.url, SavedPassword.origin(for: url.absoluteString) == item.origin else {
            throw PerchError("页面地址已变化，未填入密码。")
        }
        let result = try await view.callAsyncJavaScript("""
        if (location.origin !== origin) return false;
        const fields = [...document.querySelectorAll('input[type=password]')]
          .filter(p => !p.disabled && !p.readOnly && p.autocomplete !== 'new-password' && p.getClientRects().length);
        const target = token ? globalThis.perchFillTarget?.(token) : null;
        if (token ? !target : fields.length !== 1) return false;
        const p = target?.p || fields[0], root = p.form || document;
        const inputs = [...root.querySelectorAll('input')].filter(p => !p.disabled && !p.readOnly && p.getClientRects().length);
        const u = target ? target.u : inputs.find(p => /username|email/i.test(p.autocomplete)) ||
                  inputs.find(p => p.type !== 'password' && /email|user|login|account/i.test(p.name + ' ' + p.id)) ||
                  inputs.find(p => p.type === 'email' || p.type === 'text');
        const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
        function fill(field,value) {
          set.call(field,value);
          field.dispatchEvent(new Event('input',{bubbles:true}));
          field.dispatchEvent(new Event('change',{bubbles:true}));
        }
        if (u) fill(u,username);
        fill(p,password);
        globalThis.perchPasswordFocus(p);
        return true;
        """, arguments: ["origin": item.origin, "username": item.username, "password": item.password, "token": token ?? ""],
        in: nil, contentWorld: .defaultClient)
        guard result as? Bool == true else {
            throw PerchError("未找到唯一的登录密码输入框。跨域内嵌、注册及复杂表单需手动填写。")
        }
    }
}

struct PasswordFieldPicker: View {
    @ObservedObject private var theme = PerchTheme.shared
    let items: [SavedPassword]
    let select: (SavedPassword) -> Void
    let manage: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择账号填入").font(.headline)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "key.fill").foregroundStyle(Style.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.username.isEmpty ? "无用户名的账号" : item.username).lineLimit(1)
                                    Text("••••••••").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: CGFloat(min(items.count, 5)) * 52)
            Divider()
            Button("管理密码", action: manage).buttonStyle(.plain).foregroundStyle(Style.accent)
        }.padding(14).frame(width: 260)
    }
}

struct PasswordPrompt: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    let candidate: SavedPassword
    @State private var username = ""
    @State private var password = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存或更新密码？").font(.title3.bold())
            Text(candidate.origin).textSelection(.enabled)
            TextField("用户名", text: $username).textFieldStyle(.roundedBorder)
            SecureField("密码", text: $password).textFieldStyle(.roundedBorder)
            if candidate.origin.hasPrefix("http://") {
                Text("这个网站使用未加密的 HTTP 连接。").font(.caption).foregroundStyle(.secondary)
            }
            Text("保存到本机钥匙串；下次点击登录输入框即可选择账号填入。").font(.caption)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("暂不保存") { store.pendingPassword = nil }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        _ = try store.passwords.save([SavedPassword(origin: candidate.origin, username: username, password: password)])
                        store.pendingPassword = nil
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }.padding(24).frame(width: 380)
            .onAppear { username = candidate.username; password = candidate.password }
    }
}

struct PasswordFillButton: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    @ObservedObject var browser: Browser
    @ObservedObject var vault: PasswordVault
    @State private var showing = false
    init(store: Store, browser: Browser) {
        self.store = store; self.browser = browser; self.vault = store.passwords
    }
    private var choices: [SavedPassword] {
        guard let origin = SavedPassword.origin(for: browser.address) else { return [] }
        return vault.entries.filter { $0.origin == origin }
    }
    var body: some View {
        HStack(spacing: 0) {
            if !choices.isEmpty {
                GlyphButton(symbol: "key", label: "填入已保存的密码", size: 26) {
                    showing = true
                }.popover(isPresented: $showing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("选择账号填入").font(.headline)
                        ForEach(choices) { item in
                            Button(item.username.isEmpty ? "无用户名的账号" : item.username) {
                                showing = false
                                Task { @MainActor in
                                    do { try await PasswordBridge.fill(item, in: browser.webView) }
                                    catch { store.notice = error.localizedDescription }
                                }
                            }
                        }
                        Divider()
                        Button("管理密码") { showing = false; store.library = .passwords }
                    }.padding(16).frame(minWidth: 220)
                }
            }
        }
        .task { try? vault.load() }
        .onChange(of: browser.address) { _ in showing = false }
        .onChange(of: choices) { _ in showing = false }
    }
}

struct PasswordsPage: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    @ObservedObject var vault: PasswordVault
    @State private var search = ""
    @State private var message = ""
    @State private var editID: UUID?
    @State private var editing = false
    @State private var origin = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var revealed: UUID?
    @State private var deleting: SavedPassword?
    init(store: Store) { self.store = store; self.vault = store.passwords }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("搜索网站或用户名", text: $search).textFieldStyle(.roundedBorder)
                Button("添加密码") { editID = nil; origin = ""; username = ""; secret = ""; editing = true }
            }
            if editing {
                VStack {
                    TextField("https://example.com", text: $origin).disabled(editID != nil)
                    TextField("用户名", text: $username).disabled(editID != nil)
                    SecureField("密码", text: $secret)
                    HStack {
                        Button("保存") {
                            do {
                                _ = try vault.save([SavedPassword(id: editID ?? UUID(), origin: origin, username: username, password: secret)])
                                editing = false; secret = ""; revealed = nil
                            } catch { message = error.localizedDescription }
                        }.disabled(secret.isEmpty)
                        Button("取消") { editing = false; secret = "" }
                    }
                }.textFieldStyle(.roundedBorder)
            }
            List {
                ForEach(vault.entries.filter {
                    search.isEmpty || $0.origin.localizedCaseInsensitiveContains(search) || $0.username.localizedCaseInsensitiveContains(search)
                }) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.origin).font(.system(size: 13, weight: .semibold))
                        Text(item.username.isEmpty ? "无用户名" : item.username).font(.caption)
                        HStack {
                            Text(revealed == item.id ? item.password : "••••••••").font(.caption.monospaced())
                            Spacer()
                            Button(revealed == item.id ? "隐藏" : "查看") {
                                if revealed == item.id { revealed = nil }
                                else { authenticate { revealed = item.id } }
                            }
                            Button("复制") { authenticate {
                                copyAddress(item.password)
                                let change = NSPasteboard.general.changeCount
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                                    if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
                                }
                            } }
                            Button("修改") { authenticate {
                                editID = item.id; origin = item.origin; username = item.username; secret = ""; editing = true
                            } }
                            Button("删除", role: .destructive) { deleting = item }
                        }
                    }.padding(.vertical, 5)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(Style.paper)
            if !message.isEmpty {
                HStack {
                    Text(message).font(.caption).foregroundStyle(Style.muted)
                    Button("授权读取") {
                        do { try vault.load(allowInteraction: true); message = "" }
                        catch { message = error.localizedDescription }
                    }
                    Button("启用新密码库") {
                        do { try vault.initializeWithoutLegacyAuthorization(); message = "" }
                        catch { message = error.localizedDescription }
                    }
                }
            }
            Text("\(vault.entries.count) 个账号")
                .font(.caption).foregroundStyle(Style.muted).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(20).onAppear { do { try vault.load() } catch { message = error.localizedDescription } }
            .onDisappear { secret = ""; revealed = nil }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification)) { _ in
                revealed = nil; secret = ""
            }
            .alert("删除这个保存的密码？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) {
                    if let item = deleting { do { try vault.delete(item.id) } catch { message = error.localizedDescription } }
                    deleting = nil
                }
            }
    }
    private func authenticate(_ action: @escaping () -> Void) {
        Task { @MainActor in
            do { try await PasswordVault.authenticate(); action() }
            catch { message = error.localizedDescription }
        }
    }
}
