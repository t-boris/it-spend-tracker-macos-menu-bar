import Foundation

/// Fixed warning rules (DEC-010). v1 has no notifications and no budgets (DEC-002).
enum WarningRules {
    static let expiryWindowDays = 14
    static let increaseRatio: Decimal = 0.20
    static let increaseMinimumUSD: Decimal = 5

    /// A key expires within the next 14 days (already expired keys are not "expiring soon").
    static func isExpiringSoon(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        let window = TimeInterval(expiryWindowDays * 24 * 60 * 60)
        return expiresAt >= now && expiresAt <= now.addingTimeInterval(window)
    }

    struct Increase: Equatable, Sendable {
        var monthToDate: Decimal
        var previousSamePeriod: Decimal
    }

    /// Month-to-date spend vs. the same number of days of the previous month:
    /// warns when it is more than 20% higher and at least 5 USD higher.
    /// Usage the provider books once per month (Neon, GitHub) is spread over the days of its month first (DEC-039),
    /// so the previous month is prorated by day instead of being counted whole against a partial current month.
    static func spendIncrease(ledger: ServiceLedger, today: Day) -> Increase? {
        let current = today.calendarMonth
        let previous = current.previous
        let previousLastDay = Day(year: previous.year, month: previous.month,
                                  day: min(today.day, previous.dayCount))
        guard let now = ledger.dailySpend(from: current.firstDay, through: today, today: today).decimal,
              let before = ledger.dailySpend(from: previous.firstDay, through: previousLastDay, today: today).decimal
        else { return nil }
        let exceedsRatio = now > before * (1 + increaseRatio)
        let exceedsFloor = now - before >= increaseMinimumUSD
        return exceedsRatio && exceedsFloor ? Increase(monthToDate: now, previousSamePeriod: before) : nil
    }
}
