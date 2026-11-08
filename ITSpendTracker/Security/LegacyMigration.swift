import Foundation

/// One-time move of data saved under the app's former bundle identifier: the credentials in the Keychain and the
/// preferences. The former identifier is not part of the source; the build injects it (Info.plist key
/// `LegacyBundleIdentifier`, set from the git-ignored Config/Local.xcconfig). Without it nothing happens.
struct LegacyMigration {
    static let infoKey = "LegacyBundleIdentifier"
    static let doneKey = "legacyMigrationDone"

    let legacyBundleID: String

    init?(legacyBundleID: String?) {
        guard let id = legacyBundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        self.legacyBundleID = id
    }

    static func fromBundle(_ bundle: Bundle = .main) -> LegacyMigration? {
        LegacyMigration(legacyBundleID: bundle.object(forInfoDictionaryKey: infoKey) as? String)
    }

    /// The Keychain the credentials were stored in before the rename.
    var legacyKeychain: KeychainStore { KeychainStore(serviceName: "\(legacyBundleID).credentials") }

    /// Copies the preferences the current domain does not have yet; system keys stay where they are.
    @discardableResult
    func migratePreferences(to defaults: UserDefaults = .standard) -> Int {
        guard let old = defaults.persistentDomain(forName: legacyBundleID) else { return 0 }
        var copied = 0
        for (key, value) in old where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("com.apple")
            && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    /// Moves the credentials of `accounts` into `keychain`. Throws when the Keychain refuses (for example when the user
    /// denies access), so the caller can try again on the next launch.
    func migrateCredentials(of accounts: [UUID], into keychain: KeychainStore) throws -> Int {
        try keychain.adopt(from: legacyKeychain, accounts: accounts)
    }

    /// Runs the whole migration once; later launches return immediately. It is marked done only after the
    /// credentials were moved, so a refused Keychain prompt is asked again next time.
    @MainActor
    static func runIfNeeded(store: SpendStore, bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey), let migration = fromBundle(bundle) else { return }
        if (try? migration.migrateCredentials(of: store.services.map(\.id), into: store.keychain)) != nil {
            defaults.set(true, forKey: doneKey)
        }
    }
}

extension KeychainStore {
    /// Moves the credentials of `accounts` from `legacy` into this store and removes them from `legacy`. An item
    /// that already exists here is kept; a missing legacy item is skipped.
    func adopt(from legacy: KeychainStore, accounts: [UUID]) throws -> Int {
        var moved = 0
        for account in accounts {
            guard let fields = try legacy.load(for: account) else { continue }
            if try load(for: account) == nil { try save(fields, for: account) }
            try legacy.delete(for: account)
            moved += 1
        }
        return moved
    }
}
