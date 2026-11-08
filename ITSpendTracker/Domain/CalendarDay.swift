import Foundation

/// A calendar month (year + month), independent of time zone once constructed.
struct Month: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        let zeroBased = year * 12 + (month - 1)
        self.year = Int((Double(zeroBased) / 12).rounded(.down))
        self.month = zeroBased - self.year * 12 + 1
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year!, month: parts.month!)
    }

    var index: Int { year * 12 + (month - 1) }

    /// Inverse of `index`.
    init(index: Int) { self.init(year: 0, month: index + 1) }

    func adding(months: Int) -> Month { Month(year: year, month: month + months) }
    var previous: Month { adding(months: -1) }
    var next: Month { adding(months: 1) }

    var firstDay: Day { Day(year: year, month: month, day: 1) }

    var dayCount: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        return calendar.range(of: .day, in: .month, for: date)!.count
    }

    var lastDay: Day { Day(year: year, month: month, day: dayCount) }

    /// Months from `self` through `end`, inclusive, in ascending order.
    func through(_ end: Month) -> [Month] {
        guard end >= self else { return [] }
        return (0...(end.index - index)).map { adding(months: $0) }
    }

    static func < (lhs: Month, rhs: Month) -> Bool { lhs.index < rhs.index }

    var description: String { String(format: "%04d-%02d", year, month) }
}

/// A calendar day. Stored as an `Int` key (`yyyymmdd`) in the database.
struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    init?(key: Int) {
        let year = key / 10_000, month = (key / 100) % 100, day = key % 100
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// Parses `yyyy-MM-dd` (optionally followed by a time part).
    init?(isoPrefix string: String) {
        let parts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(key: parts[0] * 10_000 + parts[1] * 100 + parts[2])
    }

    var key: Int { year * 10_000 + month * 100 + day }
    var calendarMonth: Month { Month(year: year, month: month) }

    /// Midnight at the start of this day in the given calendar's time zone.
    func startDate(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The same day-of-month `months` later, clamped to the target month's length.
    func adding(months: Int) -> Day {
        let target = calendarMonth.adding(months: months)
        return Day(year: target.year, month: target.month, day: min(day, target.dayCount))
    }

    /// The day `days` later (or earlier when negative).
    func adding(days: Int) -> Day {
        Day(Calendar.utc.date(byAdding: .day, value: days, to: startDate(calendar: .utc))!, calendar: .utc)
    }

    var previousDay: Day { adding(days: -1) }

    /// Days from `self` through `end`, inclusive, in ascending order.
    func through(_ end: Day) -> [Day] {
        guard end >= self else { return [] }
        let count = Calendar.utc.dateComponents([.day], from: startDate(calendar: .utc), to: end.startDate(calendar: .utc)).day!
        return (0...count).map { adding(days: $0) }
    }

    static func < (lhs: Day, rhs: Day) -> Bool { lhs.key < rhs.key }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

extension Calendar {
    /// Gregorian calendar in UTC, used for provider buckets reported in UTC.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
