import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-004 / DEC-015: months before an account existed are "no data", not $0. A provider that answers without any cost
/// for them cannot tell the two apart, so coverage starts at the first month that has a cost.
@Suite struct CoverageStartTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func day(_ year: Int, _ month: Int, _ day: Int) -> Day { Day(year: year, month: month, day: day) }
    private func request(from: Day, credentials: [String: String] = [:]) -> FetchRequest {
        FetchRequest(credentials: credentials, from: from, now: now)
    }

    @Test func coverageStartsAtTheFirstMonthWithCostButNeverBeforeTheRequest() {
        let backfill = request(from: day(2025, 9, 1))
        #expect(backfill.coverageStart(for: [day(2025, 12, 15): 2, day(2026, 2, 1): 5]) == day(2025, 12, 1))
        #expect(backfill.coverageStart(for: [day(2025, 9, 10): 1]) == day(2025, 9, 1))
        // An incremental window (previous + current month) never starts earlier than it was asked for.
        let incremental = request(from: day(2026, 8, 1))
        #expect(incremental.coverageStart(for: [day(2026, 8, 20): 1]) == day(2026, 8, 1))
        #expect(incremental.coverageStart(for: [day(2026, 7, 3): 1]) == day(2026, 8, 1))
    }

    @Test func zeroEntriesAndEmptyAnswersKeepTheWholeRequestCovered() {
        let backfill = request(from: day(2025, 9, 1))
        #expect(backfill.coverageStart(for: [:]) == backfill.from)  // an idle account: its zero months are real
        #expect(backfill.coverageStart(for: [day(2025, 10, 1): 0, day(2025, 11, 1): 0]) == backfill.from)
        #expect(backfill.coverageStart(for: [day(2025, 10, 1): 0, day(2025, 12, 15): 2]) == day(2025, 12, 1))
    }

    /// From the provider answer to what the history shows: October is before the account's first cost.
    @Test func monthsBeforeTheFirstUsageShowNoDataAndLaterZeroMonthsStayZero() async throws {
        let http = StubHTTP()
        http.on("/users/octocat/settings/billing/usage", query: "year=2025", """
        {"usageItems":[{"date":"2025-12-15","product":"Actions","sku":"Actions Linux","netAmount":2}]}
        """)
        http.on("/users/octocat/settings/billing/usage", query: "year=2026", #"{"usageItems":[]}"#)
        http.on("/organizations/acme/settings/billing/usage", query: "year=2025", #"{"usageItems":[]}"#)
        http.on("/organizations/acme/settings/billing/usage", query: "year=2026", #"{"usageItems":[]}"#)
        let snapshot = try await GitHubConnector(http: http).fetch(
            request(from: day(2025, 9, 1), credentials: ["token": "t", "username": "octocat", "organization": "acme"]))
        #expect(snapshot.coveredFrom == day(2025, 12, 1))

        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: snapshot.dailyCosts,
                                   providerCoverageStart: snapshot.coveredFrom, usageIsDaily: false)
        #expect(ledger.spend(in: Month(year: 2025, month: 10)) == .noData)       // before the account had any cost
        #expect(ledger.spend(in: Month(year: 2025, month: 12)) == .value(2))     // the first month counts in full
        #expect(ledger.spend(in: Month(year: 2026, month: 3)) == .value(0))      // a later quiet month is a real zero
    }
}
