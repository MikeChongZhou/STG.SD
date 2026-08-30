import Foundation
import Security

public enum SecureStore {
    public static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func write(_ value: String, service: String, account: String) throws {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(key as CFDictionary)
        guard !value.isEmpty else { return }
        var add = key; add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw STGError.invalidDocument("Keychain error \(status)") }
    }
}

