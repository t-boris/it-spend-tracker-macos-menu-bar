import Foundation

/// A USD amount or the explicit absence of data. "No data" is never shown as zero (REQ-003, REQ-004).
enum Amount: Equatable, Sendable {
    case noData
    case value(Decimal)

    var decimal: Decimal? {
        if case .value(let value) = self { return value }
        return nil
    }

    static func + (lhs: Amount, rhs: Amount) -> Amount {
        switch (lhs, rhs) {
        case (.value(let a), .value(let b)): .value(a + b)
        case (.value, .noData): lhs
        case (.noData, _): rhs
        }
    }
}

/// A fixed subscription (DEC-014, DEC-026): charged on its start day every period, until the optional end date.
struct SubscriptionPlan: Equatable, Sendable {
    enum Period: String, Codable, CaseIterable, Sendable, Identifiable {
        case monthly, yearly
        var id: String { rawValue }
        var months: Int { self == .monthly ? 1 : 12 }
    }

    struct Price: Equatable, Sendable {
        var effectiveFrom: Day
        var amount: Decimal
    }

    var name: String = ""
    var period: Period
    var start: Day
    var end: Day?
    /// Price history. The earliest entry applies to charges before any later entry.
    var prices: [Price]

    /// The price in effect on `day`.
    func price(on day: Day) -> Decimal? {
        let sorted = prices.sorted { $0.effectiveFrom < $1.effectiveFrom }
        return (sorted.last { $0.effectiveFrom <= day } ?? sorted.first)?.amount
    }

    /// The first charge on or after `day`, if the subscription is still running then.
    func nextCharge(onOrAfter day: Day) -> (day: Day, amount: Decimal)? {
        charges(from: day, through: day.calendarMonth.adding(months: period.months + 1).lastDay).first
    }

    /// The first charge strictly after `day`.
    func nextCharge(after day: Day) -> (day: Day, amount: Decimal)? {
        nextCharge(onOrAfter: day.nextDay)
    }

    /// Charges falling due between `from` and `through`, inclusive.
    func charges(from: Day, through: Day) -> [(day: Day, amount: Decimal)] {
        let sortedPrices = prices.sorted { $0.effectiveFrom < $1.effectiveFrom }
        guard !sortedPrices.isEmpty else { return [] }
        let last = min(through, end ?? through)
        var result: [(Day, Decimal)] = []
        var occurrence = 0
        while true {
            let due = start.adding(months: occurrence * period.months)
            if due > last { break }
            if due >= from {
                let price = sortedPrices.last { $0.effectiveFrom <= due } ?? sortedPrices[0]
                result.append((due, price.amount))
            }
            occurrence += 1
        }
        return result
    }
}

/// A snapshot of everything stored for one service, used by the pure calculations below.
///
/// Spend rules (DEC-023, DEC-026): provider-reported usage cost (API-connected services)
/// + subscription charges due (any service) + recorded credit purchases (manual services only).
struct ServiceLedger: Sendable {
    /// Whether the service is fed by a provider API (built-in or approved AI-proposed connector).
    var isConnected: Bool
    /// Provider-reported usage cost per day (UTC buckets), USD.
    var providerDailyCosts: [Day: Decimal] = [:]
    /// First day covered by provider data. Days before it are "no data" (DEC-015).
    var providerCoverageStart: Day?
    /// Whether provider usage is reported per day; monthly-booked usage sits on the first day of its month (DEC-039).
    var usageIsDaily = true
    var subscriptions: [SubscriptionPlan] = []
    var creditPurchases: [(day: Day, amount: Decimal)] = []
    /// A user-entered balance (DEC-021).
    var balanceSnapshot: (day: Day, amount: Decimal)?

    // MARK: Spend

    /// Spend for a whole month.
    func spend(in month: Month) -> Amount {
        spend(from: month.firstDay, through: month.lastDay)
    }

