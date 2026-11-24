import Foundation
import Security

/// Secure Keychain storage for VNC / macOS passwords, keyed by connection profile UUID.
/// Uses atomic add-or-update (`errSecDuplicateItem` -> `SecItemUpdate`) and
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
public enum KeychainStore {
    private static let service = "com.macbeam.vnc.credentials"

    @discardableResult
    public static func savePassword(_ password: String, for profileID: UUID) -> OSStatus {
        let account = profileID.uuidString
        guard !password.isEmpty, let data = password.data(using: .utf8) else {
            return deletePassword(for: profileID)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let matchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            return SecItemUpdate(matchQuery as CFDictionary, updateAttributes as CFDictionary)
        }
        return addStatus
    }

    public static func loadPassword(for profileID: UUID) -> String {
        let account = profileID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return ""
        }
        return password
    }

    @discardableResult
    public static func deletePassword(for profileID: UUID) -> OSStatus {
        let account = profileID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
