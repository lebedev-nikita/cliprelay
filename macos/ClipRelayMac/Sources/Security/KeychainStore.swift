// Thin wrapper around macOS Keychain Services for secure data storage and retrieval.

import Foundation
import Security

/// Abstraction over keychain storage so tests can use an in-memory store
/// instead of the real login keychain (which triggers ACL password prompts
/// for every freshly-signed test bundle).
protocol SecretStore: AnyObject {
    func data(for account: String) -> Data?
    @discardableResult
    func setData(_ data: Data, for account: String) -> Bool
}

/// In-memory SecretStore for unit tests.
final class InMemorySecretStore: SecretStore {
    private var storage: [String: Data] = [:]

    func data(for account: String) -> Data? {
        storage[account]
    }

    @discardableResult
    func setData(_ data: Data, for account: String) -> Bool {
        storage[account] = data
        return true
    }
}

/// Result of reading one keychain item, keeping "absent" apart from "unreadable"
/// (e.g. the user denied the access prompt) so callers never overwrite data they couldn't read.
enum KeychainLookup: Equatable {
    case found(Data)
    case notFound
    case failed(OSStatus)
}

/// Raw keychain items, one per account. Abstracted so tests can fake the keychain.
protocol KeychainItemStore: AnyObject {
    func lookup(_ account: String) -> KeychainLookup
    @discardableResult
    func setData(_ data: Data, for account: String) -> Bool
    @discardableResult
    func removeData(for account: String) -> Bool
}

final class KeychainStore: KeychainItemStore {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func lookup(_ account: String) -> KeychainLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    @discardableResult
    func setData(_ data: Data, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    func removeData(for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Keeps every app secret in a single keychain item, read once and cached. Ad-hoc signed
/// builds drop out of each item's access list on every update, so macOS prompts per item;
/// one item means one prompt instead of one per secret.
final class CombinedSecretStore: SecretStore {
    struct LegacyItem {
        let store: KeychainItemStore
        let account: String
    }

    static let itemAccount = "app_secrets"

    static let shared = CombinedSecretStore(
        backing: KeychainStore(service: "org.cliprelay"),
        legacyItems: [
            LegacyItem(store: KeychainStore(service: "cliprelay"), account: "paired_devices"),
            LegacyItem(store: KeychainStore(service: "org.cliprelay"), account: "telemetry_install_id"),
        ]
    )

    private let backing: KeychainItemStore
    private let legacyItems: [LegacyItem]
    private let lock = NSLock()
    private var entries: [String: Data]?
    /// False when the keychain couldn't be read this session: writes then stay in memory
    /// so they can't replace secrets that exist but weren't readable.
    private var canPersist = true

    init(backing: KeychainItemStore, legacyItems: [LegacyItem] = []) {
        self.backing = backing
        self.legacyItems = legacyItems
    }

    func data(for account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return loadedEntries()[account]
    }

    @discardableResult
    func setData(_ data: Data, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var updated = loadedEntries()
        guard updated[account] != data else { return true }
        updated[account] = data
        entries = updated
        return canPersist && save(updated)
    }

    private func loadedEntries() -> [String: Data] {
        if let entries { return entries }
        let loaded: [String: Data]
        switch backing.lookup(Self.itemAccount) {
        case .found(let blob):
            if let decoded = try? JSONDecoder().decode([String: Data].self, from: blob) {
                loaded = decoded
            } else {
                loaded = [:]
                canPersist = false
            }
        case .failed:
            loaded = [:]
            canPersist = false
        case .notFound:
            loaded = migrateLegacyItems()
        }
        entries = loaded
        return loaded
    }

    /// One-time move of the per-secret items used before the combined item existed.
    private func migrateLegacyItems() -> [String: Data] {
        var migrated: [String: Data] = [:]
        for item in legacyItems {
            switch item.store.lookup(item.account) {
            case .found(let data):
                migrated[item.account] = data
            case .notFound:
                break
            case .failed:
                canPersist = false
            }
        }
        guard canPersist, !migrated.isEmpty, save(migrated) else { return migrated }
        for item in legacyItems {
            item.store.removeData(for: item.account)
        }
        return migrated
    }

    private func save(_ entries: [String: Data]) -> Bool {
        guard let blob = try? JSONEncoder().encode(entries) else { return false }
        return backing.setData(blob, for: Self.itemAccount)
    }
}
