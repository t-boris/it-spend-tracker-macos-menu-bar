import Foundation
import Testing
@testable import ITSpendTracker

private func d(_ year: Int, _ month: Int, _ day: Int) -> Day { Day(year: year, month: month, day: day) }
private func m(_ year: Int, _ month: Int) -> Month { Month(year: year, month: month) }

@Suite struct CalendarTests {
    @Test func monthArithmeticWrapsYears() {
        #expect(m(2026, 1).previous == m(2025, 12))
        #expect(m(2026, 12).next == m(2027, 1))
        #expect(m(2026, 9).adding(months: -12) == m(2025, 9))
        #expect(m(2026, 9).adding(months: -21) == m(2024, 12))
        #expect(m(2025, 11).through(m(2026, 2)).count == 4)
    }

    @Test func dayCountsAndClamping() {
        #expect(m(2024, 2).dayCount == 29)
        #expect(m(2026, 2).dayCount == 28)
        #expect(d(2026, 1, 31).adding(months: 1) == d(2026, 2, 28))
        #expect(d(2026, 2, 28).nextDay == d(2026, 3, 1))
        #expect(Day(key: 20260930) == d(2026, 9, 30))
        #expect(Day(isoPrefix: "2026-09-01T00:00:00Z") == d(2026, 9, 1))
    }
}

@Suite struct SubscriptionTests {
    @Test func monthlyChargeFallsInEachMonthUntilEnd() {
        let plan = SubscriptionPlan(period: .monthly, start: d(2026, 1, 31), end: d(2026, 4, 15),
                                    prices: [.init(effectiveFrom: d(2026, 1, 31), amount: 20)])
        let charges = plan.charges(from: d(2025, 1, 1), through: d(2026, 12, 31))
        #expect(charges.map(\.day) == [d(2026, 1, 31), d(2026, 2, 28), d(2026, 3, 31)])
    }

    @Test func yearlyChargeCountsInFullInRenewalMonth() {
        let plan = SubscriptionPlan(period: .yearly, start: d(2025, 3, 10), end: nil,
                                    prices: [.init(effectiveFrom: d(2025, 3, 10), amount: 120)])
        let ledger = ServiceLedger(isConnected: false, subscriptions: [plan])
        #expect(ledger.spend(in: m(2026, 3)) == .value(120))
        #expect(ledger.spend(in: m(2026, 4)) == .value(0))
    }

    @Test func priceChangeAppliesOnlyFromItsDate() {
        let plan = SubscriptionPlan(period: .monthly, start: d(2026, 1, 5), end: nil, prices: [
            .init(effectiveFrom: d(2026, 1, 5), amount: 20),
            .init(effectiveFrom: d(2026, 3, 1), amount: 25),
        ])
        let ledger = ServiceLedger(isConnected: false, subscriptions: [plan])
        #expect(ledger.spend(in: m(2026, 2)) == .value(20))
        #expect(ledger.spend(in: m(2026, 3)) == .value(25))
        #expect(ledger.spend(in: m(2025, 12)) == .value(0))
    }
}

@Suite struct SubscriptionOnConnectedServiceTests {
    let plan = SubscriptionPlan(name: "ChatGPT Pro", period: .monthly, start: d(2025, 12, 3), end: nil,
                                prices: [.init(effectiveFrom: d(2025, 12, 3), amount: 100)])

