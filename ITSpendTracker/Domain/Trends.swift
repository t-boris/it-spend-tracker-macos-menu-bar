import Foundation

/// Day-level spend, period comparison and the month-end forecast (REQ-019, DEC-039).
extension ServiceLedger {
    /// Days of full provider data the forecast run rate averages.
    static let runRateDays = 14
    /// Days of a month after which monthly-booked usage is extrapolated at its own pace.
    static let monthlyPaceMinimumDays = 7

    /// Spend on one day. Usage booked per month is spread evenly over the month's covered days
    /// (through `today` for the month in progress), so it does not show as a one-day spike.
    func spend(on day: Day, today: Day) -> Amount {
        var total = dailyUsage(on: day, today: today)
        let charges = subscriptionCharges(from: day, through: day)
        if !charges.isEmpty { total = total + .value(charges.reduce(0) { $0 + $1.amount }) }
        if !isConnected {
            total = total + .value(creditPurchases.filter { $0.day == day }.reduce(0) { $0 + $1.amount })
        }
        return total
    }

    /// Spend summed over `from...through` with monthly-booked usage spread per day (see `spend(on:today:)`).
    func dailySpend(from: Day, through: Day, today: Day) -> Amount {
        from.through(through).map { spend(on: $0, today: today) }.reduce(Amount.noData, +)
    }

    func dailyUsage(on day: Day, today: Day) -> Amount {
        guard isConnected else { return .value(0) }
        if usageIsDaily { return usage(from: day, through: day) }
        guard let coverage = providerCoverageStart, day >= coverage, day <= today else { return .noData }
        let month = day.calendarMonth
        guard let total = usage(in: month).decimal else { return .noData }
        let first = max(month.firstDay, coverage)
        let last = month == today.calendarMonth ? today : month.lastDay
        return .value(total / Decimal(last.day - first.day + 1))
    }

    /// ≈ spend for the whole month containing `today` (DEC-039); `.noData` when usage cannot be projected.
    func forecast(today: Day) -> Amount {
        let month = today.calendarMonth
        let fixed = subscriptionTotal(in: month) + countedPurchases(in: month)
        guard isConnected else { return .value(fixed) }
        guard let usage = projectedUsage(today: today) else { return .noData }
        return .value(fixed + usage)
    }

    /// Projected usage of the month containing `today`; `nil` without enough provider data.
    func projectedUsage(today: Day) -> Decimal? {
        let month = today.calendarMonth
        guard let coverage = providerCoverageStart, coverage <= today else { return nil }
        let daysInMonth = Decimal(month.dayCount)
        if !usageIsDaily {
            guard let soFar = usage(in: month).decimal else { return nil }
            // A few days (often hours) of a month say little about it: early on, last month's usage is the estimate.
            if today.day <= Self.monthlyPaceMinimumDays, let previous = usage(in: month.previous).decimal,
               coverage <= month.previous.firstDay {
                return max(soFar, previous)
            }
            // Month-to-date pace of the covered days, extended to the whole month.
            let elapsed = Decimal(today.day - max(month.firstDay, coverage).day + 1)
            return soFar * daysInMonth / elapsed
        }
        guard let rate = runRate(today: today) else { return nil }
        let yesterday = today.previousDay
        var total: Decimal = 0
        if month.firstDay <= yesterday {
            for day in month.firstDay.through(yesterday) {
                total += usage(from: day, through: day).decimal ?? rate
            }
        }
        total += max(usage(from: today, through: today).decimal ?? 0, rate)
        total += rate * Decimal(month.dayCount - today.day)
        return total
    }

    /// Whether every day from `from` on has provider data (always true for manual services).
    func covers(from day: Day) -> Bool {
        guard isConnected else { return true }
        return providerCoverageStart.map { $0 <= day } ?? false
    }

    /// Average daily usage of the last `runRateDays` full days that have provider data.
    func runRate(today: Day) -> Decimal? {
        guard let coverage = providerCoverageStart else { return nil }
        let start = max(today.adding(days: -Self.runRateDays), coverage)
        let end = today.previousDay
        guard start <= end, let sum = usage(from: start, through: end).decimal else { return nil }
        return sum / Decimal(start.through(end).count)
    }
}

