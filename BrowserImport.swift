import Foundation
import SQLite3
import Security
import CommonCrypto
import LocalAuthentication

enum ImportSource: String, CaseIterable, Identifiable {
    case safari = "Safari", chrome = "Chrome", firefox = "Firefox"
    var id: String { rawValue }
    var defaultDirectory: URL {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        switch self {
        case .safari: return library.appendingPathComponent("Safari")
        case .chrome:
            let root = library.appendingPathComponent("Application Support/Google/Chrome")
            return profiles(in: root).first ?? root.appendingPathComponent("Default")
        case .firefox:
            let root = library.appendingPathComponent("Application Support/Firefox/Profiles")
            return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first(where: { $0.lastPathComponent.contains("default-release") }) ?? root
        }
    }

    func profiles(in root: URL) -> [URL] {
        let manager = FileManager.default
        return ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
                return ["Bookmarks", "History", "Login Data", "Login Data For Account", "Cookies", "Network/Cookies", "places.sqlite", "cookies.sqlite"]
                    .contains { manager.fileExists(atPath: url.appendingPathComponent($0).path) }
            }.sorted {
                if $0.lastPathComponent == "Default" { return true }
                if $1.lastPathComponent == "Default" { return false }
                return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }
}

struct ImportOptions {
    var source: ImportSource
    var directory: URL
    var cookieFile: URL?
    var cookies = true
    var bookmarks = true
    var history = true
    var accessDirectory: URL?
    var passwords = false
    var passwordFile: URL?
}

struct ImportResult {
    var cookies: [HTTPCookie] = []
    var bookmarks: [Site] = []
    var bookmarkTree: [BookmarkNode]?
    var history: [Visit] = []
    var skipped = 0
    var messages: [String] = []
    var requiresFileAccess = false
    var passwords: [SavedPassword] = []
    var skippedPasswords = 0
}

enum ImportFileAccess {
    static func denied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { denied($0) } ?? false
    }
}