    @Test func usagePlusSubscription() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: [d(2026, 9, 2): 7.25],
                                   providerCoverageStart: d(2025, 9, 1), subscriptions: [plan])
        #expect(ledger.spend(in: m(2026, 9)) == .value(107.25))
        #expect(ledger.usage(in: m(2026, 9)) == .value(7.25))
        #expect(ledger.subscriptionTotal(in: m(2026, 9)) == 100)
        #expect(ledger.spend(in: m(2025, 11)) == .value(0))
    }

    @Test func subscriptionBeforeCoverageStillCounts() {
        let ledger = ServiceLedger(isConnected: true, providerCoverageStart: d(2026, 9, 1), subscriptions: [plan])
        #expect(ledger.spend(in: m(2026, 1)) == .value(100))
        #expect(ledger.usage(in: m(2026, 1)) == .noData)
    }

    @Test func nextPaymentAndPaymentList() {
        #expect(plan.nextCharge(onOrAfter: d(2026, 9, 30))?.day == d(2026, 10, 3))
        #expect(plan.nextCharge(after: d(2026, 10, 3))?.day == d(2026, 11, 3))
        #expect(plan.price(on: d(2026, 9, 30)) == 100)
        let ledger = ServiceLedger(isConnected: true, subscriptions: [plan], creditPurchases: [(d(2026, 9, 10), 50)])
        let payments = ledger.payments(from: d(2026, 8, 1), through: d(2026, 9, 30))
        #expect(payments.map(\.day) == [d(2026, 8, 3), d(2026, 9, 3), d(2026, 9, 10)])
        #expect(payments.first?.label == "ChatGPT Pro")
        #expect(ledger.countedPurchases(in: m(2026, 9)) == 0)
    }

    @Test func endedSubscriptionHasNoNextPayment() {
        let ended = SubscriptionPlan(name: "x", period: .monthly, start: d(2026, 1, 1), end: d(2026, 5, 1),
                                     prices: [.init(effectiveFrom: d(2026, 1, 1), amount: 5)])
        #expect(ended.nextCharge(onOrAfter: d(2026, 9, 1)) == nil)
    }
}

@Suite struct LedgerTests {
    let costs: [Day: Decimal] = [d(2026, 8, 3): 10, d(2026, 9, 2): 4.5, d(2026, 9, 20): 1.25]

    @Test func payAfterUseCountsProviderCostsAndMarksMissingMonths() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: costs, providerCoverageStart: d(2026, 8, 1))
        #expect(ledger.spend(in: m(2026, 9)) == .value(5.75))
        #expect(ledger.spend(in: m(2026, 8)) == .value(10))
        #expect(ledger.spend(in: m(2026, 7)) == .noData)
    }

    @Test func zeroSpendIsDistinctFromNoData() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: [:], providerCoverageStart: d(2026, 1, 1))
        #expect(ledger.spend(in: m(2026, 5)) == .value(0))
        #expect(ledger.spend(in: m(2025, 12)) == .noData)
    }

    @Test func creditPurchasesOnConnectedServiceAreInformational() {
        // DEC-023: usage cost is the spend; a top-up is not added on top.
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: costs, providerCoverageStart: d(2026, 8, 1),
                                   creditPurchases: [(d(2026, 9, 1), 100)])
        #expect(ledger.spend(in: m(2026, 9)) == .value(5.75))
        #expect(ledger.totalPurchased == 100)
    }

    @Test func creditPurchasesOnManualServiceAreSpend() {
        let ledger = ServiceLedger(isConnected: false, creditPurchases: [(d(2026, 9, 1), 25)])
        #expect(ledger.spend(in: m(2026, 9)) == .value(25))
        #expect(ledger.spend(in: m(2026, 8)) == .value(0))
    }

    @Test func remainingBalanceEstimate() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: costs, providerCoverageStart: d(2026, 8, 1),
                                   creditPurchases: [(d(2026, 9, 1), 50), (d(2026, 8, 1), 999)],
                                   balanceSnapshot: (d(2026, 8, 31), 20))
        // 20 + 50 (after snapshot) − (4.5 + 1.25) consumed after the snapshot.
        #expect(ledger.remainingBalance(today: d(2026, 9, 30)) == .estimate(64.25))
    }

    @Test func remainingWithoutSnapshotIsNoData() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: costs, providerCoverageStart: d(2026, 8, 1))
        #expect(ledger.remainingBalance(today: d(2026, 9, 30)) == .noData)
    }

    @Test func remainingForManualServiceIsSnapshotCarriedForward() {
        let ledger = ServiceLedger(isConnected: false, creditPurchases: [(d(2026, 9, 10), 10)],
                                   balanceSnapshot: (d(2026, 9, 1), 5))
        #expect(ledger.remainingBalance(today: d(2026, 9, 30)) == .asOfSnapshot(15, snapshotDay: d(2026, 9, 1)))
    }

    @Test func amountAdditionKeepsNoDataOnlyWhenAllMissing() {
        #expect(Amount.noData + .noData == .noData)
        #expect(Amount.noData + .value(3) == .value(3))
        #expect(Amount.value(2) + .value(3) == .value(5))
    }
}

