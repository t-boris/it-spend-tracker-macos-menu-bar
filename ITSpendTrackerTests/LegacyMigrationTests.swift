import Foundation
import Testing
@testable import ITSpendTracker

/// The app was renamed (new bundle identifier, new Keychain service). Credentials and preferences saved under the former
/// identifier move over once; the former identifier itself is never in the source.
@Suite @MainActor struct LegacyMigrationTests {
    private let legacyID = "test.legacy.\(UUID().uuidString)"
    private func keychain(_ name: String) -> KeychainStore { KeychainStore(serviceName: "test.migration.\(name).\(UUID().uuidString)") }

    @Test func withoutALegacyIdentifierNothingHappens() {
        #expect(LegacyMigration(legacyBundleID: nil) == nil)
        #expect(LegacyMigration(legacyBundleID: "") == nil)
        #expect(LegacyMigration(legacyBundleID: "  \n") == nil)
        #expect(LegacyMigration.fromBundle(Bundle(for: KeychainStoreAnchor.self)) == nil)  // the test bundle has no such key
    }

    @Test func credentialsMoveAndTheLegacyItemsAreRemoved() throws {
        let old = keychain("old"), new = keychain("new")
        let a = UUID(), b = UUID(), c = UUID()
        try old.save(["adminKey": "sk-a"], for: a)
        try old.save(["token": "t-b"], for: b)
        try new.save(["token": "already-here"], for: b)       // the current store wins
        // c has no legacy item
        let moved = try new.adopt(from: old, accounts: [a, b, c])
        #expect(moved == 2)
        #expect(try new.load(for: a) == ["adminKey": "sk-a"])
        #expect(try new.load(for: b) == ["token": "already-here"])
        #expect(try new.load(for: c) == nil)
        #expect(try old.load(for: a) == nil && (try old.load(for: b)) == nil)
        #expect(try new.adopt(from: old, accounts: [a, b, c]) == 0)   // a second run finds nothing
        try new.delete(for: a); try new.delete(for: b)
    }

    @Test func legacyKeychainServiceIsDerivedFromTheIdentifier() throws {
        let migration = try #require(LegacyMigration(legacyBundleID: " some.old.id\n"))
        #expect(migration.legacyKeychain.serviceName == "some.old.id.credentials")
    }

    @Test func preferencesAreCopiedOnlyWhenMissing() throws {
        let suite = "test.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); defaults.removePersistentDomain(forName: legacyID) }
        defaults.setPersistentDomain(["assistantBackend": "codex", "historyRange": "days7", "NSWindow Frame x": "1 2 3 4"], forName: legacyID)
        defaults.set("claude", forKey: "assistantBackend")                // already chosen in the new app
        let migration = try #require(LegacyMigration(legacyBundleID: legacyID))
        #expect(migration.migratePreferences(to: defaults) == 1)
        #expect(defaults.string(forKey: "assistantBackend") == "claude")
        #expect(defaults.string(forKey: "historyRange") == "days7")
        #expect(defaults.object(forKey: "NSWindow Frame x") == nil)       // system keys stay behind
    }
}

private final class KeychainStoreAnchor {}
