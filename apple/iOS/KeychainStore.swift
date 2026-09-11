import Foundation
import Security
import ExplorerLinkCore

enum KeychainStore {
    private static let service = "com.exploreros.link.pairing"
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "glass"] }
    static func read() -> String? {
        var query = query; query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        _ = try PairingKey.data(from: key)
        var values = query
        values[kSecValueData as String] = Data(key.utf8)
        values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(values as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
            guard update == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(update)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}