@Suite struct WarningTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func expiryWindowIsFourteenDays() {
        #expect(WarningRules.isExpiringSoon(expiresAt: now.addingTimeInterval(13 * 86_400), now: now))
        #expect(WarningRules.isExpiringSoon(expiresAt: now.addingTimeInterval(14 * 86_400), now: now))
        #expect(!WarningRules.isExpiringSoon(expiresAt: now.addingTimeInterval(15 * 86_400), now: now))
        #expect(!WarningRules.isExpiringSoon(expiresAt: now.addingTimeInterval(-60), now: now))
        #expect(!WarningRules.isExpiringSoon(expiresAt: nil, now: now))
    }

    private func ledger(_ costs: [Day: Decimal]) -> ServiceLedger {
        ServiceLedger(isConnected: true, providerDailyCosts: costs,
                      providerCoverageStart: d(2026, 1, 1))
    }

    @Test func comparesSameNumberOfDays() {
        // Previous month total is large, but only days 1–10 count.
        let ledger = ledger([d(2026, 8, 5): 10, d(2026, 8, 25): 500, d(2026, 9, 3): 20])
        let increase = WarningRules.spendIncrease(ledger: ledger, today: d(2026, 9, 10))
        #expect(increase == .init(monthToDate: 20, previousSamePeriod: 10))
    }

    @Test func requiresTwentyPercentAndFiveDollars() {
        #expect(WarningRules.spendIncrease(ledger: ledger([d(2026, 8, 1): 1, d(2026, 9, 1): 4]), today: d(2026, 9, 10)) == nil)
        #expect(WarningRules.spendIncrease(ledger: ledger([d(2026, 8, 1): 100, d(2026, 9, 1): 119]), today: d(2026, 9, 10)) == nil)
        #expect(WarningRules.spendIncrease(ledger: ledger([d(2026, 8, 1): 100, d(2026, 9, 1): 121]), today: d(2026, 9, 10)) != nil)
    }

    @Test func noWarningWithoutPreviousData() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: [d(2026, 9, 1): 50], providerCoverageStart: d(2026, 9, 1))
        #expect(WarningRules.spendIncrease(ledger: ledger, today: d(2026, 9, 10)) == nil)
    }

    /// REQ-008: usage booked once per month (Neon, GitHub) is prorated by day, not compared whole against a partial month.
    private func monthlyBooked(_ costs: [Day: Decimal]) -> ServiceLedger {
        ServiceLedger(isConnected: true, providerDailyCosts: costs, providerCoverageStart: d(2026, 1, 1), usageIsDaily: false)
    }

    @Test func monthlyBookedUsageIsProratedByDay() {
        // August 310 over 31 days = 10/day; 10 days = 100. September so far 150 (15/day): a real rise.
        // Counting August whole (310) against 150 would never warn.
        let ledger = monthlyBooked([d(2026, 8, 1): 310, d(2026, 9, 1): 150])
        #expect(WarningRules.spendIncrease(ledger: ledger, today: d(2026, 9, 10)) == .init(monthToDate: 150, previousSamePeriod: 100))
    }

    @Test func monthlyBookedUsageAtTheSamePaceDoesNotWarn() {
        let ledger = monthlyBooked([d(2026, 8, 1): 310, d(2026, 9, 1): 100])  // 10/day in both months
        #expect(WarningRules.spendIncrease(ledger: ledger, today: d(2026, 9, 10)) == nil)
    }

    @Test func monthlyBookedUsageComparesWholePreviousMonthOnItsLastDay() {
        // March 31 compares against all of February: 280 over 28 days = 10/day; March 465 over 31 days = 15/day.
        let ledger = monthlyBooked([d(2026, 2, 1): 280, d(2026, 3, 1): 465])
        #expect(WarningRules.spendIncrease(ledger: ledger, today: d(2026, 3, 31)) == .init(monthToDate: 465, previousSamePeriod: 280))
    }

    @Test func clampsToShorterPreviousMonth() {
        // March 31 compares against all of February.
        let ledger = ledger([d(2026, 2, 28): 10, d(2026, 3, 31): 30])
        #expect(WarningRules.spendIncrease(ledger: ledger, today: d(2026, 3, 31)) == .init(monthToDate: 30, previousSamePeriod: 10))
    }
}

