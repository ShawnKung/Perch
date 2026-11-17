import Foundation
import Security
import CryptoKit
import LocalAuthentication

// Separate, cached executable: browser rebuilds must not change the Keychain reader's identity.
struct KeyRequest: Decodable { let operation: String; let service: String; let account: String; let key: String? }
struct KeyResponse: Encodable { var key: String?; var status: OSStatus = errSecSuccess }

func verifyAIParent() throws {
    var ownCode: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
    guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
          SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let certificate = certificates.first else { throw NSError(domain: "PerchAIKeys", code: -60001) }
    let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02x", $0) }.joined()
    var requirement: SecRequirement?, parent: SecCode?
    guard SecRequirementCreateWithString(
        "identifier \"dev.perch.menubar\" and certificate leaf = H\"\(fingerprint)\"" as CFString,
        [], &requirement) == errSecSuccess, let requirement,
          SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: getppid()] as CFDictionary,
                                        [], &parent) == errSecSuccess, let parent else {
        throw NSError(domain: "PerchAIKeys", code: -60002)
    }
    let status = SecCodeCheckValidity(parent, [], requirement)
    guard status == errSecSuccess else { throw NSError(domain: "PerchAIKeys", code: Int(status)) }
}

do {
    try verifyAIParent()
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 65536 else { throw NSError(domain: "PerchAIKeys", code: 2) }
    let request = try JSONDecoder().decode(KeyRequest.self, from: input)
    guard request.service == "dev.perch.menubar.ai" ||
          (request.service.hasPrefix("dev.perch.synthetic-ai.") && request.service.count < 128),
          !request.account.isEmpty, request.account.utf8.count <= 4096 else {
        throw NSError(domain: "PerchAIKeys", code: 2)
    }
    let context = LAContext(); context.interactionNotAllowed = true
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: request.service,
        kSecAttrAccount as String: request.account, kSecUseAuthenticationContext as String: context
    ]
    var response = KeyResponse()
    switch request.operation {
    case "read":
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        response.status = SecItemCopyMatching(query as CFDictionary, &item)
        if response.status == errSecSuccess {
            guard let data = item as? Data, data.count <= 16384, let key = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "PerchAIKeys", code: 2)
            }
            response.key = key
        }
    case "write":
        guard let key = request.key, !key.isEmpty, key.utf8.count <= 16384, !key.contains("\n"), !key.contains("\r") else {
            throw NSError(domain: "PerchAIKeys", code: 2)
        }
        let data = Data(key.utf8)
        response.status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if response.status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrLabel as String] = "Perch AI Key"
            response.status = SecItemAdd(query as CFDictionary, nil)
        }
    case "delete": response.status = SecItemDelete(query as CFDictionary)
    default: throw NSError(domain: "PerchAIKeys", code: 2)
    }
    if response.status == errSecItemNotFound && request.operation != "write" { response.status = errSecSuccess }
    FileHandle.standardOutput.write(try JSONEncoder().encode(response))
} catch {
    FileHandle.standardOutput.write(try! JSONEncoder().encode(KeyResponse(status: Int32((error as NSError).code))))
    exit(1)
}
