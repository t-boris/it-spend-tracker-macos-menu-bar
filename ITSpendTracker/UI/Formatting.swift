import SwiftUI

/// USD amounts with the current locale's conventions (DEC-005, DEC-018).
enum Format {
    static func usd(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func monthName(_ month: Month) -> String {
        month.firstDay.startDate().formatted(.dateTime.month(.abbreviated).year(.twoDigits))
    }

    static func monthLong(_ month: Month) -> String {
        month.firstDay.startDate().formatted(.dateTime.month(.wide).year())
    }

    static func day(_ day: Day) -> String {
        day.startDate().formatted(date: .abbreviated, time: .omitted)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// Parses a user-entered amount in either the current locale or with a dot separator.
    static func parseAmount(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: "$", with: "")
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
            .flatMap { $0 >= 0 ? $0 : nil }
    }
}

/// Renders an `Amount`, showing "no data" instead of zero when data is missing (REQ-003/004).
struct AmountText: View {
    let amount: Amount
    /// Marks figures that contain an approximation (DEC-033).
    var approximate = false

    var body: some View {
        switch amount {
        case .value(let value): Text(verbatim: (approximate ? "≈ " : "") + Format.usd(value)).monospacedDigit()
        case .noData: Text("no data").foregroundStyle(.secondary)
        }
    }
}

extension Day {
    init(date: Date) { self.init(date) }
    var date: Date { startDate() }
}

extension SubscriptionPlan.Period {
    var title: LocalizedStringResource {
        switch self {
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }

    var unit: LocalizedStringResource {
        switch self {
        case .monthly: "month"
        case .yearly: "year"
        }
    }
}
