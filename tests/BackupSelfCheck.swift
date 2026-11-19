import AppKit

enum BackupSelfCheck {
    private static func rejects(_ operation: () throws -> Void) {
        do { try operation() }
        catch { return }
        preconditionFailure("Invalid backup must fail")
    }

    @MainActor static func run() throws {
        let suite = "dev.perch.backup-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let oldTheme = PerchTheme.shared.selection, oldFont = PerchTheme.shared.chatFontSize
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            PerchTheme.shared.selection = oldTheme; PerchTheme.shared.chatFontSize = oldFont
        }
        let store = Store(defaults: defaults)
        var settings = store.settings
        settings.chatFontSize = 18; settings.theme = .purple
        settings.followMouseOnShow = true; settings.linkPreviewDelay = 0.25
        settings.showWindowOnLaunch = true; settings.aiSendWithCommand = true
        try store.saveSettings(settings)
        let parent = BookmarkFolder(title: "Parent")
        let child = BookmarkFolder(title: "Empty", parentID: parent.id)
        store.bookmarkFolders = [parent, child]
        store.sites = [Site(title: "Fixture", address: "https://backup.invalid/a?q=1", folderID: parent.id, showOnHome: false)]
        store.importedBookmarks = [ImportSource.chrome.rawValue: [
            BookmarkNode(title: "Imported", children: [BookmarkNode(title: "Link", address: "https://import.invalid")]),
            BookmarkNode(title: "Empty", children: [])
        ]]
        let layout: [String: LayoutPreference.Value] = [
            "sidebarHidden": .flag(true), "sidebarWidth": .number(222),
            "aiSidebarWidth": .number(390), "chatHistoryWidth": .number(260),
            "previewContentSize": .text("{800, 600}"), "windowFrame": .text("{{-1200, 200}, {1000, 700}}")
        ]
        LayoutPreference.restore(layout, to: defaults)
        var provider = store.ai.configuration
        provider.name = "Fixture"; provider.baseURL = "https://model.invalid/v1"
        precondition(store.ai.save(provider, key: "synthetic-key-only"))
        let search = AISearchConfiguration()
        precondition(store.ai.saveSearch(search, key: "synthetic-search-key-only"))
        var backup = try store.settingsBackup(launchAtLogin: true)
        let zip = directory.appendingPathComponent("roundtrip.zip")
        try BackupArchive.write(backup, to: zip)
        let restored = try BackupArchive.read(zip)
        precondition(restored.settings == settings && restored.launchAtLogin)
        precondition(restored.sites.map(\.id) == store.sites.map(\.id))
        precondition(restored.folders.count == 2 && restored.folders[1].parentID == parent.id)
        precondition(restored.imported[ImportSource.chrome.rawValue]?[1].children?.isEmpty == true)
        precondition(restored.providers == backup.providers && restored.search == search)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let expectedLayout = try encoder.encode(layout)
        let restoredLayout = try encoder.encode(restored.layout)
        precondition(restoredLayout == expectedLayout)
        let json = String(data: try encoder.encode(backup), encoding: .utf8)!
        precondition(!json.contains("synthetic-key-only") && !json.contains("synthetic-search-key-only"))
        print("PASS: ZIP roundtrip preserves full settings, layout, providers, folder IDs/order and empty folders without keys")

