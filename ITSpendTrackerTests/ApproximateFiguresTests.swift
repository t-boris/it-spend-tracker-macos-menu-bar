import Foundation
import Testing
@testable import ITSpendTracker

private func d(_ y: Int, _ m: Int, _ day: Int) -> Day { Day(year: y, month: m, day: day) }

/// REQ-017: every figure that contains an approximate (estimated) amount is marked "≈": warnings, the daily
/// history (hover, table, averages) and the chat snapshot, not only the monthly totals.
@Suite @MainActor struct ApproximateFiguresTests {
    private func store() throws -> SpendStore {
        SpendStore(container: try Persistence.makeContainer(inMemory: true),
                   keychain: KeychainStore(serviceName: "app.itspendtracker.ITSpendTracker.tests.\(UUID().uuidString)"))
    }

    private func neonAndOpenAI(_ store: SpendStore) throws -> (neon: TrackedService, openAI: TrackedService) {
        let neon = try store.addConnectedService(name: "Neon", accountIdentifier: "", connector: .neon, definition: nil,
                                                 credentials: ["apiKey": "k"])
        try store.apply(ConnectorSnapshot(dailyCosts: [d(2026, 9, 2): 5], coveredFrom: d(2026, 8, 1), keys: nil, tokenUsage: nil),
                        to: neon, at: .now)
        let openAI = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                   credentials: ["adminKey": "k"])
        try store.apply(ConnectorSnapshot(dailyCosts: [d(2026, 9, 3): 7], coveredFrom: d(2026, 8, 1), keys: nil, tokenUsage: nil),
                        to: openAI, at: .now)
        return (neon, openAI)
    }

    @Test func formatMarksApproximateAmountsOnly() {
        #expect(Format.usd(5, approximate: true) == "≈ " + Format.usd(5))
        #expect(Format.usd(5, approximate: false) == Format.usd(5))
    }

    @Test func aDayIsApproximateWhenAnEstimatedServiceSpentOnIt() throws {
        let store = try store()
        let (neon, openAI) = try neonAndOpenAI(store)
        let today = d(2026, 9, 30)
        #expect(neon.isApproximate(on: d(2026, 9, 2), today: today))
        // Neon books usage per month, spread over the month's days (DEC-039): every day of September carries the estimate.
        #expect(neon.isApproximate(on: d(2026, 9, 5), today: today))
        #expect(!neon.isApproximate(on: d(2026, 8, 5), today: today))       // no usage in August: nothing to approximate
        #expect(!openAI.isApproximate(on: d(2026, 9, 3), today: today))     // exact provider cost
        try store.remove(neon)
        try store.remove(openAI)
    }

    @Test func dailyTotalsAndAveragesAreApproximateOnlyWhenTheyContainAnEstimate() throws {
        let store = try store()
        let (neon, openAI) = try neonAndOpenAI(store)
        let today = d(2026, 9, 30)
        let series = [neon, openAI].map { DailyHistory.Series(name: $0.name, service: $0, ledger: $0.ledger) }
        #expect(DailyHistory.Series.isApproximate(series, on: [d(2026, 9, 2)], today: today))
        #expect(!DailyHistory.Series.isApproximate(series, on: [d(2026, 8, 20)], today: today))  // August: nothing estimated
        // A 7-day window inside August has no estimate; one that reaches into September does.
        #expect(!DailyHistory.Series.isApproximate(series, on: (14...20).map { d(2026, 8, $0) }, today: today))
        #expect(DailyHistory.Series.isApproximate(series, on: [d(2026, 8, 31), d(2026, 9, 1)], today: today))
        try store.remove(neon)
        try store.remove(openAI)
    }

    @Test func chatSnapshotListsMonthsWhoseTotalContainsAnEstimate() throws {
        let store = try store()
        let (neon, openAI) = try neonAndOpenAI(store)
        let json = SpendingSnapshot.json(SpendingSnapshot.build(services: store.services, today: d(2026, 9, 30)))
        #expect(json.contains("\"total_months_containing_estimates\":[\"2026-09\"]"))  // August has no usage at all
        try store.remove(neon)
        try store.remove(openAI)
    }
}
