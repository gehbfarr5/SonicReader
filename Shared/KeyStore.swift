import Foundation
import Security

struct KeyStore {
    private let accessGroup: String
    init(accessGroup: String) { self.accessGroup = accessGroup }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jin.sonicreader.cartesia",
         kSecAttrAccount as String: "api-key",
         kSecAttrAccessGroup as String: accessGroup]
    }

    func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ReaderError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ReaderError.configuration("存储的密钥格式不正确。请重新输入。")
        }
        return key
    }

    func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk_car_"), !key.contains(where: { $0.isWhitespace }) else {
            throw ReaderError.configuration("请输入以 sk_car_ 开头的 Cartesia API 密钥。")
        }
        let update = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = Data(key.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ReaderError.keychain(status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ReaderError.keychain(status) }
    }
}
