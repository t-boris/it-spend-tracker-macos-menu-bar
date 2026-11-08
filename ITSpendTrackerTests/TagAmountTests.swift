import Foundation
import SwiftData
import Testing
@testable import ITSpendTracker

/// REQ-020: what each tagged target costs this month. Figures come from the current month's data only; a target the
/// provider no longer lists has no cost, and an earlier month's figure is never reused (REQ-018).
@Suite @MainActor struct TagAmountTests {
    private let keychain = KeychainStore(serviceName: "app.itspendtracker.ITSpendTracker.tests.\(UUID().uuidString)")
    private let august = Month(year: 2026, month: 8)
    private let september = Month(year: 2026, month: 9)
    private let october = Month(year: 2026, month: 10)

    private func makeStore() throws -> SpendStore {
        SpendStore(container: try Persistence.makeContainer(inMemory: true), keychain: keychain)
    }

    private func state(_ target: TagTarget, _ name: String, _ cost: Decimal?, estimate: Bool = false) -> TagTargetState {
        TagTargetState(target: target, name: name, cost: cost, costIsEstimate: estimate)
    }

    private func assignment(_ target: TagTarget, _ tags: [String], name: String = "stored") -> TagAssignment {
        TagAssignment(target: target, displayName: name, tags: tags)
    }

    private func input(_ name: String = "A", spend: Decimal? = nil, estimate: Bool = false, present: [TagTargetState] = [],
                       assignments: [TagAssignment]) -> TagServiceInput {
        TagServiceInput(serviceName: name, spend: spend, spendIsEstimate: estimate, present: present, assignments: assignments)
    }

    // MARK: Resolving a target against the month's data

    @Test func keysOfOneServiceAddUpLikeTheFirstRelease() {
        let totals = TagTotal.compute([input(spend: 50, present: [state(.key("k1"), "Bot", 7), state(.key("k2"), "Scripts", 3)],
                                             assignments: [assignment(.key("k1"), ["client"]), assignment(.key("k2"), ["Client"])])])
        let tag = totals.first
        #expect(totals.count == 1 && tag?.tag == "client")
        #expect(tag?.total == 10)
        #expect(tag?.members.map(\.name) == ["Bot", "Scripts"])
        #expect(tag?.members.allSatisfy { $0.isPresent && $0.isCounted } == true)
    }

    @Test func aMissingTargetKeepsItsStoredNameAndHasNoCost() throws {
        let totals = TagTotal.compute([input(present: [state(.key("other"), "Other", 4)],
                                             assignments: [assignment(.key("gone"), ["client"], name: "Old bot")])])
        let member = try #require(totals.first?.members.first)
        #expect(member.name == "Old bot")
        #expect(!member.isPresent && member.cost == nil && !member.isCounted)
        #expect(totals.first?.total == 0 && totals.first?.hasUnavailable == true)
    }

    @Test func aCostTheProviderDoesNotReportIsListedButNotAdded() {
        let totals = TagTotal.compute([input(present: [state(.key("k1"), "Bot", 7), state(.key("k2"), "Scripts", nil)],
                                             assignments: [assignment(.key("k1"), ["client"]), assignment(.key("k2"), ["client"])])])
        #expect(totals.first?.total == 7)
        #expect(totals.first?.hasUnavailable == true)
        #expect(totals.first?.members.first { $0.name == "Scripts" }?.isPresent == true)
    }

    @Test func estimatesKeepTheApproximateMarkerOnlyWhenTheyAreAdded() {
        let estimated = TagTotal.compute([input(present: [state(.key("k1"), "Bot", 5, estimate: true)],
                                                assignments: [assignment(.key("k1"), ["a"])])])
        #expect(estimated.first?.isApproximate == true)
        let exact = TagTotal.compute([input(present: [state(.key("k1"), "Bot", 5)], assignments: [assignment(.key("k1"), ["a"])])])
        #expect(exact.first?.isApproximate == false)
        // An estimate without a cost adds nothing, so the total is not approximate.
        let unknown = TagTotal.compute([input(present: [state(.key("k1"), "Bot", nil, estimate: true)],
                                              assignments: [assignment(.key("k1"), ["a"])])])
        #expect(unknown.first?.isApproximate == false)
    }

    @Test func tagsAreGroupedCaseInsensitivelyAndSortedByTotalThenName() {
        let totals = TagTotal.compute([input(present: [state(.key("k1"), "A", 9), state(.key("k2"), "B", 2), state(.key("k3"), "C", 2)],
                                             assignments: [assignment(.key("k1"), ["Big"]), assignment(.key("k2"), ["small"]),
                                                           assignment(.key("k3"), ["alpha", "BIG"])])])
        #expect(totals.map(\.tag) == ["Big", "alpha", "small"])
        #expect(totals.map(\.total) == [11, 2, 2])
    }

    // MARK: Resolving from stored data

    @Test func aTaggedServiceUsesItsMonthlySpendWhetherOrNotItIsInTheMainTotal() throws {
        let store = try makeStore()
        let service = try store.addManualService(name: "ChatGPT Plus")
        try store.addSubscription(service, name: "Plus", period: .monthly, start: Day(year: 2026, month: 1, day: 15), end: nil, amount: 20)
        try store.setTags(["tools"], for: .service, displayName: service.name, of: service)
        try store.setIncludedInTotal(service, false)
        let totals = TagTotal.compute([service.tagInput(in: september)])
        #expect(totals.first?.total == 20)
        #expect(totals.first?.members.first?.target == .service)
        #expect(service.ledger.spend(in: september) == .value(20)) // tagging does not change the service's own spend
    }

