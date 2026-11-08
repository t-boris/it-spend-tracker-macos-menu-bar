import Foundation
import SwiftData
import Testing
@testable import ITSpendTracker

/// REQ-017, REQ-018: tags on services, keys, breakdown items and Neon projects are stored as independent, stable
/// assignments (DEC-036) that survive refreshes and month changes.
@Suite @MainActor struct TagAssignmentTests {
    private let keychain = KeychainStore(serviceName: "app.itspendtracker.ITSpendTracker.tests.\(UUID().uuidString)")
    private let september = Month(year: 2026, month: 9)
    private let october = Month(year: 2026, month: 10)

    private func makeStore(container: ModelContainer? = nil) throws -> SpendStore {
        SpendStore(container: try container ?? Persistence.makeContainer(inMemory: true), keychain: keychain)
    }

    private func openAI(_ store: SpendStore, name: String = "OpenAI") throws -> TrackedService {
        try store.addConnectedService(name: name, accountIdentifier: "", connector: .openAI, definition: nil,
                                      credentials: ["adminKey": "k"])
    }

    private func snapshot(from month: Month, keys: [ProviderKey] = [], rows: [BreakdownRow] = []) -> ConnectorSnapshot {
        ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: month.year, month: month.month, day: 1), keys: keys,
                          tokenUsage: nil, breakdown: rows, breakdownFrom: month)
    }

    private func row(_ month: Month, _ dimension: BreakdownDimension, _ label: String, _ amount: Decimal) -> BreakdownRow {
        BreakdownRow(month: month, dimension: dimension, label: label, amount: amount)
    }

    // MARK: Targets are independent (REQ-017)

    @Test func everyTargetKindTakesItsOwnTags() throws {
        let store = try makeStore()
        let service = try openAI(store)
        let item = TagTarget.breakdownItem(dimension: .project, label: "web")
        let neon = TagTarget.usageProject(organization: "Example Org", name: "web-app")
        try store.setTags(["whole"], for: .service, displayName: "OpenAI", of: service)
        try store.setTags(["bot"], for: .key("k1"), displayName: "Bot", of: service)
        try store.setTags(["site"], for: item, displayName: "web", of: service)
        try store.setTags(["db"], for: neon, displayName: "web-app", of: service)
        #expect(service.tags(for: .service) == ["whole"])
        #expect(service.tags(forKey: "k1") == ["bot"])
        #expect(service.tags(for: item) == ["site"])
        #expect(service.tags(for: neon) == ["db"])
        // Tagging a service does not tag anything inside it, and the reverse (AC-002).
        #expect(service.tags(for: .key("k2")).isEmpty)
        #expect(service.tags(for: .breakdownItem(dimension: .lineItem, label: "web")).isEmpty)
        try store.setTags([], for: item, displayName: "web", of: service)
        #expect(service.tags(for: .service) == ["whole"])
        #expect(service.tagAssignments.count == 3)
    }

    @Test func tagInputIsTrimmedDeduplicatedAndEmptyEntriesAreIgnored() throws {
        let store = try makeStore()
        let service = try openAI(store)
        try store.setTags(["  client X ", "", "   ", "Client x", "bot"], for: .service, displayName: "OpenAI", of: service)
        #expect(service.tags(for: .service) == ["client X", "bot"])
        try store.setTags(["", " "], for: .service, displayName: "OpenAI", of: service)
        #expect(service.tags(for: .service).isEmpty)
        #expect(try store.context.fetchCount(FetchDescriptor<TagAssignmentRecord>()) == 0)
    }

    @Test func suggestionsSpanEveryTargetTypeAndMergeSpellingsThatDifferInCase() throws {
        let store = try makeStore()
        let first = try openAI(store, name: "A")
        let second = try openAI(store, name: "B")
        try store.setTags(["Client X"], for: .service, displayName: "A", of: first)
        try store.setTags(["client x", "bot"], for: .key("k1"), displayName: "Bot", of: second)
        try store.setTags(["site"], for: .breakdownItem(dimension: .project, label: "web"), displayName: "web", of: second)
        #expect(store.allTags == ["bot", "Client X", "site"])
    }

    // MARK: Stable identity (REQ-018)

    @Test func assignmentsSurviveRefreshesAndMonthChanges() throws {
        let store = try makeStore()
        let service = try openAI(store)
        let item = TagTarget.breakdownItem(dimension: .project, label: "web")
        try store.apply(snapshot(from: september, keys: [ProviderKey(externalID: "k1", name: "Bot", currentMonthCost: 7)],
                                 rows: [row(september, .project, "web", 5)]), to: service, at: .now)
        try store.setTags(["site"], for: item, displayName: "web", of: service)
        try store.setTags(["bot"], for: .key("k1"), displayName: "Bot", of: service)
        // The next month replaces the key records and breakdown rows; the assignments are separate records.
        try store.apply(snapshot(from: october, keys: [ProviderKey(externalID: "k1", name: "Bot", currentMonthCost: 1)],
                                 rows: [row(october, .project, "web", 2)]), to: service, at: .now)
        #expect(service.tags(for: item) == ["site"])
        #expect(service.tags(forKey: "k1") == ["bot"])
    }

    @Test func sameNamesInDifferentServicesOrDimensionsDoNotShareAssignments() throws {
        let store = try makeStore()
        let first = try openAI(store, name: "First")
        let second = try openAI(store, name: "Second")
        try store.setTags(["a"], for: .key("k1"), displayName: "Bot", of: first)
        try store.setTags(["b"], for: .breakdownItem(dimension: .project, label: "web"), displayName: "web", of: first)
        #expect(second.tags(forKey: "k1").isEmpty)
        #expect(second.tags(for: .breakdownItem(dimension: .project, label: "web")).isEmpty)
        // Same label in another dimension is another target.
        #expect(first.tags(for: .breakdownItem(dimension: .lineItem, label: "web")).isEmpty)
        // Same project name in another organization is another target.
        try store.setTags(["c"], for: .usageProject(organization: "Org A", name: "app"), displayName: "app", of: first)
        #expect(first.tags(for: .usageProject(organization: "Org B", name: "app")).isEmpty)
    }

    @Test func missingTargetKeepsItsAssignmentAndItsName() throws {
        let store = try makeStore()
        let service = try openAI(store)
        try store.apply(snapshot(from: september, keys: [ProviderKey(externalID: "k1", name: "Bot", currentMonthCost: 7)]),
                        to: service, at: .now)
        try store.setTags(["bot"], forKey: "k1", of: service)
        try store.apply(snapshot(from: september, keys: []), to: service, at: .now) // the provider no longer lists the key
        #expect(service.keys.isEmpty)
        #expect(service.tags(forKey: "k1") == ["bot"])
        #expect(service.tagAssignments.first?.displayName == "Bot")
    }

    @Test func renamedLabelIsANewTargetAndTheOldAssignmentStays() throws {
        let store = try makeStore()
        let service = try openAI(store)
        try store.apply(snapshot(from: september, rows: [row(september, .lineItem, "gpt-5", 5)]), to: service, at: .now)
        try store.setTags(["llm"], for: .breakdownItem(dimension: .lineItem, label: "gpt-5"), displayName: "gpt-5", of: service)
        try store.apply(snapshot(from: september, rows: [row(september, .lineItem, "gpt-5.1", 5)]), to: service, at: .now)
        #expect(service.tags(for: .breakdownItem(dimension: .lineItem, label: "gpt-5.1")).isEmpty)
        #expect(service.tags(for: .breakdownItem(dimension: .lineItem, label: "gpt-5")) == ["llm"])
    }

    @Test func removingAServiceDeletesItsAssignments() throws {
        let store = try makeStore()
        let service = try openAI(store)
        try store.setTags(["a"], for: .service, displayName: "OpenAI", of: service)
        try store.setTags(["b"], for: .breakdownItem(dimension: .project, label: "web"), displayName: "web", of: service)
        let other = try openAI(store, name: "Other")
        try store.setTags(["c"], for: .service, displayName: "Other", of: other)
        try store.remove(service)
        #expect(try store.context.fetchCount(FetchDescriptor<TagAssignmentRecord>()) == 1)
        #expect(other.tags(for: .service) == ["c"])
    }

    // MARK: Migration of the first release's key tags (DEC-036)

    @Test func legacyKeyTagsMigrateWithoutLoss() throws {
        let store = try makeStore()
        let service = try openAI(store)
        try store.apply(snapshot(from: september, keys: [ProviderKey(externalID: "k1", name: "Bot", currentMonthCost: 7)]),
                        to: service, at: .now)
        service.keyTags.append(KeyTagRecord(keyExternalID: "k1", tags: ["client X", "bot"]))
        service.keyTags.append(KeyTagRecord(keyExternalID: "gone", tags: ["old"]))
        try store.save()

        try store.migrateLegacyKeyTags()

        #expect(service.tags(forKey: "k1") == ["client X", "bot"])
        #expect(service.tags(forKey: "gone") == ["old"])
        #expect(service.tagAssignments.first { $0.reference == "k1" }?.displayName == "Bot")
        #expect(service.tagAssignments.first { $0.reference == "gone" }?.displayName == "gone")
        #expect(try store.context.fetchCount(FetchDescriptor<KeyTagRecord>()) == 0)
        // Running it again changes nothing.
        try store.migrateLegacyKeyTags()
        #expect(service.tagAssignments.count == 2)
        #expect(store.allTags == ["bot", "client X", "old"])
    }

    @Test func migrationMergesWithAnAssignmentThatAlreadyExists() throws {
        let store = try makeStore()
        let service = try openAI(store)
        try store.setTags(["new"], forKey: "k1", of: service)
        service.keyTags.append(KeyTagRecord(keyExternalID: "k1", tags: ["old", "New"]))
        try store.save()
        try store.migrateLegacyKeyTags()
        #expect(service.tags(forKey: "k1") == ["new", "old"])
        #expect(service.tagAssignments.count == 1)
    }

    @Test func aStoreConvertsLegacyTagsWhenItOpens() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let first = try makeStore(container: container)
        let service = try openAI(first)
        service.keyTags.append(KeyTagRecord(keyExternalID: "k1", tags: ["bots"]))
        try first.save()

        let reopened = try makeStore(container: container)

        #expect(reopened.services.first?.tags(forKey: "k1") == ["bots"])
        #expect(try reopened.context.fetchCount(FetchDescriptor<KeyTagRecord>()) == 0)
    }
}
