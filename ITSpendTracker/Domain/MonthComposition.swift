import Foundation

/// How the cost of one month is composed on a service page: provider usage, fixed subscriptions and the total (REQ-015).
struct MonthComposition: Equatable, Sendable {
    /// Provider usage cost; `nil` for manual services, which have no provider usage.
    var usage: Amount?
    /// Subscription charges due in the month; `nil` when the service has no subscriptions.
    var subscriptions: Decimal?
    /// What counts toward totals for the month (DEC-023): usage + subscriptions (+ purchases on manual services).
    var total: Amount

    init(ledger: ServiceLedger, month: Month) {
        usage = ledger.isConnected ? ledger.usage(in: month) : nil
        subscriptions = ledger.subscriptions.isEmpty ? nil : ledger.subscriptionTotal(in: month)
        total = ledger.spend(in: month)
    }
}