    /// Spend for days `from...through`.
    func spend(from: Day, through: Day) -> Amount {
        var total = usage(from: from, through: through)
        let charges = subscriptionCharges(from: from, through: through)
        if !charges.isEmpty { total = total + .value(charges.reduce(0) { $0 + $1.amount }) }
        if !isConnected {
            total = total + .value(creditPurchases.filter { $0.day >= from && $0.day <= through }.reduce(0) { $0 + $1.amount })
        }
        return total
    }

    /// Provider-reported usage cost; "no data" before coverage. Manual services have no usage (zero).
    func usage(from: Day, through: Day) -> Amount {
        guard isConnected else { return .value(0) }
        guard let coverage = providerCoverageStart, through >= coverage else { return .noData }
        return .value(providerSum(from: max(from, coverage), through: through))
    }

    func usage(in month: Month) -> Amount { usage(from: month.firstDay, through: month.lastDay) }

    /// Charges of all subscriptions falling due in the period.
    func subscriptionCharges(from: Day, through: Day) -> [(day: Day, amount: Decimal)] {
        subscriptions.flatMap { $0.charges(from: from, through: through) }
    }

    struct Payment: Equatable, Sendable {
        var day: Day
        var label: String
        var amount: Decimal
    }

    /// Subscription charges and recorded credit purchases with their dates, oldest first.
    func payments(from: Day, through: Day) -> [Payment] {
        let charges = subscriptions.flatMap { plan in
            plan.charges(from: from, through: through).map { Payment(day: $0.day, label: plan.name, amount: $0.amount) }
        }
        let purchases = creditPurchases.filter { $0.day >= from && $0.day <= through }
            .map { Payment(day: $0.day, label: String(localized: "Credit purchase"), amount: $0.amount) }
        return (charges + purchases).sorted { $0.day < $1.day }
    }

    /// Recorded credit purchases counted as spend (manual services only, DEC-023).
    func countedPurchases(in month: Month) -> Decimal {
        guard !isConnected else { return 0 }
        return creditPurchases.filter { $0.day.calendarMonth == month }.reduce(0) { $0 + $1.amount }
    }

    func subscriptionTotal(in month: Month) -> Decimal {
        subscriptionCharges(from: month.firstDay, through: month.lastDay).reduce(0) { $0 + $1.amount }
    }

    // MARK: Credits (informational for API-connected services, DEC-021 / DEC-023)

    var totalPurchased: Decimal { creditPurchases.reduce(0) { $0 + $1.amount } }

    enum Remaining: Equatable, Sendable {
        case noData
        /// Snapshot value carried forward with later purchases; no usage data to subtract.
        case asOfSnapshot(Decimal, snapshotDay: Day)
        /// Snapshot + later purchases − later provider-reported usage cost.
        case estimate(Decimal)
    }

    /// Remaining credit balance estimate as of `today` (DEC-021).
    func remainingBalance(today: Day) -> Remaining {
        guard let snapshot = balanceSnapshot else { return .noData }
        let later = creditPurchases.filter { $0.day > snapshot.day }.reduce(0) { $0 + $1.amount }
        let base = snapshot.amount + later
        guard isConnected else {
            return .asOfSnapshot(base, snapshotDay: snapshot.day)
        }
        guard let coverage = providerCoverageStart, coverage <= snapshot.day.nextDay else {
            return .noData
        }
        let used = today > snapshot.day ? providerSum(from: snapshot.day.nextDay, through: today) : 0
        return .estimate(base - used)
    }

    private func providerSum(from: Day, through: Day) -> Decimal {
        providerDailyCosts.reduce(into: 0) { sum, entry in
            if entry.key >= from && entry.key <= through { sum += entry.value }
        }
    }
}

extension Day {
    var nextDay: Day {
        day < calendarMonth.dayCount ? Day(year: year, month: month, day: day + 1) : calendarMonth.next.firstDay
    }
}