        store.newTab(title: "已保存的标签")
        let groupID = store.createTabGroup(store.tabs[0].id)!
        store.editTabGroup(groupID, name: "工作", color: .cyan)
        store.hideTabGroup(groupID)
        let groupBackup = try store.settingsBackup(launchAtLogin: false, scope: [.bookmarks])
        let groupZIP = directory.appendingPathComponent("groups.zip")
        try BackupArchive.write(groupBackup, to: groupZIP)
        let decodedGroups = try BackupArchive.read(groupZIP)
        precondition(decodedGroups.tabGroups?.first?.hiddenTabs?.first?.title == "已保存的标签")
        store.openTabGroup(groupID)
        let openIDs = store.tabs.map(\.id)
        try store.restoreSettingsBackup(decodedGroups, setLaunchAtLogin: { _ in })
        precondition(store.tabs.map(\.id) == openIDs && store.tabs.allSatisfy { $0.groupID == nil })
        precondition(store.tabGroups.count == 1 && store.tabGroups[0].hidden && store.tabGroups[0].id != groupID)
        precondition(Store(defaults: defaults).tabGroups[0].hidden)
        let importedGroup = store.tabGroups[0].id
        store.openTabGroup(importedGroup)
        precondition(store.tabs.count == 2 && Set(store.tabs.map(\.id)).count == 2)
        var invalidGroup = decodedGroups
        invalidGroup.tabGroups![0].hiddenTabs![0].address = "javascript:alert(1)"
        rejects { try invalidGroup.validate() }
        invalidGroup = decodedGroups
        invalidGroup.tabGroups![0].hiddenTabs!.append(invalidGroup.tabGroups![0].hiddenTabs![0])
        rejects { try invalidGroup.validate() }
        var v2 = groupBackup; v2.version = 2
        let oldGroups = try JSONDecoder().decode(SettingsBackup.self, from: encoder.encode(v2))
        precondition(oldGroups.tabGroups == nil)
        let currentGroups = store.tabGroups
        try store.restoreSettingsBackup(oldGroups, setLaunchAtLogin: { _ in })
        precondition(store.tabGroups == currentGroups)
        store.deleteTabGroup(importedGroup)
        print("PASS: saved group ZIP roundtrip, fresh IDs, hidden import, open-page preservation, v2 compatibility and invalid member rejection")

