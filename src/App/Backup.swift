import AppKit
import ServiceManagement

// Register persistent layout preferences here; capture and restore enumerate the same keys.
enum LayoutPreference: String, CaseIterable {
    case sidebarHidden, sidebarWidth, aiSidebarWidth, chatHistoryWidth, previewContentSize, windowFrame

    enum Value: Codable {
        case flag(Bool), number(Double), text(String)
        var object: Any {
            switch self {
            case .flag(let value): return value
            case .number(let value): return value
            case .text(let value): return value
            }
        }
    }

    func read(_ defaults: UserDefaults) -> Value? {
        guard defaults.object(forKey: rawValue) != nil else { return nil }
        switch self {
        case .sidebarHidden: return .flag(defaults.bool(forKey: rawValue))
        case .sidebarWidth, .aiSidebarWidth, .chatHistoryWidth: return .number(defaults.double(forKey: rawValue))
        case .previewContentSize, .windowFrame: return defaults.string(forKey: rawValue).map(Value.text)
        }
    }

    func validate(_ value: Value) throws {
        switch (self, value) {
        case (.sidebarHidden, .flag): return
        case (.sidebarWidth, .number(let width)), (.aiSidebarWidth, .number(let width)),
             (.chatHistoryWidth, .number(let width)):
            if width.isFinite && (100...10000).contains(width) { return }
        case (.previewContentSize, .text(let raw)):
            let size = NSSizeFromString(raw)
            if [size.width, size.height].allSatisfy({ $0.isFinite && (100...10000).contains($0) }) { return }
        case (.windowFrame, .text(let raw)):
            let rect = NSRectFromString(raw)
            if [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite && abs($0) <= 100000 }),
               rect.width >= 100, rect.height >= 100 { return }
        default: break
        }
        throw PerchError("备份中的界面布局无效：\(rawValue)。")
    }

    static func capture(_ defaults: UserDefaults) -> [String: Value] {
        Dictionary(uniqueKeysWithValues: allCases.compactMap { key in key.read(defaults).map { (key.rawValue, $0) } })
    }
    static func restore(_ values: [String: Value], to defaults: UserDefaults) {
        for key in allCases {
            if let value = values[key.rawValue] { defaults.set(value.object, forKey: key.rawValue) }
            else { defaults.removeObject(forKey: key.rawValue) }
        }
    }
}