@Suite struct RefreshPolicyTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func staleAfterFourHours() {
        #expect(RefreshPolicy.isStale(lastSuccess: nil, now: now))
        #expect(!RefreshPolicy.isStale(lastSuccess: now.addingTimeInterval(-3 * 3600), now: now))
        #expect(RefreshPolicy.isStale(lastSuccess: now.addingTimeInterval(-4 * 3600 - 1), now: now))
    }

    @Test func firstFetchBackfillsTwelveMonths() {
        #expect(RefreshPolicy.fetchStart(hasHistory: false, today: d(2026, 9, 30)) == d(2025, 9, 1))
        #expect(RefreshPolicy.fetchStart(hasHistory: true, today: d(2026, 9, 30)) == d(2026, 8, 1))
    }
}

@Suite struct TagTotalTests {
    @Test func groupsCaseInsensitivelyAndSkipsUnavailableCosts() {
        let totals = TagTotal.compute([
            .init(serviceName: "OpenAI", keyName: "bot", cost: 4, tags: ["Client X"]),
            .init(serviceName: "Anthropic", keyName: "bot", cost: nil, tags: ["client x", "bots"]),
            .init(serviceName: "OpenAI", keyName: "cron", cost: 1, tags: ["bots"]),
        ])
        #expect(totals.map(\.tag) == ["Client X", "bots"])
        #expect(totals[0].total == 4)
        #expect(totals[0].members.count == 2)
        #expect(totals[0].hasUnavailable)
        #expect(totals[1].total == 1)
    }
}

@Suite struct NeonPricingTests {
    @Test func launchAndScaleRates() {
        #expect(NeonPricing.cost(metric: "compute_unit_seconds", value: 100, plan: "launch") == Decimal(string: "10.6"))
        #expect(NeonPricing.cost(metric: "compute_unit_seconds", value: 100, plan: "scale_v2") == Decimal(string: "22.2"))
        #expect(NeonPricing.cost(metric: "root_branch_bytes_month", value: 2, plan: "launch") == Decimal(string: "0.7"))
        #expect(NeonPricing.cost(metric: "snapshot_storage_bytes_month", value: 10, plan: "scale") == Decimal(string: "0.9"))
    }

    @Test func allowancesAreSubtractedPerProjectMonth() {
        #expect(NeonPricing.cost(metric: "public_network_transfer_bytes", value: 58.50, plan: "launch") == 0)
        #expect(NeonPricing.cost(metric: "public_network_transfer_bytes", value: 600, plan: "launch") == 10)
        #expect(NeonPricing.cost(metric: "extra_branches_month", value: 11, plan: "launch") == 3)
        #expect(NeonPricing.cost(metric: "extra_branches_month", value: 11, plan: "scale") == 0)
    }

    @Test func freeAndUnknownPlans() {
        #expect(NeonPricing.cost(metric: "compute_unit_seconds", value: 100, plan: "free_v3") == 0)
        #expect(NeonPricing.cost(metric: "compute_unit_seconds", value: 100, plan: nil) == nil)
        #expect(NeonPricing.cost(metric: "private_network_transfer_bytes", value: 5, plan: "launch") == nil)
    }
}

