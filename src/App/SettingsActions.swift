import AppKit
import WebKit

extension SettingsPageBridge {
    func shortcut(_ action: String, body: [String: Any], store: Store) throws {
        guard let target = body["target"] as? String,
              ["open", "close", "toggle", "preview"].contains(target) else { return }
        func commit(_ value: Shortcut?) throws {
            var next = store.settings
            switch target {
            case "open": next.openKey = value
            case "close": next.closeKey = value
            case "toggle": next.toggleKey = value
            default: if let value { next.linkPreviewKey = value }
            }
            try store.saveSettings(next)
        }
        if action == "clearShortcut" { try commit(nil); return }
        recorder.recordingChanged = { [weak self, weak store] recording in
            store?.shortcutRecording?(recording)
            DispatchQueue.main.async { self?.update() }
        }
        let receive: (Shortcut) -> Void = { [weak self] value in
            do { try commit(value) } catch { self?.error = error.localizedDescription }
            self?.update()
        }
        if target == "preview" { recorder.startHoldKey(receive: receive) }
        else { recorder.start(target, receive: receive) }
    }

    func aiState(_ ai: AIController) -> [String: Any] {
        let search = ai.searchConfiguration ?? AISearchConfiguration()
        return [
            "providers": ai.providers.map {
                ["id": $0.id.uuidString, "name": $0.name, "providerID": $0.providerID, "baseURL": $0.baseURL,
                 "protocol": $0.apiProtocol.rawValue, "models": $0.models, "search": $0.nativeSearch.rawValue,
                 "hasKey": ai.keyedProviders.contains($0.id),
                 "configured": ai.keyedProviders.contains($0.id) && $0.endpoint != nil && !$0.models.isEmpty] as [String: Any]
            },
            "types": AIProvider.allCases.map(\.rawValue), "protocols": AIProtocol.allCases.map(\.rawValue),
            "searchCompatibility": Dictionary(uniqueKeysWithValues: AIProtocol.allCases.map { api in
                (api.rawValue, AINativeSearch.allCases.filter { $0.definition(protocol: api) != nil }.map(\.rawValue))
            }),
            "searchModes": AINativeSearch.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "searchName": search.name, "searchURL": search.baseURL, "searchConfigured": ai.searchConfiguration != nil,
            "searchHasKey": ai.searchHasKey, "needsReset": ai.needsReset,
            "models": discoveredModels, "discoveryID": discoveryID, "discovering": modelTask != nil,
            "directory": ai.conversationDirectory?.path ?? ""
        ]
    }

