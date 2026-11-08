import Foundation

/// Refresh timing (DEC-009): every 4 hours while running; on launch and wake only when stale.
enum RefreshPolicy {
    static let interval: TimeInterval = 4 * 60 * 60

    static func isStale(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > interval
    }

    /// First day to request from a provider. The first fetch backfills the previous 12 months (DEC-015);
    /// later fetches re-read the previous and current month to pick up late adjustments.
    static func fetchStart(hasHistory: Bool, today: Day) -> Day {
        let back = hasHistory ? 1 : 12
        return today.calendarMonth.adding(months: -back).firstDay
    }
}