@Suite @MainActor struct ApproximateMarkingTests {
    @Test func estimatedServiceMarksMonthsWithUsage() throws {
        let store = SpendStore(container: try Persistence.makeContainer(inMemory: true),
                               keychain: KeychainStore(serviceName: "app.itspendtracker.ITSpendTracker.tests.\(UUID().uuidString)"))
        let neon = try store.addConnectedService(name: "Neon", accountIdentifier: "", connector: .neon, definition: nil,
                                                 credentials: ["apiKey": "k"])
        try store.apply(ConnectorSnapshot(dailyCosts: [d(2026, 8, 1): 60.00], coveredFrom: d(2025, 10, 1), keys: nil, tokenUsage: nil),
                        to: neon, at: .now)
        #expect(neon.spendIsEstimate)
        #expect(neon.isApproximate(in: m(2026, 8)))
        #expect(!neon.isApproximate(in: m(2026, 7)))   // zero usage: nothing approximate in that month
        let openAI = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                   credentials: ["adminKey": "k"])
        #expect(!openAI.spendIsEstimate)
        try store.remove(neon)
        try store.remove(openAI)
    }
}

@Suite struct UsageMetricOrganizationTests {
    private let august = Month(year: 2026, month: 8)

    @Test func mergeKeepsOrganizationsApartButSumsWithinOne() {
        func row(_ organization: String?, _ value: Decimal) -> UsageMetricRow {
            UsageMetricRow(month: august, project: "app", metric: "compute_unit_seconds", value: value, organization: organization)
        }
        let merged = [row("Alpha", 1), row("Beta", 2), row("Alpha", 3)].merged()
        #expect(merged.count == 2)
        #expect(merged.first { $0.organization == "Alpha" }?.value == 4)   // daily buckets of one organization add up
        #expect(merged.first { $0.organization == "Beta" }?.value == 2)
    }

    @Test func labelShowsTheOrganizationOnlyWhenThereAreSeveral() {
        let row = UsageMetricRow(month: august, project: "app", metric: "m", value: 1, organization: "Alpha")
        #expect(row.label(showingOrganization: true) == "app (Alpha)")
        #expect(row.label(showingOrganization: false) == "app")
        let legacy = UsageMetricRow(month: august, project: "app", metric: "m", value: 1)      // saved before organizations were stored
        #expect(legacy.label(showingOrganization: true) == "app")
        #expect(UsageMetricLabel.project("app", organization: "", showingOrganization: true) == "app")
    }

    @Test func recordKeepsTheOrganization() {
        let record = UsageMetricRecord(UsageMetricRow(month: august, project: "app", metric: "m", value: 1, organization: "Beta"))
        #expect(record.organization == "Beta")
        #expect(record.label(showingOrganization: true) == "app (Beta)")
    }
}

@Suite struct KeyCostSplitTests {
    typealias Cost = KeyCostSplit.ServiceCost

    @Test func splitsServiceCostByRequestShare() {
        let costs = [Cost(project: "p1", service: "generativelanguage.googleapis.com"): Decimal(10)]
        let requests = ["k1": ["generativelanguage.googleapis.com": 30], "k2": ["generativelanguage.googleapis.com": 10],
                        "k3": ["firestore.googleapis.com": 100]]
        let split = KeyCostSplit.split(costs: costs, requests: requests, keyProjects: ["k1": "p1", "k2": "p1", "k3": "p1"])
        #expect(split["k1"] == Decimal(string: "7.5"))
        #expect(split["k2"] == Decimal(string: "2.5"))
        #expect(split["k3"] == nil) // called another service only
    }

    @Test func keysOfOtherProjectsAndUncalledServicesAreIgnored() {
        let costs = [Cost(project: "p1", service: "s"): Decimal(4), Cost(project: "p1", service: "unused"): Decimal(9)]
        let split = KeyCostSplit.split(costs: costs, requests: ["kA": ["s": 1], "kB": ["s": 1]], keyProjects: ["kA": "p1", "kB": "p2"])
        #expect(split == ["kA": 4])  // kB belongs to p2; "unused" has no callers → unattributed
    }
}

@Suite struct TrendTests {
    /// 10 USD per day from 2026-08-01 through `last`.
    func flat(_ perDay: Decimal, from: Day = d(2026, 8, 1), through last: Day) -> [Day: Decimal] {
        Dictionary(uniqueKeysWithValues: from.through(last).map { ($0, perDay) })
    }

