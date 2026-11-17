import Foundation
import Security
import CryptoKit

struct VaultRequest: Decodable {
    let operation: String
    let service: String
    let allowInteraction: Bool
    let data: Data?
}
struct VaultResponse: Encodable {
    var data: Data?
    var status: Int32 = 0
}
struct VaultRecord: Decodable {
    let id: UUID
    let origin: String
    let username: String
    let password: String
}

// The helper's signature stays unchanged when the browser is rebuilt.
func verifyBrowser() throws {
    var ownCode: SecCode?
    var staticCode: SecStaticCode?
    var ownInfo: CFDictionary?
    guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
          SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &ownInfo) == errSecSuccess,
          let certificates = (ownInfo as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let certificate = certificates.first else { throw NSError(domain: "PerchVault", code: -60001) }
    let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02x", $0) }.joined()
    var requirement: SecRequirement?
    var parent: SecCode?
    guard SecRequirementCreateWithString(
        "identifier \"dev.perch.menubar\" and certificate leaf = H\"\(fingerprint)\"" as CFString,
        [], &requirement) == errSecSuccess, let requirement,
          SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: getppid()] as CFDictionary,
                                        [], &parent) == errSecSuccess, let parent else {
        throw NSError(domain: "PerchVault", code: -60002)
    }
    let status = SecCodeCheckValidity(parent, [], requirement)
    guard status == errSecSuccess else { throw NSError(domain: "PerchVault", code: Int(status)) }
}
func validate(_ data: Data) throws {
    let records = try JSONDecoder().decode([VaultRecord].self, from: data)
    guard records.count <= 10000, Set(records.map(\.id)).count == records.count,
          records.allSatisfy({ record in
              guard let url = URLComponents(string: record.origin),
                    ["http", "https"].contains(url.scheme ?? ""), url.host?.isEmpty == false else { return false }
              return record.origin.utf8.count <= 16384 && record.username.utf8.count <= 1024 &&
                  !record.password.isEmpty && record.password.utf8.count <= 16384
          }) else { throw NSError(domain: "PerchVault", code: 2) }
}
func query(_ service: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: "saved-passwords",
     kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
}
func read(_ service: String, interactive: Bool) throws -> (OSStatus, Data?) {
    var request = query(service)
    request[kSecUseAuthenticationUI as String] = interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &value)
    let data = value as? Data
    if status == errSecSuccess {
        guard let data else { throw NSError(domain: "PerchVault", code: 2) }
        try validate(data)
    }
    return (status, data)
}
func write(_ service: String, data: Data) -> OSStatus {
    let status = SecItemUpdate(query(service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    guard status == errSecItemNotFound else { return status }
    var item = query(service)
    item[kSecValueData as String] = data
    item[kSecAttrLabel as String] = "Perch 保存的网站密码"
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil)
}
do {
    try verifyBrowser()
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 256 * 1024 * 1024 else { throw NSError(domain: "PerchVault", code: 2) }
    let request = try JSONDecoder().decode(VaultRequest.self, from: input)
    let production = request.service == "dev.perch.menubar.passwords.v2"
    let synthetic = (request.service.hasPrefix("dev.perch.synthetic-passwords.") ||
                     request.service.hasPrefix("dev.perch.synthetic-upgrade.")) && request.service.count < 128
    guard production || synthetic else { throw NSError(domain: "PerchVault", code: 2) }
    var response = VaultResponse()
    switch request.operation {
    case "load":
        var (status, data) = try read(request.service, interactive: request.allowInteraction)
        if production && status == errSecItemNotFound {
            // Preserve the legacy item, including when its old authorization has been denied.
            (status, data) = try read("dev.perch.menubar.passwords", interactive: request.allowInteraction)
            if status == errSecSuccess, let existing = data {
                status = write(request.service, data: existing)
            }
        }
        response.status = status == errSecItemNotFound ? errSecSuccess : status
        response.data = data
    case "write":
        guard let data = request.data else { throw NSError(domain: "PerchVault", code: 2) }
        try validate(data)
        response.status = write(request.service, data: data)
    case "initialize" where production:
        let (status, data) = try read(request.service, interactive: false)
        if status == errSecItemNotFound {
            response.status = write(request.service, data: Data("[]".utf8))
            response.data = Data("[]".utf8)
        } else {
            response.status = status; response.data = data
        }
    case "cleanup" where synthetic:
        response.status = SecItemDelete(query(request.service) as CFDictionary)
    default: throw NSError(domain: "PerchVault", code: 2)
    }
    FileHandle.standardOutput.write(try JSONEncoder().encode(response))
} catch {
    FileHandle.standardOutput.write(try! JSONEncoder().encode(VaultResponse(status: Int32((error as NSError).code))))
    exit(1)
}
