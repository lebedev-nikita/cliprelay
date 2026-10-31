import Security
import XCTest
@testable import ClipRelay

private final class FakeKeychain: KeychainItemStore {
    var items: [String: Data] = [:]
    var failingAccounts: Set<String> = []
    private(set) var lookups: [String] = []
    private(set) var writes: [String] = []

    func lookup(_ account: String) -> KeychainLookup {
        lookups.append(account)
        if failingAccounts.contains(account) { return .failed(errSecAuthFailed) }
        return items[account].map(KeychainLookup.found) ?? .notFound
    }

    func setData(_ data: Data, for account: String) -> Bool {
        writes.append(account)
        items[account] = data
        return true
    }

    func removeData(for account: String) -> Bool {
        items[account] = nil
        return true
    }
}

final class CombinedSecretStoreTests: XCTestCase {
    private let devices = Data("devices".utf8)
    private let installId = Data("install-id".utf8)

    func testMigratesLegacyItemsIntoOneItemAndDeletesThem() {
        let legacyPairing = FakeKeychain()
        legacyPairing.items["paired_devices"] = devices
        let backing = FakeKeychain()
        backing.items["telemetry_install_id"] = installId

        let store = CombinedSecretStore(backing: backing, legacyItems: [
            .init(store: legacyPairing, account: "paired_devices"),
            .init(store: backing, account: "telemetry_install_id"),
        ])

        XCTAssertEqual(store.data(for: "paired_devices"), devices)
        XCTAssertEqual(store.data(for: "telemetry_install_id"), installId)
        XCTAssertEqual(Array(backing.items.keys), [CombinedSecretStore.itemAccount])
        XCTAssertTrue(legacyPairing.items.isEmpty)

        let reopened = CombinedSecretStore(backing: backing)
        XCTAssertEqual(reopened.data(for: "paired_devices"), devices)
        XCTAssertEqual(reopened.data(for: "telemetry_install_id"), installId)
    }

    func testReadsKeychainOnceAndSkipsUnchangedWrites() {
        let backing = FakeKeychain()
        let store = CombinedSecretStore(backing: backing)
        XCTAssertTrue(store.setData(devices, for: "paired_devices"))
        XCTAssertTrue(store.setData(devices, for: "paired_devices"))
        _ = store.data(for: "paired_devices")
        _ = store.data(for: "telemetry_install_id")

        XCTAssertEqual(backing.lookups, [CombinedSecretStore.itemAccount])
        XCTAssertEqual(backing.writes, [CombinedSecretStore.itemAccount])
    }

    func testUnreadableItemIsNeverOverwritten() {
        let backing = FakeKeychain()
        let existing = Data("existing".utf8)
        backing.items[CombinedSecretStore.itemAccount] = existing
        backing.failingAccounts = [CombinedSecretStore.itemAccount]
        let store = CombinedSecretStore(backing: backing)

        XCTAssertNil(store.data(for: "paired_devices"))
        XCTAssertFalse(store.setData(devices, for: "paired_devices"))
        XCTAssertEqual(store.data(for: "paired_devices"), devices)
        XCTAssertEqual(backing.items[CombinedSecretStore.itemAccount], existing)
        XCTAssertTrue(backing.writes.isEmpty)
    }

    func testUnreadableLegacyItemIsKept() {
        let legacy = FakeKeychain()
        legacy.items["paired_devices"] = devices
        legacy.failingAccounts = ["paired_devices"]
        let backing = FakeKeychain()
        let store = CombinedSecretStore(backing: backing, legacyItems: [
            .init(store: legacy, account: "paired_devices"),
        ])

        XCTAssertNil(store.data(for: "paired_devices"))
        XCTAssertEqual(legacy.items["paired_devices"], devices)
        XCTAssertTrue(backing.writes.isEmpty)
    }
}