    func aiAction(_ action: String, body: [String: Any], store: Store) throws {
        let ai = store.ai
        let id = (body["id"] as? String).flatMap(UUID.init(uuidString:))
        let key = (body["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count <= 16384, !key.contains("\n"), !key.contains("\r") else {
            throw PerchError("密钥过长或包含换行。")
        }
        switch action {
        case "addProvider":
            if let raw = body["kind"] as? String, let type = AIProvider(rawValue: raw), !ai.needsReset { ai.addProvider(type) }
        case "deleteProvider", "removeKey":
            guard let id, ai.providers.contains(where: { $0.id == id }) else { return }
            if action == "deleteProvider" { ai.deleteProvider(id) }
            else { ai.select(id); ai.removeKey() }
        case "saveProvider", "models":
            guard let id, var config = ai.providers.first(where: { $0.id == id }),
                  let name = body["name"] as? String, name.count <= 256,
                  let providerID = body["providerID"] as? String, providerID.count <= 64,
                  let url = body["baseURL"] as? String, url.count <= 4096,
                  let rawProtocol = body["protocol"] as? String, let apiProtocol = AIProtocol(rawValue: rawProtocol),
                  let rawSearch = body["search"] as? String, let search = AINativeSearch(rawValue: rawSearch),
                  let models = body["models"] as? [String], models.count <= 2048,
                  models.allSatisfy({ !$0.isEmpty && $0.count <= 512 }) else { throw PerchError("请检查供应商字段和模型名称的长度。") }
            config.name = name; config.providerID = providerID; config.baseURL = url
            config.apiProtocol = apiProtocol
            config.nativeSearch = search.definition(protocol: apiProtocol) == nil ? .none : search
            var seen = Set<String>()
            config.models = models.filter { seen.insert($0).inserted }
            if !config.models.contains(config.model) { config.model = config.models.first ?? "" }
            if action == "saveProvider" {
                guard ai.save(config, key: key) else { throw PerchError(ai.settingsError ?? "无法保存模型供应商。") }
            } else {
                modelTask?.cancel()
                discoveredModels = []; discoveryID = id.uuidString
                modelTask = Task { @MainActor [weak self] in
                    do {
                        let names = try await ai.models(for: config, key: key)
                        guard !Task.isCancelled else { return }
                        self?.discoveredModels = names
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.errors[.ai] = error.localizedDescription
                    }
                    self?.modelTask = nil; self?.update()
                }
            }
        case "saveSearch":
            guard let name = body["name"] as? String, name.count <= 256,
                  let url = body["baseURL"] as? String, url.count <= 4096 else { throw PerchError("请检查搜索供应商名称和 API 地址的长度。") }
            var config = ai.searchConfiguration ?? AISearchConfiguration()
            config.name = name; config.baseURL = url
            guard ai.saveSearch(config, key: key) else { throw PerchError(ai.searchSettingsError ?? "无法保存搜索供应商。") }
        case "removeSearchKey": ai.removeSearchKey()
        case "deleteSearch": ai.deleteSearch()
        case "reset": if ai.needsReset { ai.resetConfiguration() }
        case "directory":
            guard let directory = ai.conversationDirectory else { return }
            ai.saveConversations()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(directory) else { throw PerchError("无法打开存储文件夹。") }
        default: return
        }
        if action != "models", let message = action.contains("Search") ? ai.searchSettingsError : ai.settingsError {
            throw PerchError(message)
        }
    }

    func bookmarkState(_ store: Store) -> [String: Any] {
        func site(_ item: Site) -> [String: String] {
            ["id": item.id.uuidString, "title": item.title, "address": item.address,
             "folder": item.folderID?.uuidString ?? "", "home": item.showOnHome == false ? "false" : "true"]
        }
        func imported(_ items: [BookmarkNode]) -> [[String: Any]] {
            items.map { node in
                var result: [String: Any] = ["id": node.id.uuidString, "title": node.title]
                if let address = node.address { result["address"] = address }
                else { result["children"] = imported(node.children ?? []) }
                return result
            }
        }
        return [
            "sites": store.sites.map(site),
            "folders": store.bookmarkFolders.map {
                ["id": $0.id.uuidString, "title": $0.title, "path": store.bookmarkFolderPath($0.id),
                 "parent": $0.parentID?.uuidString ?? ""]
            },
            "imported": store.importedBookmarks.mapValues(imported),
            "groups": store.tabGroups.map { group in
                ["id": group.id.uuidString, "name": group.name, "color": group.color.rawValue, "hidden": group.hidden,
                 "tabs": store.tabs(inGroup: group.id).map {
                    ["id": $0.id.uuidString, "title": $0.displayTitle, "address": $0.address]
                 }] as [String: Any]
            },
            "colors": TabGroupColor.allCases.map { color in
                ["id": color.rawValue, "name": color.name,
                 "color": "rgb(\(Int(color.color.redComponent * 255)),\(Int(color.color.greenComponent * 255)),\(Int(color.color.blueComponent * 255)))"]
            },
            "scope": store.settingsBookmarkScope
        ]
    }

    func bookmarkAction(_ action: String, body: [String: Any], store: Store) throws {
        func uuid(_ key: String) -> UUID? { (body[key] as? String).flatMap(UUID.init(uuidString:)) }
        let id = uuid("id"), folder = uuid("folder")
        let ids = Set((body["ids"] as? [String] ?? []).prefix(10000).compactMap(UUID.init(uuidString:)))
        let title = String((body["title"] as? String ?? "").prefix(80))
        let address = String((body["address"] as? String ?? "").prefix(8192))
        switch action {
        case "scope":
            guard let scope = body["scope"] as? String,
                  scope == "root" || scope == "all" ||
                    store.bookmarkFolders.contains(where: { scope == "folder:" + $0.id.uuidString }) ||
                    store.tabGroups.contains(where: { scope == "group:" + $0.id.uuidString }) ||
                    store.importedBookmarks.keys.contains(where: { scope == "imported:" + $0 }) else { return }
            store.settingsBookmarkScope = scope
        case "save":
            if let id {
                guard let item = store.sites.first(where: { $0.id == id }) else { return }
                _ = store.edit(item, title: title, address: address, folderID: folder, showOnHome: body["home"] as? Bool)
            } else {
                _ = store.add(title: title, address: address, folderID: folder, showOnHome: body["home"] as? Bool)
            }
        case "folder":
            if let id {
                guard var item = store.bookmarkFolders.first(where: { $0.id == id }) else { return }
                item.title = title; item.parentID = folder
                _ = store.saveBookmarkFolder(item)
            } else { _ = store.saveBookmarkFolder(BookmarkFolder(title: title, parentID: folder)) }
        case "move": _ = store.moveBookmarkItems(ids, to: folder)
        case "reorder": _ = store.reorderBookmarkSites((body["ids"] as? [String] ?? []).prefix(10000).compactMap(UUID.init(uuidString:)))
        case "delete": _ = store.deleteBookmarkItems(ids)
        case "copy": store.copyBookmarkItems(ids, to: .general)
        case "cut": store.cutBookmarkItems(ids, to: .general)
        case "paste": _ = store.pasteBookmarks(from: .general, to: folder)
        case "home": if let id { store.toggleBookmarkHome(id) }
        case "open":
            store.openBookmarks(store.bookmarkSelectionPayload(ids).sites)
        case "preview", "copyAddress":
            let items = store.sites + store.importedBookmarks.values.flatMap { $0.flatMap(\.sites) }
            guard let id, let item = items.first(where: { $0.id == id }) else { return }
            if action == "copyAddress" { copyAddress(item.address) }
            else if let window = web?.window, let tabID = store.selected {
                store.bookmarkEditor.preview(item, store: store, parent: window, tabID: tabID)
            }
        case "openGroup": if let id { store.openTabGroup(id, tabID: uuid("tab")) }
        case "editGroup":
            if let id, let raw = body["color"] as? String, let color = TabGroupColor(rawValue: raw) {
                store.editTabGroup(id, name: title, color: color)
            }
        case "hideGroup": if let id { store.hideTabGroup(id) }
        case "dissolveGroup": if let id { store.ungroup(id) }
        case "deleteGroup": if let id { store.deleteTabGroup(id) }
        default: return
        }
        if let notice = store.notice { store.notice = nil; throw PerchError(notice) }
    }

    func passwordAction(_ action: String, body: [String: Any], store: Store) throws {
        let vault = store.passwords
        let id = (body["id"] as? String).flatMap(UUID.init(uuidString:))
        let entry = id.flatMap { id in vault.entries.first { $0.id == id } }
        switch action {
        case "unlock": try vault.load(allowInteraction: true)
        case "initialize": try vault.initializeWithoutLegacyAuthorization()
        case "save":
            guard let secret = body["secret"] as? String, !secret.isEmpty, secret.utf8.count <= 16384 else { return }
            let origin = entry?.origin ?? body["origin"] as? String ?? ""
            let user = entry?.username ?? body["username"] as? String ?? ""
            guard (id == nil || entry != nil), origin.count <= 4096, user.count <= 1024 else { return }
            if let entry {
                authenticatedPassword(entry, store: store) {
                    _ = try vault.save([SavedPassword(id: entry.id, origin: origin, username: user, password: secret)])
                }
            } else { _ = try vault.save([SavedPassword(id: UUID(), origin: origin, username: user, password: secret)]) }
        case "delete": if let entry { try vault.delete(entry.id) }
        case "reveal", "copy":
            guard let entry else { return }
            authenticatedPassword(entry, store: store) { [weak self] in
                if action == "copy" {
                    copyAddress(entry.password)
                    let change = NSPasteboard.general.changeCount
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
                    }
                } else if let window = self?.web?.window { self?.revealPassword(entry.password, origin: entry.origin, in: window) }
            }
        default: return
        }
    }

    private func authenticatedPassword(_ entry: SavedPassword, store: Store, action: @escaping () throws -> Void) {
        Task { @MainActor [weak self, weak store] in
            do {
                try await PasswordVault.authenticate()
                guard let self, let store, let web = self.web, web.window != nil,
                      SettingsRoute(web.url) == .passwords, store.browser?.webView === web,
                      store.passwords.entries.contains(entry) else { return }
                try action()
            } catch { self?.error = error.localizedDescription }
            self?.update()
        }
    }
}
