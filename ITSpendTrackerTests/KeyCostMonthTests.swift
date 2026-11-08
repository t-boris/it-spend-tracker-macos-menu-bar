import Foundation
import SwiftData
import Testing
@testable import ITSpendTracker

/// REQ-013: a key's stored cost belongs to the month it was fetched for. After a month change it must not be shown
/// (or summed into a tag total) as the new month's cost until the next refresh.
@Suite @MainActor struct KeyCostMonthTests {
    private let keychain = KeychainStore(serviceName: "app.itspendtracker.ITSpendTracker.tests.\(UUID().uuidString)")
    private let september = Month(year: 2026, month: 9)

    private func makeStore() throws -> SpendStore {
        SpendStore(container: try Persistence.makeContainer(inMemory: true), keychain: keychain)
    }

    @Test func storedCostIsOnlyValidForTheMonthItWasFetchedIn() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "k"])
        let snapshot = ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1),
                                         keys: [ProviderKey(externalID: "k1", name: "Bot", currentMonthCost: 7)], tokenUsage: nil)
        try store.apply(snapshot, to: service, at: Day(year: 2026, month: 9, day: 30).startDate())
        let key = try #require(service.keys.first)
        #expect(key.monthCost(in: september) == 7)
        #expect(key.monthCost(in: september.next) == nil)  // October: nothing fetched yet
        // The next refresh replaces the record and stamps the new month.
        try store.apply(snapshot, to: service, at: Day(year: 2026, month: 10, day: 1).startDate())
        #expect(try #require(service.keys.first).monthCost(in: september.next) == 7)
    }

    @Test func recordsSavedBeforeTheMonthWasStoredAreTrustedUntilRefreshed() {
        let legacy = KeyRecord(ProviderKey(externalID: "k", name: "Old", currentMonthCost: 4))
        #expect(legacy.currentMonthIndex == nil)
        #expect(legacy.monthCost(in: september) == 4)
        #expect(KeyRecord(ProviderKey(externalID: "n", name: "None")).monthCost(in: september) == nil)  // no cost at all
    }

    @Test func staleKeyCostIsUnavailableInTagTotals() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "k"])
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1),
                                          keys: [ProviderKey(externalID: "k1", name: "Bot", currentMonthCost: 7)], tokenUsage: nil),
                        to: service, at: Day(year: 2026, month: 9, day: 30).startDate())
        try store.setTags(["client"], forKey: "k1", of: service)
        func totals(in month: Month) -> [TagTotal] { TagTotal.compute([service.tagInput(in: month)]) }
        #expect(totals(in: september).first?.total == 7)
        let october = try #require(totals(in: september.next).first)
        #expect(october.total == 0 && october.hasUnavailable)  // listed as "unavailable", not last month's 7
    }
}
