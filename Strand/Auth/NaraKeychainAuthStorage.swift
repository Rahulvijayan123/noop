import Foundation
import Security
import Auth

/// Persists the Supabase Auth session in the Keychain.
///
/// Compared with the library's default storage this pins the item to `AfterFirstUnlockThisDeviceOnly`:
/// readable by a background relaunch once the phone has been unlocked since boot, but never synced to
/// iCloud Keychain or restored onto another device from a backup. A copied session would be a copied login.
struct NaraKeychainAuthStorage: AuthLocalStorage {
    private let service: String

    init(service: String = "com.noopapp.noop.auth") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    func store(key: String, value: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery(key)
            insert.merge(attributes) { current, _ in current }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw NaraKeychainError.status(added) }
        } else if status != errSecSuccess {
            throw NaraKeychainError.status(status)
        }
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NaraKeychainError.status(status) }
        return item as? Data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NaraKeychainError.status(status) }
    }
}

enum NaraKeychainError: Error, Equatable {
    case status(OSStatus)
}

/// A session store that lives only in memory. Tests and end-to-end runs use it so no Keychain item is created
/// on the machine running them; the app never does.
final class NaraMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.lock(); items[key] = value; lock.unlock()
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    func remove(key: String) throws {
        lock.lock(); items[key] = nil; lock.unlock()
    }
}
