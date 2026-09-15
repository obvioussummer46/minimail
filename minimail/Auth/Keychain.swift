import Foundation
import Security

/// Verbatim architecture §2.4 (`[ios-platform §5.5]`). Generic-password items, primary key `service` + `account`.
/// All functions are synchronous and block the calling thread (Security framework); only `exists` may run on
/// main (< 5 ms, attributes only).
nonisolated enum Keychain {
    static let service = "com.minimail"

    /// `SecItemCopyMatching` with `kSecReturnAttributes: true`, `kSecMatchLimit: kSecMatchLimitOne` (no data
    /// decrypt). `errSecSuccess` → true; `errSecItemNotFound` → false; `errSecInteractionNotAllowed` → true
    /// (item present, device not yet unlocked; logged); any other status → false + `Log.auth.error`.
    static func exists(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        case errSecInteractionNotAllowed:
            Log.auth.notice("keychain exists status=\(status, privacy: .public) (locked; item present)")
            return true
        default:
            Log.auth.error("keychain exists status=\(status, privacy: .public)")
            return false
        }
    }

    /// `SecItemUpdate` (`kSecValueData`, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
    /// falling back to `SecItemAdd` on `errSecItemNotFound`. Throws `AuthError.keychain(status)` for any other status.
    static func set(_ data: Data, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attrs: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            let add = query.merging(attrs) { $1 }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecSuccess { return }
            Log.auth.error("keychain set(add) status=\(addStatus, privacy: .public)")
            throw AuthError.keychain(addStatus)
        }
        Log.auth.error("keychain set(update) status=\(status, privacy: .public)")
        throw AuthError.keychain(status)
    }

    /// `SecItemCopyMatching` with `kSecReturnData: true`. `nil` on `errSecItemNotFound`; throws
    /// `AuthError.keychain(status)` otherwise.
    static func get(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            Log.auth.error("keychain get status=\(status, privacy: .public)")
            throw AuthError.keychain(status)
        }
    }

    /// `SecItemDelete`. `errSecSuccess` and `errSecItemNotFound` both succeed; anything else throws
    /// `AuthError.keychain(status)`.
    static func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        Log.auth.error("keychain delete status=\(status, privacy: .public)")
        throw AuthError.keychain(status)
    }
}