enum LaunchAtLogin {
    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }
    static func set(_ enabled: Bool) throws {
        guard enabled != self.enabled else { return }
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

enum BackupScope: String, Codable, CaseIterable {
    case settings, ai, bookmarks
    var title: String {
        switch self {
        case .settings: return "设置与布局"
        case .ai: return "AI 配置"
        case .bookmarks: return "书签"
        }
    }
}

struct BackupCredentials: Codable {
    var providers: [String: String] = [:]
    var search: String?
    var count: Int { providers.count + (search == nil ? 0 : 1) }
}

struct SettingsBackup: Codable {
    var format = "dev.perch.settings-bookmarks"
    var version = 2
    var created = Date()
    var settings: BrowserSettings
    var launchAtLogin: Bool
    var layout: [String: LayoutPreference.Value]
    var providers: [AIConfiguration]
    var selectedProvider: UUID
    var search: AISearchConfiguration?
    var sites: [Site]
    var folders: [BookmarkFolder]
    var imported: [String: [BookmarkNode]]
    var scope = Set(BackupScope.allCases)
    var credentials: BackupCredentials?
    var scopeDescription: String { BackupScope.allCases.filter(scope.contains).map(\.title).joined(separator: "、") }

    func validate() throws {
        guard format == "dev.perch.settings-bookmarks", [1, 2].contains(version), !scope.isEmpty,
              version != 1 || (scope == Set(BackupScope.allCases) && credentials == nil) else {
            throw PerchError("不支持此备份格式或版本，请使用兼容版本的 Perch。")
        }
        if scope.contains(.settings) {
            try settings.validate()
            for (key, value) in layout {
                guard let key = LayoutPreference(rawValue: key) else { continue }
                try key.validate(value)
            }
        }
        if scope.contains(.ai) {
            guard !providers.isEmpty, providers.count <= 100,
                  Set(providers.map(\.id)).count == providers.count,
                  Set(providers.map(\.providerID)).count == providers.count,
                  providers.contains(where: { $0.id == selectedProvider }) else {
                throw PerchError("备份中的 AI 供应商列表无效。")
            }
            for provider in providers {
                // Newly added custom providers may not have an endpoint or models yet.
                guard (provider.baseURL.isEmpty || provider.endpoint != nil),
                      !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      provider.providerID.range(of: #"^[a-z][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil,
                      provider.models.count <= 10000 else { throw PerchError("备份中的 AI 配置无效。") }
            }
            if let search, search.endpoint == nil || search.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PerchError("备份中的搜索配置无效。")
            }
        }
        if let credentials {
            let accounts = Set(providers.filter { $0.account != nil }.map { $0.id.uuidString })
            let keys = Array(credentials.providers.values) + (credentials.search.map { [$0] } ?? [])
            guard scope.contains(.ai), Set(credentials.providers.keys).isSubset(of: accounts),
                  credentials.search == nil || search != nil,
                  keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16384 && !$0.contains("\n") && !$0.contains("\r") }) else {
                throw PerchError("备份中的 AI 密钥或关联配置无效。")
            }
        }
        guard scope.contains(.bookmarks) else { return }
        guard sites.count + folders.count <= 50000 else { throw PerchError("备份中的书签过多。") }
        var ids = Set<UUID>()
        for folder in folders {
            guard ids.insert(folder.id).inserted else { throw PerchError("书签文件夹 ID 重复。") }
        }
        let parents = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.parentID) })
        for folder in folders {
            var path = Set([folder.id]), parent = folder.parentID
            while let id = parent {
                guard ids.contains(id), path.insert(id).inserted, path.count <= 64 else {
                    throw PerchError("书签文件夹包含无效层级或循环。")
                }
                parent = parents[id] ?? nil
            }
        }
        let folderIDs = ids
        for site in sites {
            guard ids.insert(site.id).inserted, URLInput.parse(site.address, search: false) != nil,
                  site.folderID.map({ folderIDs.contains($0) }) ?? true else {
                throw PerchError("备份中的书签地址、ID 或所属文件夹无效。")
            }
        }
        var count = sites.count + folders.count
        func check(_ nodes: [BookmarkNode], depth: Int, ids: inout Set<UUID>) throws {
            guard depth <= 64 else { throw PerchError("导入书签层级过深。") }
            for node in nodes {
                count += 1
                guard count <= 50000, ids.insert(node.id).inserted,
                      node.address.map({ URLInput.parse($0, search: false) != nil }) ?? true,
                      node.address == nil || node.children == nil else {
                    throw PerchError("备份中的导入书签无效或过多。")
                }
                if let children = node.children { try check(children, depth: depth + 1, ids: &ids) }
            }
        }
        for (source, nodes) in imported {
            guard ImportSource(rawValue: source) != nil else { throw PerchError("备份中的书签来源无效。") }
            var sourceIDs = Set<UUID>()
            try check(nodes, depth: 0, ids: &sourceIDs)
        }
    }

    func withFreshCredentialIDs() -> Self {
        var copy = self
        copy.credentials?.providers = [:]
        copy.providers = providers.map { provider in
            var value = provider
            value.id = UUID(); value.legacyAccount = nil; value.keyEnvironment = nil
            if provider.id == selectedProvider { copy.selectedProvider = value.id }
            if let key = credentials?.providers[provider.id.uuidString] {
                copy.credentials?.providers[value.id.uuidString] = key
            }
            return value
        }
        copy.search?.id = UUID(); copy.search?.keyEnvironment = ""
        return copy
    }
}

