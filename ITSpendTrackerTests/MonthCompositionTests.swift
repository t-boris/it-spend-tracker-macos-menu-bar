import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-015: the service page shows usage, subscriptions and total for the *selected* month, not only the current one.
@Suite struct MonthCompositionTests {
    private func day(_ year: Int, _ month: Int, _ day: Int) -> Day { Day(year: year, month: month, day: day) }

    private func monthlyPlan(price: Decimal) -> SubscriptionPlan {
        SubscriptionPlan(period: .monthly, start: day(2026, 1, 5), end: nil,
                         prices: [.init(effectiveFrom: day(2026, 1, 5), amount: price)])
    }

    @Test func pastMonthSplitsUsageAndSubscriptions() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: [day(2026, 8, 10): 30],
                                   providerCoverageStart: day(2026, 1, 1), subscriptions: [monthlyPlan(price: 20)])
        let august = MonthComposition(ledger: ledger, month: Month(year: 2026, month: 8))
        #expect(august.usage == .value(30))
        #expect(august.subscriptions == 20)
        #expect(august.total == .value(50))
        // A different month of the same service is composed independently.
        let september = MonthComposition(ledger: ledger, month: Month(year: 2026, month: 9))
        #expect(september.usage == .value(0) && september.subscriptions == 20 && september.total == .value(20))
    }

    @Test func monthBeforeProviderDataIsNoDataForUsageButKeepsSubscriptions() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: [day(2026, 4, 2): 8],
                                   providerCoverageStart: day(2026, 3, 1), subscriptions: [monthlyPlan(price: 20)])
        let february = MonthComposition(ledger: ledger, month: Month(year: 2026, month: 2))
        #expect(february.usage == .noData)
        #expect(february.subscriptions == 20)
        #expect(february.total == .value(20))
    }

    @Test func manualServiceHasNoUsageAndCountsPurchases() {
        let ledger = ServiceLedger(isConnected: false, subscriptions: [monthlyPlan(price: 20)],
                                   creditPurchases: [(day: day(2026, 8, 12), amount: 15)])
        let august = MonthComposition(ledger: ledger, month: Month(year: 2026, month: 8))
        #expect(august.usage == nil)
        #expect(august.subscriptions == 20)
        #expect(august.total == .value(35))
    }

    @Test func connectedServiceWithoutSubscriptionsHasNoSubscriptionRow() {
        let ledger = ServiceLedger(isConnected: true, providerDailyCosts: [day(2026, 8, 10): 30],
                                   providerCoverageStart: day(2026, 1, 1))
        let august = MonthComposition(ledger: ledger, month: Month(year: 2026, month: 8))
        #expect(august.subscriptions == nil)
        #expect(august.usage == .value(30) && august.total == .value(30))
    }
}