    @Test func dayArithmeticCrossesMonthsAndYears() {
        #expect(d(2026, 3, 1).previousDay == d(2026, 2, 28))
        #expect(d(2026, 12, 31).adding(days: 1) == d(2027, 1, 1))
        #expect(d(2026, 9, 25).adding(days: -30) == d(2026, 8, 26))
        #expect(d(2026, 9, 29).through(d(2026, 10, 2)).count == 4)
        #expect(d(2026, 9, 29).through(d(2026, 9, 28)).isEmpty)
    }

    @Test func forecastExtendsRunRateAndAddsWholeMonthSubscriptions() {
        let plan = SubscriptionPlan(name: "Pro", period: .monthly, start: d(2026, 1, 28), end: nil,
                                    prices: [.init(effectiveFrom: d(2026, 1, 28), amount: 100)])
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: flat(10, through: d(2026, 9, 10)),
                                   providerCoverageStart: d(2026, 8, 1), subscriptions: [plan])
        // 9 past days + today (rate 10, today's 10 already) + 20 days left = 30 × 10, plus the charge due on the 28th.
        #expect(ledger.forecast(today: d(2026, 9, 10)) == .value(400))
        #expect(ledger.spend(from: d(2026, 9, 1), through: d(2026, 9, 10)) == .value(100))
    }

    @Test func runRateFollowsTheLastFourteenFullDays() {
        var costs = flat(10, through: d(2026, 9, 5))
        costs.merge(flat(30, from: d(2026, 9, 6), through: d(2026, 9, 19))) { $1 }
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: costs, providerCoverageStart: d(2026, 8, 1))
        #expect(ledger.runRate(today: d(2026, 9, 20)) == 30)
        // 5 × 10 + 14 × 30 + today max(0, 30) + 10 days × 30.
        #expect(ledger.forecast(today: d(2026, 9, 20)) == .value(50 + 420 + 30 + 300))
    }

    @Test func forecastOnFirstDayOfMonthUsesPreviousMonthsRate() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: flat(10, through: d(2026, 9, 30)),
                                   providerCoverageStart: d(2026, 8, 1))
        #expect(ledger.forecast(today: d(2026, 10, 1)) == .value(310))
    }

    @Test func noFullDayOfDataMeansNoForecast() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: [d(2026, 9, 10): 5],
                                   providerCoverageStart: d(2026, 9, 10))
        #expect(ledger.forecast(today: d(2026, 9, 10)) == .noData)
        let unconnected = ServiceLedger(isConnected: true)
        #expect(unconnected.forecast(today: d(2026, 9, 10)) == .noData)
        #expect(SpendTrends.forecast([ledger, ServiceLedger(isConnected: false)], today: d(2026, 9, 10)) == .value(0))
    }

    @Test func monthlyBookedUsageIsSpreadAndExtrapolatedAtItsPace() {
        // Neon-style: the month's usage so far is booked on its first day.
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: [d(2026, 8, 1): 31, d(2026, 9, 1): 20],
                                   providerCoverageStart: d(2026, 8, 1), usageIsDaily: false)
        let today = d(2026, 9, 10)
        #expect(ledger.spend(on: d(2026, 8, 15), today: today) == .value(1))
        #expect(ledger.spend(on: d(2026, 9, 1), today: today) == .value(2))
        #expect(ledger.spend(on: d(2026, 7, 31), today: today) == .noData)
        #expect(ledger.forecast(today: today) == .value(60))
        #expect(ledger.dailySpend(from: d(2026, 8, 1), through: d(2026, 9, 10), today: today) == .value(51))
    }

    @Test func comparisonUsesFullDaysAndKeepsNoData() {
        var costs = flat(10, through: d(2026, 9, 3))
        costs.merge(flat(15, from: d(2026, 9, 4), through: d(2026, 10, 3))) { $1 }
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: costs, providerCoverageStart: d(2026, 8, 1))
        let comparison = SpendTrends.comparison([ledger], days: 30, today: d(2026, 10, 4))
        #expect(comparison.current == .value(450))
        #expect(comparison.previous == .value(300))
        #expect(comparison.change == Decimal(string: "0.5"))
        // A service covering only the current period: its own previous period is "no data" ...
        let young = ServiceLedger(isConnected: true, providerDailyCosts: flat(2, from: d(2026, 9, 1), through: d(2026, 10, 3)),
                                  providerCoverageStart: d(2026, 9, 1))
        let single = SpendTrends.comparison(young, days: 30, today: d(2026, 10, 4))
        #expect(single.current == .value(60))
        #expect(single.previous == .noData)
        #expect(single.change == nil)
        // ... and the total compares like with like, naming the service it left out.
        let both = SpendTrends.comparison([young, ledger], days: 30, today: d(2026, 10, 4))
        #expect(both == SpendTrends.Comparison(current: .value(450), previous: .value(300), excluded: [0]))
        // Services that have no provider data at all yet do not count.
        #expect(SpendTrends.comparison([ledger, ServiceLedger(isConnected: true)], days: 30, today: d(2026, 10, 4)) == comparison)
    }

    @Test func monthlyBookedUsageUsesLastMonthEarlyInTheMonth() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: [d(2026, 9, 1): 90, d(2026, 10, 1): 0.5],
                                   providerCoverageStart: d(2026, 8, 1), usageIsDaily: false)
        #expect(ledger.forecast(today: d(2026, 10, 1)) == .value(90))
        let busy = ServiceLedger(isConnected: true, providerDailyCosts: [d(2026, 9, 1): 90, d(2026, 10, 1): 120],
                                 providerCoverageStart: d(2026, 8, 1), usageIsDaily: false)
        #expect(busy.forecast(today: d(2026, 10, 5)) == .value(120))
        // After the first week the month's own pace applies: 40 in 8 days → 155 for 31 days.
        let paced = ServiceLedger(isConnected: true, providerDailyCosts: [d(2026, 9, 1): 90, d(2026, 10, 1): 40],
                                  providerCoverageStart: d(2026, 8, 1), usageIsDaily: false)
        #expect(paced.forecast(today: d(2026, 10, 8)) == .value(155))
    }

    @Test func dailyTotalsMovingAverageAndCumulative() {
        let a = ServiceLedger(isConnected: true, providerDailyCosts: [d(2026, 9, 1): 4, d(2026, 9, 2): 8],
                              providerCoverageStart: d(2026, 9, 1))
        let manual = ServiceLedger(isConnected: false, creditPurchases: [(day: d(2026, 9, 2), amount: 2)])
        let today = d(2026, 9, 3)
        let days = d(2026, 8, 31).through(today)
        let totals = SpendTrends.dailyTotals([a, manual], days: days, today: today)
        #expect(totals == [0, 4, 10, 0])
        #expect(SpendTrends.dailyTotals([a], days: [d(2026, 8, 31)], today: today) == [nil])
        #expect(SpendTrends.movingAverage([nil, 4, 10, 0], window: 2) == [nil, 4, 7, 5])
        let running = SpendTrends.cumulative([a, manual], month: m(2026, 9), through: today, today: today)
        #expect(running.map(\.total) == [4, 14, 14])
    }
}

@Suite struct MonthToDateTests {
    @Test func excludesChargesDueLaterInTheMonth() {
        let plan = SubscriptionPlan(name: "Plus", period: .monthly, start: d(2025, 3, 14), end: nil,
                                    prices: [.init(effectiveFrom: d(2025, 3, 14), amount: 20)])
        let manual = ServiceLedger(isConnected: false, subscriptions: [plan])
        let usage = ServiceLedger(isConnected: true, providerDailyCosts: [d(2026, 10, 1): 7],
                                  providerCoverageStart: d(2026, 9, 1))
        #expect(SpendTrends.monthToDate([manual, usage], today: d(2026, 10, 1)) == .value(7))
        #expect(SpendTrends.monthToDate([manual, usage], today: d(2026, 10, 14)) == .value(27))
    }
}