extension SettingsBackup {
    private enum CodingKeys: String, CodingKey {
        case format, version, created, scope, settings, launchAtLogin, layout, providers, selectedProvider
        case search, sites, folders, imported, credentials
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        let scope = version == 1 ? Set(BackupScope.allCases) : try c.decode(Set<BackupScope>.self, forKey: .scope)
        self.init(format: try c.decode(String.self, forKey: .format), version: version,
            created: try c.decode(Date.self, forKey: .created),
            settings: scope.contains(.settings) ? try c.decode(BrowserSettings.self, forKey: .settings) : BrowserSettings(),
            launchAtLogin: scope.contains(.settings) ? try c.decode(Bool.self, forKey: .launchAtLogin) : false,
            layout: scope.contains(.settings) ? try c.decode([String: LayoutPreference.Value].self, forKey: .layout) : [:],
            providers: scope.contains(.ai) ? try c.decode([AIConfiguration].self, forKey: .providers) : [],
            selectedProvider: scope.contains(.ai) ? try c.decode(UUID.self, forKey: .selectedProvider) : UUID(),
            search: scope.contains(.ai) ? try c.decodeIfPresent(AISearchConfiguration.self, forKey: .search) : nil,
            sites: scope.contains(.bookmarks) ? try c.decode([Site].self, forKey: .sites) : [],
            folders: scope.contains(.bookmarks) ? try c.decode([BookmarkFolder].self, forKey: .folders) : [],
            imported: scope.contains(.bookmarks) ? try c.decode([String: [BookmarkNode]].self, forKey: .imported) : [:],
            scope: scope, credentials: try c.decodeIfPresent(BackupCredentials.self, forKey: .credentials))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format); try c.encode(version, forKey: .version); try c.encode(created, forKey: .created)
        if version >= 2 { try c.encode(scope, forKey: .scope) }
        if scope.contains(.settings) {
            try c.encode(settings, forKey: .settings); try c.encode(launchAtLogin, forKey: .launchAtLogin)
            try c.encode(layout, forKey: .layout)
        }
        if scope.contains(.ai) {
            try c.encode(providers, forKey: .providers); try c.encode(selectedProvider, forKey: .selectedProvider)
            try c.encodeIfPresent(search, forKey: .search); try c.encodeIfPresent(credentials, forKey: .credentials)
        }
        if scope.contains(.bookmarks) {
            try c.encode(sites, forKey: .sites); try c.encode(folders, forKey: .folders); try c.encode(imported, forKey: .imported)
        }
    }
}

enum BackupArchive {
    static let limit = 16 * 1024 * 1024
    private static let entry = "perch-backup.json"

    // Read only stdout, never extract archive paths; cap every subprocess output and execution time.
    private static func run(_ executable: String, _ arguments: [String], directory: URL, limit: Int) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume()
        defer { timer.cancel(); try? pipe.fileHandleForReading.close() }
        var output = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard output.count + chunk.count <= limit else {
                process.terminate(); try? pipe.fileHandleForReading.close(); process.waitUntilExit()
                throw PerchError("备份文件超过大小限制。")
            }
            output.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PerchError("ZIP 文件损坏、加密或处理超时。") }
        return output
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PerchBackup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func write(_ backup: SettingsBackup, to destination: URL) throws {
        try backup.validate()
        let data = try JSONEncoder().encode(backup)
        guard data.count <= limit else { throw PerchError("备份数据超过 16 MB。") }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent(entry))
        _ = try run("/usr/bin/zip", ["-q", "backup.zip", entry], directory: directory, limit: 4096)
        try Data(contentsOf: directory.appendingPathComponent("backup.zip")).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func read(_ source: URL) throws -> SettingsBackup {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let data = try input.read(upToCount: limit * 2 + 1) ?? Data()
        guard data.count <= limit * 2 else { throw PerchError("ZIP 文件超过 32 MB。") }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent("backup.zip"))
        let list = try run("/usr/bin/unzip", ["-Z1", "backup.zip"], directory: directory, limit: 4096)
        guard String(data: list, encoding: .utf8) == entry + "\n" else {
            throw PerchError("请选择 Perch 导出的 ZIP 备份，文件清单不符合备份格式。")
        }
        let json = try run("/usr/bin/unzip", ["-p", "backup.zip", entry], directory: directory, limit: limit)
        let backup: SettingsBackup
        do { backup = try JSONDecoder().decode(SettingsBackup.self, from: json) }
        catch { throw PerchError("备份内容不完整或已损坏。") }
        try backup.validate()
        return backup
    }
}