/// Totals across services for the day-level history (REQ-019).
enum SpendTrends {
    /// The `count` full days ending yesterday, ascending.
    static func fullDays(count: Int, today: Day) -> [Day] {
        today.adding(days: -count).through(today.previousDay)
    }

    struct Comparison: Equatable, Sendable {
        var current: Amount
        var previous: Amount
        /// Indices of services left out of a total because they lack data for one of the periods.
        var excluded: [Int] = []

        /// Relative change, e.g. 0.25 for +25%; `nil` when either side is missing or the previous period is zero.
        var change: Decimal? {
            guard let now = current.decimal, let before = previous.decimal, before != 0 else { return nil }
            return (now - before) / before
        }
    }

    /// One service: the last `days` full days against the `days` before them.
    /// A period the provider data does not cover completely is "no data", never a partial sum.
    static func comparison(_ ledger: ServiceLedger, days: Int, today: Day) -> Comparison {
        let current = fullDays(count: days, today: today)
        let previous = fullDays(count: days, today: today.adding(days: -days))
        func total(_ range: [Day]) -> Amount {
            guard let first = range.first, let last = range.last, ledger.covers(from: first) else { return .noData }
            return ledger.dailySpend(from: first, through: last, today: today)
        }
        return Comparison(current: total(current), previous: total(previous))
    }

    /// Total of the services that have data for both periods, so like is compared with like; services with data
    /// for only part of the range are listed in `excluded`. Services without any provider data are ignored.
    static func comparison(_ ledgers: [ServiceLedger], days: Int, today: Day) -> Comparison {
        let start = today.adding(days: -2 * days)
        var result = Comparison(current: .noData, previous: .noData)
        for (index, ledger) in ledgers.enumerated() where !ledger.isConnected || ledger.providerCoverageStart != nil {
            guard ledger.covers(from: start) else {
                result.excluded.append(index)
                continue
            }
            let single = comparison(ledger, days: days, today: today)
            result.current = result.current + single.current
            result.previous = result.previous + single.previous
        }
        return result
    }

    /// Total spend per day across `ledgers`; `nil` for days without any data.
    static func dailyTotals(_ ledgers: [ServiceLedger], days: [Day], today: Day) -> [Decimal?] {
        days.map { day in ledgers.map { $0.spend(on: day, today: today) }.reduce(Amount.noData, +).decimal }
    }

    /// Trailing average over up to `window` values ending at each position; days without data are skipped.
    static func movingAverage(_ values: [Decimal?], window: Int) -> [Decimal?] {
        values.indices.map { index in
            let known = values[max(0, index - window + 1)...index].compactMap { $0 }
            guard !known.isEmpty else { return nil }
            return known.reduce(0, +) / Decimal(known.count)
        }
    }

    /// Running total of `month` from its first day through `through` (inclusive), one value per day.
    static func cumulative(_ ledgers: [ServiceLedger], month: Month, through: Day, today: Day) -> [(day: Day, total: Decimal)] {
        let last = min(through, month.lastDay)
        guard month.firstDay <= last else { return [] }
        var running: Decimal = 0
        return month.firstDay.through(last).map { day in
            running += ledgers.map { $0.spend(on: day, today: today) }.reduce(Amount.noData, +).decimal ?? 0
            return (day, running)
        }
    }

    /// Spend from the first of today's month through today; charges due later in the month are not included.
    static func monthToDate(_ ledgers: [ServiceLedger], today: Day) -> Amount {
        ledgers.map { $0.spend(from: today.calendarMonth.firstDay, through: today) }.reduce(Amount.noData, +)
    }

    /// Sum of the per-service forecasts that exist.
    static func forecast(_ ledgers: [ServiceLedger], today: Day) -> Amount {
        ledgers.map { $0.forecast(today: today) }.reduce(Amount.noData, +)
    }
}