        var withKeys = try store.settingsBackup(launchAtLogin: true, includeKeys: true)
        precondition(withKeys.credentials?.providers[provider.id.uuidString] == "synthetic-key-only")
        precondition(withKeys.credentials?.search == "synthetic-search-key-only")
        let keyZIP = directory.appendingPathComponent("keys.zip")
        try BackupArchive.write(withKeys, to: keyZIP)
        withKeys = try BackupArchive.read(keyZIP)
        let permissions = try FileManager.default.attributesOfItem(atPath: keyZIP.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let fresh = withKeys.withFreshCredentialIDs()
        precondition(fresh.selectedProvider != provider.id)
        precondition(fresh.credentials?.providers[fresh.selectedProvider.uuidString] == "synthetic-key-only")
        precondition(fresh.credentials?.providers[provider.id.uuidString] == nil)
        rejects {
            try store.ai.withImportedCredentials(fresh) { throw PerchError("Synthetic transaction failure") }
        }
        // Retrying identical fresh IDs proves the failed transaction removed every staged key.
        try store.ai.withImportedCredentials(fresh) {}
        rejects { try store.ai.withImportedCredentials(fresh) {} }
        let unchangedKeys = try store.ai.backupCredentials()
        precondition(unchangedKeys.providers[provider.id.uuidString] == "synthetic-key-only")
        try store.restoreSettingsBackup(withKeys, setLaunchAtLogin: { _ in })
        precondition(store.ai.hasKey && store.ai.searchHasKey)
        let importedKeys = try store.ai.backupCredentials()
        precondition(importedKeys.providers[store.ai.configuration.id.uuidString] == "synthetic-key-only")
        precondition(importedKeys.search == "synthetic-search-key-only")
        print("PASS: opt-in keys roundtrip privately, remap accounts, rollback on failure and reject account overwrite")

        for scope in BackupScope.allCases {
            let selected = try store.settingsBackup(launchAtLogin: false, scope: [scope], includeKeys: true)
            let object = try JSONSerialization.jsonObject(with: encoder.encode(selected)) as! [String: Any]
            precondition((object["settings"] != nil) == (scope == .settings))
            precondition((object["providers"] != nil) == (scope == .ai))
            precondition((object["sites"] != nil) == (scope == .bookmarks))
            precondition((object["credentials"] != nil) == (scope == .ai))
            var decoded = try JSONDecoder().decode(SettingsBackup.self, from: encoder.encode(selected))
            try decoded.validate()
            let oldSettings = store.settings, oldProvider = store.ai.configuration
            let oldSites = store.sites.map(\.id)
            if scope == .settings { decoded.settings.chatFontSize = 17 }
            if scope == .bookmarks { decoded.sites = []; decoded.folders = []; decoded.imported = [:] }
            var loginTouched = false
            try store.restoreSettingsBackup(decoded, setLaunchAtLogin: { _ in loginTouched = true })
            precondition(loginTouched == (scope == .settings))
            if scope != .settings { precondition(store.settings == oldSettings) }
            if scope != .ai { precondition(store.ai.configuration == oldProvider && store.ai.hasKey) }
            if scope != .bookmarks { precondition(store.sites.map(\.id) == oldSites) }
            else { precondition(store.sites.isEmpty && store.importedBookmarks.isEmpty) }
        }
        var legacy = backup; legacy.version = 1
        let oldBackup = try JSONDecoder().decode(SettingsBackup.self, from: encoder.encode(legacy))
        try oldBackup.validate()
        precondition(oldBackup.scope == Set(BackupScope.allCases) && oldBackup.credentials == nil)
        var invalidKeys = withKeys; invalidKeys.credentials?.providers[UUID().uuidString] = "unassociated"
        rejects { try invalidKeys.validate() }
        invalidKeys = withKeys; invalidKeys.credentials?.search = "invalid\nkey"
        rejects { try invalidKeys.validate() }
        invalidKeys = withKeys; invalidKeys.scope = [.bookmarks]
        rejects { try invalidKeys.validate() }
        rejects { _ = try store.settingsBackup(launchAtLogin: false, scope: []) }
        print("PASS: selective encoding/restore preserves omitted categories, v1 remains compatible and invalid keys reject")

        // A missing older setting adopts its model default without an export-specific field list.
        var object = try JSONSerialization.jsonObject(with: encoder.encode(backup)) as! [String: Any]
        var oldSettings = object["settings"] as! [String: Any]
        oldSettings.removeValue(forKey: "chatFontSize"); oldSettings.removeValue(forKey: "followMouseOnShow")
        object["settings"] = oldSettings
        let older = try JSONDecoder().decode(SettingsBackup.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(older.settings.chatFontSize == BrowserSettings.defaultChatFontSize && !older.settings.followMouseOnShow)
        backup.providers[0].id = provider.id
        backup.providers[0].legacyAccount = provider.account
        backup.providers[0].keyEnvironment = "SYNTHETIC_SECRET"
        let owner = UUID()
        store.ai.drafts[owner] = "Keep draft"
        store.ai.setSearchEnabled(false, tab: owner)
        let sessionID = store.ai.sessions[owner]!.id
        store.mergeHistory([Visit(title: "Keep", address: "https://keep.invalid", date: Date())])
        var login: Bool?
        try store.restoreSettingsBackup(backup, setLaunchAtLogin: { login = $0 })
        precondition(login == true && store.settings == settings)
        precondition(store.ai.configuration.id != provider.id && store.ai.configuration.legacyAccount == nil)
        precondition(store.ai.configuration.keyEnvironment == nil && !store.ai.hasKey && !store.ai.searchHasKey)
        precondition(store.ai.searchConfiguration?.id != search.id)
        precondition(store.ai.sessions[owner]?.id == sessionID && store.ai.drafts[owner] == "Keep draft")
        precondition(store.history.count == 1)
        let reopened = Store(defaults: defaults)
        precondition(reopened.settings == settings && reopened.sites[0].folderID == parent.id)
        precondition(reopened.bookmarkFolders[1].id == child.id && reopened.ai.configuration == store.ai.configuration)
        let persistedLayout = try encoder.encode(LayoutPreference.capture(defaults))
        precondition(persistedLayout == expectedLayout)
        print("PASS: restore persists all models, isolates credential identities and keeps drafts/conversations/history")

        let unchanged = defaults.persistentDomain(forName: suite)! as NSDictionary
        var invalid = backup; invalid.version = 99
        rejects { try store.restoreSettingsBackup(invalid, setLaunchAtLogin: { _ in preconditionFailure("No system changes") }) }
        invalid = backup; invalid.folders[0].parentID = child.id
        rejects { try invalid.validate() }
        invalid = backup; invalid.sites.append(invalid.sites[0])
        rejects { try invalid.validate() }
        invalid = backup; invalid.sites[0].folderID = UUID()
        rejects { try invalid.validate() }
        invalid = backup; invalid.sites[0].address = "javascript:alert(1)"
        rejects { try invalid.validate() }
        invalid = backup; invalid.layout["sidebarWidth"] = .number(-10)
        rejects { try invalid.validate() }
        invalid = backup; invalid.providers.append(invalid.providers[0])
        rejects { try invalid.validate() }
        invalid = backup; invalid.imported[ImportSource.chrome.rawValue] = [
            BookmarkNode(title: "Invalid", address: "https://valid.invalid", children: [])
        ]
        rejects { try invalid.validate() }
        var deep = BookmarkNode(title: "Leaf", address: "https://deep.invalid")
        for _ in 0..<66 { deep = BookmarkNode(title: "Folder", children: [deep]) }
        invalid = backup; invalid.imported = [ImportSource.chrome.rawValue: [deep]]
        rejects { try invalid.validate() }

        var calls: [BrowserSettings] = []
        var changed = backup; changed.settings.theme = .red
        store.applyHotkeys = { calls.append($0) }
        rejects {
            try store.restoreSettingsBackup(changed, setLaunchAtLogin: { _ in throw PerchError("Synthetic login failure") })
        }
        precondition(calls == [changed.settings, settings])
        precondition(unchanged.isEqual(to: defaults.persistentDomain(forName: suite)!))
        store.applyHotkeys = { _ in throw PerchError("Synthetic shortcut conflict") }
        rejects {
            try store.restoreSettingsBackup(changed, setLaunchAtLogin: { _ in preconditionFailure("No login change") })
        }
        precondition(unchanged.isEqual(to: defaults.persistentDomain(forName: suite)!))
        store.applyHotkeys = nil
        print("PASS: invalid schema, duplicate IDs, cyclic/deep trees and system failures leave stored data intact")

        func rawZip(_ data: Data, name: String = "perch-backup.json") throws -> URL {
            let file = directory.appendingPathComponent(name)
            try data.write(to: file)
            let archive = directory.appendingPathComponent(UUID().uuidString + ".zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-q", archive.path, name]; process.currentDirectoryURL = directory
            try process.run(); process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            return archive
        }
        let brokenJSON = try rawZip(Data("{".utf8))
        rejects { _ = try BackupArchive.read(brokenJSON) }
        let wrongName = try rawZip(Data(json.utf8), name: "unexpected.json")
        rejects { _ = try BackupArchive.read(wrongName) }
        let brokenZIP = directory.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: brokenZIP)
        rejects { _ = try BackupArchive.read(brokenZIP) }
        var oversized = backup
        oversized.sites[0].title = String(repeating: "a", count: BackupArchive.limit)
        let bomb = try rawZip(encoder.encode(oversized))
        rejects { _ = try BackupArchive.read(bomb) }
        let originalZIP = try Data(contentsOf: zip)
        rejects { try BackupArchive.write(oversized, to: zip) }
        let preservedZIP = try Data(contentsOf: zip)
        precondition(preservedZIP == originalZIP, "Failed export preserves existing destination")
        print("PASS: malformed ZIP/JSON, unexpected entries and decompression limits reject safely; failed export preserves file")

        for key in ["settings", "sites", "bookmarkFolders", "importedBookmarks", "aiProviders", "aiSearchProvider"] {
            let original = defaults.object(forKey: key)
            defaults.set(Data("broken".utf8), forKey: key)
            let damaged = Store(defaults: defaults)
            rejects { _ = try damaged.settingsBackup(launchAtLogin: false) }
            rejects { try damaged.restoreSettingsBackup(backup, setLaunchAtLogin: { _ in preconditionFailure("No login change") }) }
            precondition(defaults.data(forKey: key) == Data("broken".utf8))
            let unaffected: Set<BackupScope> = key == "settings" || key.hasPrefix("ai") ? [.bookmarks] : [.ai]
            _ = try damaged.settingsBackup(launchAtLogin: false, scope: unaffected)
            defaults.set(original, forKey: key)
        }
        var cleared = backup; cleared.search = nil; cleared.layout = [:]
        try store.restoreSettingsBackup(cleared, setLaunchAtLogin: { _ in })
        precondition(store.ai.searchConfiguration == nil && defaults.object(forKey: "aiSearchProvider") == nil)
        precondition(LayoutPreference.capture(defaults).isEmpty)
        print("PASS: damaged local models are protected and absent optional preferences restore defaults")
    }
}
