import AppKit
import WebKit
import UniformTypeIdentifiers
import ServiceManagement

@MainActor
final class SettingsImportController {
    private var source = ImportSource.chrome
    private var directory = ImportSource.chrome.defaultDirectory
    private var cookieFile: URL?
    private var passwordFile: URL?
    private var cookies = true, bookmarks = true, history = true, passwords = true
    private var status = "", backupStatus = ""
    private var profiles: [URL] = []
    private var accessDirectory: URL?
    private var requiresFileAccess = false
    private var backupScope = Set(BackupScope.allCases)
    private var includeAIKeys = false

    init() { refreshProfiles() }

    var state: [String: Any] {
        ["sources": ImportSource.allCases.map(\.rawValue), "source": source.rawValue,
         "directory": directory.path, "profiles": profiles.map { $0.lastPathComponent },
         "cookieFile": cookieFile?.lastPathComponent ?? "", "passwordFile": passwordFile?.lastPathComponent ?? "",
         "status": status, "backupStatus": backupStatus, "needsAccess": requiresFileAccess,
         "scopes": BackupScope.allCases.map { ["id": $0.rawValue, "title": $0.title] }]
    }

    func handle(_ action: String, body: [String: Any], store: Store, update: @escaping () -> Void) {
        guard !store.importing else { return }
        switch action {
        case "source":
            guard let raw = body["source"] as? String, let value = ImportSource(rawValue: raw) else { return }
            source = value; directory = value.defaultDirectory; cookieFile = nil; passwordFile = nil
            accessDirectory = nil; requiresFileAccess = false; status = ""; refreshProfiles()
        case "profile":
            guard let index = body["index"] as? Int, profiles.indices.contains(index) else { return }
            directory = profiles[index]
        case "directory": chooseDirectory()
        case "cookieFile", "passwordFile":
            let panel = NSOpenPanel()
            panel.message = action == "cookieFile" ? "选择 Safari、JSON 或 Netscape Cookie 文件。" :
                "选择浏览器导出的密码 CSV。此文件包含明文密码，请妥善处理。"
            if panel.runModal() == .OK {
                if action == "cookieFile" { cookieFile = panel.url }
                else { passwordFile = panel.url }
            }
        case "clearCookies": cookieFile = nil
        case "clearPasswords": passwordFile = nil
        case "diskAccess":
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        case "finder": NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        case "start":
            cookies = body["cookies"] as? Bool == true; bookmarks = body["bookmarks"] as? Bool == true
            history = body["history"] as? Bool == true; passwords = body["passwords"] as? Bool == true
            if cookies || bookmarks || history || passwords { start(store: store, update: update) }
        case "export":
            backupScope = Set((body["scopes"] as? [String] ?? []).compactMap(BackupScope.init(rawValue:)))
            guard !backupScope.isEmpty else { return }
            includeAIKeys = backupScope.contains(.ai) && body["keys"] as? Bool == true
            exportBackup(store: store, update: update)
        case "import": importBackup(store: store, update: update)
        default: return
        }
    }

    private func exportBackup(store: Store, update: @escaping () -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Perch-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importing = true; backupStatus = "正在导出…"
        Task { @MainActor in
            defer { store.importing = false; update() }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let backup = try store.settingsBackup(launchAtLogin: LaunchAtLogin.enabled,
                    scope: backupScope, includeKeys: includeAIKeys)
                try await Task.detached(priority: .userInitiated) { try BackupArchive.write(backup, to: url) }.value
                backupStatus = "已导出 \(url.lastPathComponent)。"
            } catch { backupStatus = "导出失败：\(error.localizedDescription)" }
        }
    }

    private func importBackup(store: Store, update: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importing = true; backupStatus = "正在检查备份…"
        Task { @MainActor in
            defer { store.importing = false; update() }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let backup = try await Task.detached(priority: .userInitiated) { try BackupArchive.read(url) }.value
                let count = backup.sites.count + backup.imported.values.flatMap { $0 }.flatMap(\.sites).count
                let alert = NSAlert()
                alert.messageText = "导入并替换\(backup.scopeDescription)？"
                var details = ["只替换备份包含的类别，其他内容保持不变。"]
                if backup.scope.contains(.settings) {
                    details.append("登录时启动将设为\(backup.launchAtLogin ? "开启" : "关闭")。")
                }
                if backup.scope.contains(.bookmarks) { details.append("替换个人书签和浏览器导入书签，共 \(count) 个书签。") }
                if let groups = backup.tabGroups, backup.scope.contains(.bookmarks) {
                    details.append("替换 \(groups.count) 个标签组并保存为隐藏目录；已有打开页面保留并解除旧分组。")
                }
                if backup.scope.contains(.ai) {
                    details.append("替换 \(backup.providers.count) 个 AI 供应商及搜索配置，导入 \(backup.credentials?.count ?? 0) 个密钥；未包含的密钥需重新填写。")
                }
                alert.informativeText = details.joined(separator: "\n") + "\n\n建议先导出当前备份。"
                alert.addButton(withTitle: "替换并导入")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { backupStatus = ""; return }
                try store.restoreSettingsBackup(backup)
                backupStatus = "已导入：\(backup.scopeDescription)。"
                if backup.scope.contains(.ai) { backupStatus += "已导入 \(backup.credentials?.count ?? 0) 个 AI 密钥，未包含的密钥请在 AI 设置中填写。" }
                if backup.scope.contains(.settings) { backupStatus += "预览尺寸下次打开时生效，全屏窗口的位置在退出全屏后恢复。" }
                if backup.scope.contains(.settings), SMAppService.mainApp.status == .requiresApproval {
                    backupStatus += "\n登录时启动等待系统批准，请到常规设置中打开系统登录项设置。"
                }
            } catch { backupStatus = "导入失败：\(error.localizedDescription)" }
        }
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

    private func start(store: Store, update: @escaping () -> Void) {
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
            let cookieStore = (store.browser?.webView.configuration.websiteDataStore ?? .default()).httpCookieStore
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
            store.importing = false; update()
        }
    }
}