/// Prefer a read transaction; exclusively locked browser files need a private, stable snapshot.
final class ImportDatabase {
    private var db: OpaquePointer?
    private let source: URL
    private var snapshot: URL?
    init(_ url: URL) throws {
        source = url.resolvingSymlinksInPath()
        // Preserve the OS permission error instead of reducing it to SQLite's generic CANTOPEN.
        let file = try FileHandle(forReadingFrom: url)
        try file.close()
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = databaseError("无法读取 \(url.lastPathComponent)：请确认资料目录，并退出源浏览器后重试。")
            if let db { sqlite3_close(db) }; db = nil
            throw error
        }
        sqlite3_busy_timeout(db, 1500)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            let error = databaseError("无法建立数据库读取快照。")
            sqlite3_close(db); db = nil; throw error
        }
    }
    deinit {
        if let db { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
    }

    private func databaseError(_ message: String) -> Error {
        let code = db.map { sqlite3_system_errno($0) } ?? 0
        if code == EACCES || code == EPERM { return NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        let sqliteCode = db.map { sqlite3_errcode($0) & 0xff } ?? 0
        if sqliteCode == SQLITE_BUSY || sqliteCode == SQLITE_LOCKED {
            return NSError(domain: "Perch.SQLiteBusy", code: Int(sqliteCode),
                           userInfo: [NSLocalizedDescriptionKey: "源浏览器正在锁定数据库，请退出源浏览器后重试。"])
        }
        return PerchError(message)
    }

    func rows(_ sql: String) throws -> [[String: SQLValue]] {
        do { return try readRows(sql) }
        catch {
            guard (error as NSError).domain == "Perch.SQLiteBusy", snapshot == nil else { throw error }
            try openStableSnapshot()
            return try readRows(sql)
        }
    }

    private func openStableSnapshot() throws {
        struct Stamp: Equatable {
            let size: UInt64
            let modified: Date
            let inode: UInt64
        }
        let manager = FileManager.default
        let files = [source, URL(fileURLWithPath: source.path + "-wal"), URL(fileURLWithPath: source.path + "-journal")]
        func stamp(_ file: URL) throws -> Stamp? {
            do {
                let attributes = try manager.attributesOfItem(atPath: file.resolvingSymlinksInPath().path)
                return Stamp(size: (attributes[.size] as! NSNumber).uint64Value,
                             modified: attributes[.modificationDate] as! Date,
                             inode: (attributes[.systemFileNumber] as! NSNumber).uint64Value)
            } catch where (error as NSError).domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code) { return nil }
        }
        for _ in 0..<3 {
            let directory = manager.temporaryDirectory.appendingPathComponent("perch-db-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var retain = false
            defer { if !retain { try? manager.removeItem(at: directory) } }
            let before = try files.map(stamp)
            guard before[0] != nil else { throw PerchError("源数据库已被移除，请重新选择资料目录。") }
            do {
                for (file, metadata) in zip(files, before) where metadata != nil {
                    let target = directory.appendingPathComponent(file.lastPathComponent)
                    try manager.copyItem(at: file.resolvingSymlinksInPath(), to: target)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                }
            } catch {
                if try files.map(stamp) != before { continue }
                throw error
            }
            guard try files.map(stamp) == before else { continue }
            if let db { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }; db = nil
            let copy = directory.appendingPathComponent(source.lastPathComponent)
            // Only the private copy may recover its journal or rebuild shared-memory WAL metadata.
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
                throw PerchError("无法读取浏览器数据库快照，请退出源浏览器后重试。")
            }
            snapshot = directory; retain = true
            return
        }
        throw PerchError("源数据库持续写入，未取得一致快照。请退出源浏览器后重试。")
    }

    private func readRows(_ sql: String) throws -> [[String: SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError("源数据库结构不受支持（\(String(cString: sqlite3_errmsg(db)))）。请选择其他资料目录；密码可改用导出 CSV。")
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String: SQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw databaseError("源数据库读取失败或正在使用，请退出源浏览器后重试。") }
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_BLOB:
                    let size = Int(sqlite3_column_bytes(statement, index))
                    row[name] = .blob(sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: size) } ?? Data())
                case SQLITE_INTEGER, SQLITE_FLOAT: row[name] = .number(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                default: row[name] = .text("")
                }
            }
            result.append(row)
        }
    }
}

enum SQLValue { case text(String), number(Double), blob(Data) }
extension Dictionary where Key == String, Value == SQLValue {
    func string(_ key: String) -> String {
        switch self[key] {
        case .text(let text): return text
        case .number(let value): return value.isFinite && value >= Double(Int32.min) && value <= Double(Int32.max) ? String(Int64(value)) : String(value)
        default: return ""
        }
    }
    func number(_ key: String) -> Double {
        switch self[key] { case .number(let value): return value; case .text(let value): return Double(value) ?? 0; default: return 0 }
    }
    func blob(_ key: String) -> Data { if case .blob(let data) = self[key] { return data }; return Data() }
}

