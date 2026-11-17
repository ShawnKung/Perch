import SwiftUI
import AppKit
import WebKit

struct ImportPage: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    @State private var source: ImportSource = .chrome
    @State private var directory = ImportSource.chrome.defaultDirectory
    @State private var cookieFile: URL?
    @State private var cookies = true
    @State private var bookmarks = true
    @State private var history = true
    @State private var passwords = true
    @State private var passwordFile: URL?
    @State private var status = ""
    @State private var profiles: [URL] = []
    @State private var accessDirectory: URL?
    @State private var requiresFileAccess = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text("来源浏览器").frame(width: 76, alignment: .leading)
                    Picker("来源浏览器", selection: $source) {
                        ForEach(ImportSource.allCases) { source in Text(source.rawValue).tag(source) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 216).onChange(of: source) { value in
                        directory = value.defaultDirectory; cookieFile = nil; status = ""
                        passwordFile = nil
                        accessDirectory = nil; requiresFileAccess = false; refreshProfiles()
                    }
                    Spacer()
                    if !profiles.isEmpty {
                        Text("资料配置")
                        Picker("资料配置", selection: $directory) {
                            ForEach(profiles, id: \.self) { profile in Text(profile.lastPathComponent).tag(profile) }
                        }.labelsHidden().frame(width: 120)
                    }
                }
                HStack(spacing: 12) {
                    Text("资料目录").frame(width: 76, alignment: .leading)
                    Text(directory.path).font(.caption).foregroundStyle(Style.muted).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle).help(directory.path)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(Style.sidebar, in: RoundedRectangle(cornerRadius: 6))
                    Button("选择目录…") { chooseDirectory() }.fixedSize()
                }
                HStack(spacing: 12) {
                    Text("导入内容").frame(width: 76, alignment: .leading)
                    Toggle("Cookie / 登录态", isOn: $cookies)
                    Toggle("书签", isOn: $bookmarks)
                    Toggle("历史记录", isOn: $history)
                    Toggle("密码", isOn: $passwords)
                }
                if passwords || cookies {
                    HStack(spacing: 12) {
                        Text("文件").frame(width: 76, alignment: .leading)
                        if passwords {
                            Button("选择密码 CSV…") {
                                let panel = NSOpenPanel()
                                panel.message = "选择从 Chrome、Firefox 或 Safari 导出的密码 CSV。文件包含明文密码，导入后请妥善处理。"
                                if panel.runModal() == .OK { passwordFile = panel.url }
                            }.fixedSize()
                            if let passwordFile {
                                Text(passwordFile.lastPathComponent).font(.caption).lineLimit(1)
                                    .truncationMode(.middle).help(passwordFile.path)
                                Button("清除") { self.passwordFile = nil }.fixedSize()
                            }
                        }
                        if cookies {
                            Button("选择 Cookie 文件…") {
                                let panel = NSOpenPanel()
                                panel.message = "支持 Safari .binarycookies、JSON Cookie 数组和 Netscape cookies.txt。"
                                if panel.runModal() == .OK { cookieFile = panel.url }
                            }.fixedSize()
                            if let cookieFile {
                                Text(cookieFile.lastPathComponent).font(.caption).lineLimit(1)
                                    .truncationMode(.middle).help(cookieFile.path).textSelection(.enabled)
                                Button("使用浏览器数据") { self.cookieFile = nil }.fixedSize()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                Divider()
                HStack {
                    if store.importing {
                        ProgressView().controlSize(.small)
                        Text("正在导入…").font(.caption).foregroundStyle(Style.muted)
                    }
                    Spacer()
                    Button("开始导入") { start() }.buttonStyle(.borderedProminent)
                        .disabled(store.importing || (!cookies && !bookmarks && !history && !passwords))
                }
                if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled).lineSpacing(5) }
                if requiresFileAccess {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("需要允许 Perch 读取浏览器资料", systemImage: "lock.shield").font(.callout.bold())
                        Text("1. 点击「重新选择资料目录」，在系统选择框中选中上方目录并确认。\n2. 若仍提示没有权限，打开「完全磁盘访问权限」，用 + 添加下方这个 Perch.app 并开启；随后退出并重新打开 Perch，再导入。此权限允许应用读取更广泛的受保护文件，请按需开启。")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        Text(Bundle.main.bundleURL.path).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("重新选择资料目录…") { chooseDirectory() }
                            Button("完全磁盘访问权限…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                            }
                            Button("在 Finder 显示 Perch") {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }
                        }
                        Text("文件访问权限与 Chrome Safe Storage 钥匙串授权是两件事；本应用不会自动修改系统权限。")
                            .font(.caption).foregroundStyle(Style.muted)
                    }.padding(14).background(Style.mint, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(20).disabled(store.importing)
        }.background(Style.paper).onAppear { refreshProfiles() }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = directory.deletingLastPathComponent()
        panel.message = "允许 Perch 读取所选资料。Chrome 选择 Default / Profile N 或 Chrome 根目录；Firefox 选择具体 Profile；Safari 选择 Library/Safari。"
        if panel.runModal() == .OK, let url = panel.url {
            accessDirectory = url
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let found = source.profiles(in: url)
            if !found.isEmpty { profiles = found; directory = found[0] }
            else { directory = url; refreshProfiles() }
        }
    }

    private func refreshProfiles() {
        profiles = source == .safari ? [] : source.profiles(in: directory.deletingLastPathComponent())
        if let matched = profiles.first(where: { $0.path == directory.path }) { directory = matched }
        else if !profiles.isEmpty { profiles.append(directory) }
    }

    private func start() {
        let options = ImportOptions(source: source, directory: directory, cookieFile: cookieFile,
                                    cookies: cookies, bookmarks: bookmarks, history: history, accessDirectory: accessDirectory,
                                    passwords: passwords, passwordFile: passwordFile)
        store.importing = true; status = ""; requiresFileAccess = false
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { BrowserImporter.read(options) }.value
            requiresFileAccess = result.requiresFileAccess
            let bookmarksAdded = result.bookmarkTree.map { store.replaceImportedBookmarks($0, source: options.source) } ?? 0
            let historyBefore = Set(store.history.map { $0.address + "|" + String(Int($0.date.timeIntervalSince1970)) })
            if options.history { store.mergeHistory(result.history) }
            let historyAdded = store.history.filter { !historyBefore.contains($0.address + "|" + String(Int($0.date.timeIntervalSince1970))) }.count
            var passwordCount = 0
            var passwordError: String?
            if !result.passwords.isEmpty {
                do { passwordCount = try store.passwords.save(result.passwords) }
                catch { passwordError = "密码保存失败：\(error.localizedDescription)" }
            }
            let cookieStore = WKWebsiteDataStore.default().httpCookieStore
            // Deduplicate before writes so the final verification is deterministic.
            var unique: [String: HTTPCookie] = [:]
            func identity(_ cookie: HTTPCookie) -> String { cookie.domain + "\n" + cookie.path + "\n" + cookie.name }
            for cookie in result.cookies { unique[identity(cookie)] = cookie }
            for cookie in unique.values {
                await withCheckedContinuation { continuation in
                    cookieStore.setCookie(cookie) { continuation.resume() }
                }
            }
            let installed: [HTTPCookie] = await withCheckedContinuation { continuation in
                cookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
            let verified = installed.filter { cookie in
                guard let expected = unique[identity(cookie)] else { return false }
                return cookie.value == expected.value && cookie.isSecure == expected.isSecure && cookie.isHTTPOnly == expected.isHTTPOnly
                    && (expected.sameSitePolicy == nil || cookie.sameSitePolicy == expected.sameSitePolicy)
            }.count
            let outcome = result.messages.isEmpty && passwordError == nil && result.skippedPasswords == 0 ? "导入完成" :
                (bookmarksAdded + historyAdded + verified + passwordCount == 0 ? "导入未成功" : "部分导入完成")
            var lines = ["\(outcome)：更新 \(bookmarksAdded) 个书签、新增 \(historyAdded) 条历史，确认写入 \(verified) 个 Cookie、\(passwordCount) 个密码。"]
            if let passwordError { lines.append(passwordError) }
            if result.skippedPasswords > 0 {
                lines.append("跳过 \(result.skippedPasswords) 个密码（无效网址、空密码或不支持的加密格式）。可选择浏览器导出的密码 CSV 重试。")
            }
            if result.skipped > 0 { lines.append("跳过 \(result.skipped) 个 Cookie（过期、分区、容器、无效或无法解密）。") }
            if verified < unique.count { lines.append("\(unique.count - verified) 个 Cookie 未通过 WebKit 写入确认。") }
            lines += result.messages
            if verified > 0 { lines.append("请刷新对应网页以使用导入的登录态。") }
            status = lines.joined(separator: "\n")
            store.importing = false
        }
    }
}