    @Test func aServiceWithoutDataIsUnavailableNotZero() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "k"])
        try store.setTags(["ai"], for: .service, displayName: service.name, of: service)
        let member = try #require(TagTotal.compute([service.tagInput(in: september)]).first?.members.first)
        #expect(member.cost == nil && member.isPresent)
    }

    @Test func breakdownItemsUseTheirOwnMonthOnly() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "k"])
        let rows = [BreakdownRow(month: september, dimension: .lineItem, label: "gpt-5", amount: 5),
                    BreakdownRow(month: september, dimension: .project, label: "web", amount: 4),
                    BreakdownRow(month: october, dimension: .lineItem, label: "gpt-6", amount: 3)]
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1), keys: nil, tokenUsage: nil,
                                          breakdown: rows, breakdownFrom: september), to: service, at: .now)
        let item = TagTarget.breakdownItem(dimension: .lineItem, label: "gpt-5")
        try store.setTags(["llm"], for: item, displayName: "gpt-5", of: service)

        let inSeptember = try #require(TagTotal.compute([service.tagInput(in: september)]).first?.members.first)
        #expect(inSeptember.cost == 5 && inSeptember.isPresent)
        // In October "gpt-5" has no row: unavailable, September's 5 is not reused. The dimension must match too.
        let inOctober = try #require(TagTotal.compute([service.tagInput(in: october)]).first?.members.first)
        #expect(inOctober.cost == nil && !inOctober.isPresent && inOctober.name == "gpt-5")
        try store.setTags(["web"], for: .breakdownItem(dimension: .lineItem, label: "web"), displayName: "web", of: service)
        let wrongDimension = TagTotal.compute([service.tagInput(in: september)]).first { $0.tag == "web" }
        #expect(wrongDimension?.members.first?.isPresent == false) // "web" exists as a project row, not as a line item
    }

    @Test func breakdownBeforeTheCoverageStartIsUnavailable() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "k"])
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1), keys: nil, tokenUsage: nil,
                                          breakdown: [BreakdownRow(month: september, dimension: .project, label: "web", amount: 4)],
                                          breakdownFrom: september), to: service, at: .now)
        try store.setTags(["site"], for: .breakdownItem(dimension: .project, label: "web"), displayName: "web", of: service)
        let member = try #require(TagTotal.compute([service.tagInput(in: august)]).first?.members.first)
        #expect(member.cost == nil && !member.isPresent)
    }

    @Test func aKeyFetchedInAnotherMonthHasNoCostThisMonth() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "k"])
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1),
                                          keys: [ProviderKey(externalID: "k1", name: "Bot", currentMonthCost: 7)], tokenUsage: nil),
                        to: service, at: Day(year: 2026, month: 9, day: 30).startDate())
        try store.setTags(["client"], forKey: "k1", of: service)
        #expect(TagTotal.compute([service.tagInput(in: september)]).first?.total == 7)
        let october = try #require(TagTotal.compute([service.tagInput(in: october)]).first)
        #expect(october.total == 0 && october.hasUnavailable && october.members.first?.isPresent == true)
    }

    @Test func neonProjectsUseTheApproximateCostOfTheirMetricsAndAreMarkedApproximate() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "Neon", accountIdentifier: "", connector: .neon, definition: nil,
                                                    credentials: ["apiKey": "k"])
        let rows = [UsageMetricRow(month: september, project: "web-app", metric: "compute_unit_seconds", value: 12, plan: "launch",
                                   organization: "Example Org"),
                    UsageMetricRow(month: september, project: "web-app", metric: "root_branch_bytes_month", value: 3, plan: "launch",
                                   organization: "Example Org"),
                    UsageMetricRow(month: september, project: "api", metric: "compute_unit_seconds", value: 5, plan: nil,
                                   organization: "Example Org")]
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1), keys: nil, tokenUsage: nil,
                                          usageMetrics: rows, usageMetricsFrom: september), to: service, at: .now)
        let web = TagTarget.usageProject(organization: "Example Org", name: "web-app")
        let api = TagTarget.usageProject(organization: "Example Org", name: "api")
        try store.setTags(["db"], for: web, displayName: "web-app", of: service)
        try store.setTags(["db"], for: api, displayName: "api", of: service)

        let expected = try #require(NeonPricing.cost(metric: "compute_unit_seconds", value: 12, plan: "launch"))
            + #require(NeonPricing.cost(metric: "root_branch_bytes_month", value: 3, plan: "launch"))
        let tag = try #require(TagTotal.compute([service.tagInput(in: september)]).first)
        #expect(tag.members.first { $0.target == web }?.cost == expected)
        #expect(tag.members.first { $0.target == web }?.costIsEstimate == true)
        #expect(tag.members.first { $0.target == api }?.cost == nil) // the plan's rates are unknown
        #expect(tag.total == expected && tag.isApproximate)
        // A project is its own target: the same name in another organization is not tagged.
        #expect(service.tags(for: .usageProject(organization: "Other Org", name: "web-app")).isEmpty)
    }
}