enum BrowserImporter {
    static func read(_ options: ImportOptions) -> ImportResult {
        let resources = [options.accessDirectory, options.cookieFile, options.passwordFile].compactMap { $0 }
            .filter { $0.startAccessingSecurityScopedResource() }
        defer { resources.forEach { $0.stopAccessingSecurityScopedResource() } }
        var result = ImportResult()
        func report(_ category: String, _ error: Error) {
            if ImportFileAccess.denied(error) {
                result.requiresFileAccess = true
                result.messages.append("\(category)：macOS 拒绝访问所选文件，请按下方提示授权后重试。")
            } else { result.messages.append("\(category)：\(error.localizedDescription)") }
        }
        if options.bookmarks || options.history || (options.cookies && options.cookieFile == nil) ||
            (options.passwords && options.passwordFile == nil) {
            do {
                guard try options.directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw PerchError("请选择实际 Profile 目录。")
                }
            } catch {
                if ImportFileAccess.denied(error) { report("资料目录", error) }
                else { result.messages.append("资料目录不存在或不可用：\(options.directory.path)。请选择实际 Profile 目录。") }
                return result
            }
        }
        if options.bookmarks {
            do {
                let tree = try bookmarkTree(options)
                result.bookmarkTree = tree
                result.bookmarks = tree.flatMap(\.sites)
            }
            catch { report("书签", error) }
        }
        if options.history {
            do { result.history = try history(options) }
            catch { report("历史", error) }
        }
        if options.cookies {
            do {
                let parsed = try cookies(options)
                result.cookies = parsed.cookies; result.skipped = parsed.skipped
                result.messages += parsed.messages
            } catch { report("Cookie", error) }
        }
        if options.passwords {
            do {
                let parsed = try passwords(options)
                result.passwords = parsed.items; result.skippedPasswords = parsed.skipped
            } catch { report("密码", error) }
        }
        return result
    }

    static func passwords(_ options: ImportOptions) throws -> (items: [SavedPassword], skipped: Int) {
        if let file = options.passwordFile {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16 * 1024 * 1024 else { throw PerchError("密码 CSV 超过 16 MB，未读取。") }
            return try PasswordCSV.read(Data(contentsOf: file))
        }
        guard options.source == .chrome else {
            throw PerchError("请在 \(options.source.rawValue) 的密码管理中导出 CSV，再点击「选择密码 CSV」。不会直接读取或修改源浏览器的密码钥匙串。")
        }
        let candidates = ["Login Data", "Login Data For Account"].map { options.directory.appendingPathComponent($0) }
        let available = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        var rows: [[String: SQLValue]] = []
        for file in available.isEmpty ? [candidates[0]] : available {
            let db = try ImportDatabase(file)
            rows += try db.rows("SELECT origin_url,signon_realm,username_value,password_value FROM logins WHERE blacklisted_by_user=0 LIMIT 10001")
            guard rows.count <= 10000 else { throw PerchError("Chrome 密码超过 10,000 条，未导入。") }
        }
        guard rows.count <= 10000 else { throw PerchError("Chrome 密码超过 10,000 条，未导入。") }
        guard !rows.isEmpty else { return ([], 0) }
        let key = try chromeKey()
        var items: [SavedPassword] = []
        var skipped = 0
        for row in rows {
            guard let origin = SavedPassword.origin(for: row.string("origin_url").isEmpty ?
                row.string("signon_realm") : row.string("origin_url")) else { skipped += 1; continue }
            do {
                let password = try decryptChrome(row.blob("password_value"), key: key, domain: "", version: 0)
                let item = try SavedPassword(origin: origin, username: row.string("username_value"), password: password).validated()
                items.append(item)
            } catch { skipped += 1 }
        }
        return (items, skipped)
    }

    static func bookmarkTree(_ options: ImportOptions) throws -> [BookmarkNode] {
        switch options.source {
        case .chrome:
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: options.directory.appendingPathComponent("Bookmarks")))
            guard let roots = (object as? [String: Any])?["roots"] as? [String: Any] else {
                throw PerchError("Chrome 书签结构不完整。")
            }
            func node(_ value: Any, fallback: String = "") throws -> BookmarkNode {
                guard let item = value as? [String: Any] else { throw PerchError("Chrome 书签节点损坏。") }
                let title = item["name"] as? String ?? fallback
                if let address = item["url"] as? String { return BookmarkNode(title: title, address: address) }
                guard let children = item["children"] as? [Any] else { throw PerchError("Chrome 书签文件夹损坏。") }
                return BookmarkNode(title: title, children: try children.map { try node($0) })
            }
            let order = ["bookmark_bar", "other", "synced"]
            return try (order.filter { roots[$0] != nil } + roots.keys.filter { !order.contains($0) }.sorted())
                .map { try node(roots[$0]!, fallback: $0) }
        case .safari:
            let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: options.directory.appendingPathComponent("Bookmarks.plist")), format: nil)
            func node(_ value: Any) throws -> BookmarkNode {
                guard let item = value as? [String: Any] else { throw PerchError("Safari 书签节点损坏。") }
                if let address = item["URLString"] as? String {
                    let title = (item["URIDictionary"] as? [String: Any])?["title"] as? String ?? address
                    return BookmarkNode(title: title, address: address)
                }
                let title = item["Title"] as? String ?? ""
                if item["WebBookmarkType"] as? String == "WebBookmarkTypeProxy" {
                    return BookmarkNode(title: title)
                }
                guard let children = item["Children"] as? [Any] else { throw PerchError("Safari 书签文件夹损坏。") }
                return BookmarkNode(title: title, children: try children.map(node))
            }
            guard let root = object as? [String: Any], let children = root["Children"] as? [Any] else {
                throw PerchError("Safari 书签结构不完整。")
            }
            return try children.map(node)
        case .firefox:
            let db = try ImportDatabase(options.directory.appendingPathComponent("places.sqlite"))
            let rows = try db.rows("SELECT b.id,b.parent,b.position,b.type,b.title,b.guid,p.url FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id=b.fk ORDER BY b.position,b.id")
            let groups = Dictionary(grouping: rows, by: { Int($0.number("parent")) })
            var visiting = Set<Int>()
            func node(_ row: [String: SQLValue], depth: Int) throws -> BookmarkNode {
                let id = Int(row.number("id"))
                guard depth < 256, visiting.insert(id).inserted else { throw PerchError("Firefox 书签目录包含循环或层级过深。") }
                defer { visiting.remove(id) }
                let defaults = ["toolbar_____": "书签工具栏", "menu________": "书签菜单",
                                "unfiled_____": "其他书签", "mobile______": "移动设备书签"]
                let title = row.string("title").isEmpty ? defaults[row.string("guid")] ?? "" : row.string("title")
                switch Int(row.number("type")) {
                case 1: return BookmarkNode(title: title, address: row.string("url"))
                case 2:
                    return BookmarkNode(title: title, children: try (groups[id] ?? []).map { try node($0, depth: depth + 1) })
                case 3: return BookmarkNode(title: "")
                default: throw PerchError("Firefox 书签节点类型不受支持。")
                }
            }
            guard let root = rows.first(where: { $0.string("guid") == "root________" }) ??
                rows.first(where: { $0.number("parent") == 0 && $0.number("type") == 2 }) else {
                throw PerchError("Firefox 书签根目录不存在。")
            }
            return try (groups[Int(root.number("id"))] ?? []).map { try node($0, depth: 0) }
        }
    }

    static func history(_ options: ImportOptions) throws -> [Visit] {
        let file: String
        let sql: String
        let divisor: Double
        let offset: Double
        switch options.source {
        case .chrome:
            file = "History"
            sql = "SELECT url, title, last_visit_time AS visited FROM urls WHERE last_visit_time>0 ORDER BY last_visit_time DESC LIMIT 10000"
            divisor = 1_000_000; offset = -11_644_473_600
        case .firefox:
            file = "places.sqlite"
            sql = "SELECT url, title, last_visit_date AS visited FROM moz_places WHERE last_visit_date>0 ORDER BY last_visit_date DESC LIMIT 10000"
            divisor = 1_000_000; offset = 0
        case .safari:
            file = "History.db"
            sql = "SELECT i.url, v.title, v.visit_time AS visited FROM history_visits v JOIN history_items i ON i.id=v.history_item ORDER BY v.visit_time DESC LIMIT 10000"
            divisor = 1; offset = 978_307_200
        }
        let db = try ImportDatabase(options.directory.appendingPathComponent(file))
        return try db.rows(sql).compactMap { row in
            let seconds = row.number("visited") / divisor + offset
            guard seconds.isFinite, seconds >= 0, seconds <= Date().timeIntervalSince1970 + 86400,
                  URLInput.parse(row.string("url"), search: false) != nil else { return nil }
            return Visit(title: row.string("title"), address: row.string("url"),
                         date: Date(timeIntervalSince1970: seconds))
        }
    }

    static func cookie(domain: String, name: String, value: String, path: String, secure: Bool, httpOnly: Bool,
                       expires: Date?, sameSite: String = "") -> HTTPCookie? {
        guard !domain.isEmpty, !name.isEmpty, path.hasPrefix("/"),
              !(domain + name + value + path).unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              expires == nil || (expires!.timeIntervalSince1970.isFinite && expires! > Date()) else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .name: name, .value: value, .path: path,
            .secure: secure ? "TRUE" : "FALSE",
            HTTPCookiePropertyKey("HttpOnly"): httpOnly ? "TRUE" : "FALSE"
        ]
        if let expires { properties[.expires] = expires }
        let policy = sameSite.lowercased()
        if ["strict", "lax", "none"].contains(policy) { properties[.sameSitePolicy] = policy }
        else if policy == "no_restriction" { properties[.sameSitePolicy] = "none" }
        return HTTPCookie(properties: properties)
    }

    static func cookies(_ options: ImportOptions) throws -> ImportResult {
        if let file = options.cookieFile {
            let data = try Data(contentsOf: file)
            if data.starts(with: Data("cook".utf8)) { return try binaryCookies(data) }
            return try exportedCookies(data)
        }
        switch options.source {
        case .safari:
            let home = FileManager.default.homeDirectoryForCurrentUser
            let candidates = [
                home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")
            ]
            for file in candidates {
                if let data = try? Data(contentsOf: file) { return try binaryCookies(data) }
            }
            throw PerchError("无法读取 Safari Cookie。请在系统设置中给 Perch「完全磁盘访问权限」后重启，或选择导出的 Cookie 文件。")
        case .firefox:
            let db = try ImportDatabase(options.directory.appendingPathComponent("cookies.sqlite"))
            var result = ImportResult()
            for row in try db.rows("SELECT * FROM moz_cookies LIMIT 100000") {
                guard row.string("originAttributes").isEmpty else { result.skipped += 1; continue }
                let expiry = row.number("expiry")
                let sameSite = row.number("sameSite") == 1 ? "Lax" : row.number("sameSite") == 2 ? "Strict" : "None"
                if let item = cookie(domain: row.string("host"), name: row.string("name"), value: row.string("value"),
                                     path: row.string("path"), secure: row.number("isSecure") != 0,
                                     httpOnly: row.number("isHttpOnly") != 0,
                                     expires: expiry > 0 ? Date(timeIntervalSince1970: expiry) : nil, sameSite: sameSite) {
                    result.cookies.append(item)
                } else { result.skipped += 1 }
            }
            return result
        case .chrome:
            let network = options.directory.appendingPathComponent("Network/Cookies")
            let file = FileManager.default.fileExists(atPath: network.path) ? network : options.directory.appendingPathComponent("Cookies")
            let db = try ImportDatabase(file)
            let rows = try db.rows("SELECT * FROM cookies LIMIT 100000")
            let version = try db.rows("SELECT value FROM meta WHERE key='version'").first?.number("value") ?? 0
            var result = ImportResult()
            var key: Data?
            if rows.contains(where: { $0.blob("encrypted_value").starts(with: Data("v10".utf8)) && $0.string("top_frame_site_key").isEmpty }) {
                do { key = try chromeKey() }
                catch { result.messages.append(error.localizedDescription) }
            }
            for row in rows {
                guard row.string("top_frame_site_key").isEmpty else { result.skipped += 1; continue }
                let domain = row.string("host_key")
                let encrypted = row.blob("encrypted_value")
                let value: String
                if !encrypted.isEmpty {
                    guard let key, let decoded = try? decryptChrome(encrypted, key: key, domain: domain, version: Int(version)) else {
                        result.skipped += 1; continue
                    }
                    value = decoded
                } else { value = row.string("value") }
                let expiry = row.number("expires_utc")
                let sameSite = row.number("samesite") == 1 ? "Lax" : row.number("samesite") == 2 ? "Strict" : row.number("samesite") == 0 ? "None" : ""
                if let item = cookie(domain: domain, name: row.string("name"), value: value, path: row.string("path"),
                                     secure: row.number("is_secure") != 0, httpOnly: row.number("is_httponly") != 0,
                                     expires: expiry > 0 ? Date(timeIntervalSince1970: expiry / 1_000_000 - 11_644_473_600) : nil,
                                     sameSite: sameSite) {
                    result.cookies.append(item)
                } else { result.skipped += 1 }
            }
            return result
        }
    }

    static func chromeKey() throws -> Data {
        let context = LAContext()
        context.localizedReason = "Perch 需要解密你选择导入的 Chrome Cookie 或密码"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            throw PerchError("无法访问 Chrome Safe Storage（\(status)），加密 Cookie 已跳过。可允许钥匙串访问后重试，或导出 Cookie 文件。")
        }
        return try deriveChromeKey(password)
    }

    static func deriveChromeKey(_ password: Data) throws -> Data {
        var output = Data(count: 16)
        let salt = Data("saltysalt".utf8)
        let status = output.withUnsafeMutableBytes { outputBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                        outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
                }
            }
        }
        guard status == kCCSuccess else { throw PerchError("Chrome Cookie 密钥派生失败。") }
        return output
    }

    static func sha256(_ data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = digest.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { source in CC_SHA256(source.baseAddress, CC_LONG(data.count), out.baseAddress?.assumingMemoryBound(to: UInt8.self)) }
        }
        return digest
    }

    static func decryptChrome(_ data: Data, key: Data, domain: String, version: Int) throws -> String {
        guard data.starts(with: Data("v10".utf8)), key.count == 16 else { throw PerchError("不支持此 Cookie 加密版本。") }
        let encrypted = Data(data.dropFirst(3))
        var output = Data(count: encrypted.count + kCCBlockSizeAES128)
        var written = 0
        let iv = Data(repeating: 0x20, count: 16)
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            encrypted.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, encrypted.count,
                                out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw PerchError("Cookie 解密失败。") }
        output.count = written
        if version >= 24 {
            guard output.count >= 32, output.prefix(32) == sha256(Data(domain.utf8)) else { throw PerchError("Cookie 域名校验失败。") }
            output = Data(output.dropFirst(32))
        }
        guard let text = String(data: output, encoding: .utf8) else { throw PerchError("Cookie 内容编码不受支持。") }
        return text
    }

    static func binaryCookies(_ data: Data) throws -> ImportResult {
        let bytes = [UInt8](data)
        func integer(_ bytes: [UInt8], _ offset: Int, big: Bool = false) throws -> Int {
            guard offset >= 0, offset <= bytes.count - 4 else { throw PerchError("Safari Cookie 文件不完整。") }
            let slice = Array(bytes[offset..<offset + 4])
            return (big ? slice : Array(slice.reversed())).reduce(0) { ($0 << 8) | Int($1) }
        }
        guard data.starts(with: Data("cook".utf8)) else { throw PerchError("不是 Safari Cookie 文件。") }
        let count = try integer(bytes, 4, big: true)
        guard count <= 100000, 8 + count * 4 <= bytes.count else { throw PerchError("Safari Cookie 页数无效。") }
        var start = 8 + count * 4
        var result = ImportResult()
        for pageIndex in 0..<count {
            let size = try integer(bytes, 8 + pageIndex * 4, big: true)
            guard size >= 12, start <= bytes.count - size else { throw PerchError("Safari Cookie 页面越界。") }
            let page = Array(bytes[start..<start + size]); start += size
            guard Array(page.prefix(4)) == [0, 0, 1, 0] else { throw PerchError("Safari Cookie 页面格式不支持。") }
            let records = try integer(page, 4)
            guard records <= 100000, 8 + records * 4 <= page.count else { throw PerchError("Safari Cookie 记录表无效。") }
            for recordIndex in 0..<records {
                do {
                    let offset = try integer(page, 8 + recordIndex * 4)
                    let length = try integer(page, offset)
                    guard offset >= 8 + records * 4, length >= 56, offset <= page.count - length else { throw PerchError("记录越界") }
                    let record = Array(page[offset..<offset + length])
                    func string(_ index: Int) throws -> String {
                        let from = try integer(record, index)
                        guard from >= 56, from < record.count, let end = record[from...].firstIndex(of: 0),
                              let value = String(bytes: record[from..<end], encoding: .utf8) else { throw PerchError("字符串越界") }
                        return value
                    }
                    var bits: UInt64 = 0
                    for i in 0..<8 { bits |= UInt64(record[40 + i]) << (8 * i) }
                    let seconds = Double(bitPattern: bits)
                    guard seconds.isFinite else { throw PerchError("过期时间无效") }
                    let flags = try integer(record, 8)
                    if let item = try cookie(domain: string(16), name: string(20), value: string(28), path: string(24),
                                             secure: flags & 1 != 0, httpOnly: flags & 4 != 0,
                                             expires: seconds > 0 ? Date(timeIntervalSinceReferenceDate: seconds) : nil) {
                        result.cookies.append(item)
                    } else { result.skipped += 1 }
                } catch { result.skipped += 1 }
            }
        }
        return result
    }

    static func exportedCookies(_ data: Data) throws -> ImportResult {
        var result = ImportResult()
        if let object = try? JSONSerialization.jsonObject(with: data) {
            let list = object as? [[String: Any]] ?? (object as? [String: Any])?["cookies"] as? [[String: Any]]
            guard let list else { throw PerchError("JSON 应是 Cookie 数组或包含 cookies 数组的对象。") }
            for item in list {
                let storeID = item["storeId"] as? String ?? ""
                let partitioned = item["partitionKey"].map { !($0 is NSNull) } ?? false
                if partitioned || item["partitionKeyOpaque"] as? Bool == true || storeID.hasPrefix("firefox-container-") || storeID == "firefox-private" {
                    result.skipped += 1; continue
                }
                let expiry = item["expirationDate"] as? Double ?? item["expires"] as? Double
                if let domain = item["domain"] as? String, let name = item["name"] as? String, let value = item["value"] as? String,
                   let cookie = cookie(domain: domain, name: name, value: value, path: item["path"] as? String ?? "/",
                                       secure: item["secure"] as? Bool ?? false, httpOnly: item["httpOnly"] as? Bool ?? false,
                                       expires: item["session"] as? Bool == true ? nil : expiry.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                                       sameSite: item["sameSite"] as? String ?? "") {
                    result.cookies.append(cookie)
                } else { result.skipped += 1 }
            }
            return result
        }
        guard let text = String(data: data, encoding: .utf8) else { throw PerchError("支持 Safari binarycookies、JSON 或 Netscape cookies.txt。") }
        var candidates = 0
        for line in text.components(separatedBy: .newlines) {
            let httpOnly = line.hasPrefix("#HttpOnly_")
            if line.isEmpty || (line.hasPrefix("#") && !httpOnly) { continue }
            candidates += 1
            let fields = (httpOnly ? String(line.dropFirst(10)) : line).components(separatedBy: "\t")
            guard fields.count == 7, let expiry = Double(fields[4]) else { result.skipped += 1; continue }
            if let item = cookie(domain: fields[0], name: fields[5], value: fields[6], path: fields[2], secure: fields[3] == "TRUE",
                                 httpOnly: httpOnly, expires: expiry > 0 ? Date(timeIntervalSince1970: expiry) : nil) {
                result.cookies.append(item)
            } else { result.skipped += 1 }
        }
        guard candidates == 0 || !result.cookies.isEmpty || result.skipped > 0 else { throw PerchError("Cookie 文件格式无法识别。") }
        return result
    }
}
