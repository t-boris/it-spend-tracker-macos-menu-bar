import Charts
import SwiftUI

/// History of the selected services (REQ-004, REQ-019): recent days with trends and the month forecast,
/// or the last 12 months.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("historyRange") private var range: HistoryRange = .days30

    enum HistoryRange: String, CaseIterable, Identifiable {
        case days30, days60, days90, months12
        var id: String { rawValue }

        var days: Int? {
            switch self {
            case .days30: 30
            case .days60: 60
            case .days90: 90
            case .months12: nil
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .days30: "30 days"
            case .days60: "60 days"
            case .days90: "90 days"
            case .months12: "12 months"
            }
        }
    }

    var body: some View {
        let hasServices = model.store.services.contains(where: \.includedInTotal)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                if !hasServices {
                    Text("Select services in the list to see their history.").foregroundStyle(.secondary)
                } else if let days = range.days {
                    DailyHistory(days: days)
                } else {
                    MonthlyHistory()
                }
            }
            .padding(16)
        }
    }
}

/// Monthly history per service and in total for the selected services (REQ-004).
/// Months without data are listed as "no data", never as zero.
struct MonthlyHistory: View {
    @Environment(AppModel.self) private var model
    static let monthsShown = 12

    struct Point: Identifiable {
        let month: Month
        let service: String
        let amount: Decimal
        var id: String { "\(month)-\(service)" }
    }

    var body: some View {
        let current = model.today.calendarMonth
        let months = current.adding(months: -(Self.monthsShown - 1)).through(current)
        let services = model.store.services.filter(\.includedInTotal)
        // Services whose spend is approximate carry "≈" in the legend (DEC-033).
        let ledgers = services.map { ($0.spendIsEstimate ? "≈ \($0.name)" : $0.name, $0.ledger) }
        let points = months.flatMap { month in
            ledgers.compactMap { name, ledger in
                ledger.spend(in: month).decimal.map { Point(month: month, service: name, amount: $0) }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            Chart(points) { point in
                BarMark(x: .value("Month", point.month.firstDay.date, unit: .month),
                        y: .value("USD", NSDecimalNumber(decimal: point.amount).doubleValue))
                    .foregroundStyle(by: .value("Service", point.service))
            }
            .monthAxis(months)
            .chartLegend(position: .bottom, alignment: .leading)
            .growingChartHeight(minimum: 260, fraction: 0.40)

            ScrollView(.horizontal, showsIndicators: false) {
                MonthlyTable(services: services, months: months)
            }
        }
    }
}

/// Spend of every selected service per month, then the total. A month with no data says so; a month with zero spend
/// shows $0.00, so the two never look alike (REQ-004).
struct MonthlyTable: View {
    @Environment(AppModel.self) private var model
    let services: [TrackedService]
    let months: [Month]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Month").font(.caption.weight(.semibold))
                ForEach(services) { service in
                    Text(service.spendIsEstimate ? "≈ \(service.name)" : service.name)
                        .font(.caption.weight(.semibold)).lineLimit(1)
                        .gridColumnAlignment(.trailing)
                }
                Text("Total").font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
            }
            Divider()
            ForEach(months.reversed(), id: \.self) { month in
                GridRow {
                    Text(Format.monthLong(month))
                    ForEach(services) { service in
                        AmountText(amount: service.ledger.spend(in: month), approximate: service.spendIsEstimate)
                    }
                    AmountText(amount: model.total(in: month), approximate: model.totalIsApproximate(in: month))
                        .fontWeight(.semibold)
                }
            }
        }
        .font(.callout)
    }
}

/// 12-month history of one service, stacked by usage, subscriptions and counted credit purchases,
/// so subscription payment months stand out (DEC-026).
struct ServiceHistoryChart: View {
    let ledger: ServiceLedger
    let currentMonth: Month
    var isEstimate = false

    struct Part: Identifiable {
        let month: Month
        let kind: String
        let amount: Decimal
        var id: String { "\(month)-\(kind)" }
    }

    var body: some View {
        let months = currentMonth.adding(months: -11).through(currentMonth)
        let usageLabel = ledger.isConnected && isEstimate ? "≈ " + String(localized: "Usage") : String(localized: "Usage")
        let subscriptionsLabel = String(localized: "Subscriptions")
        let purchasesLabel = String(localized: "Credit purchases")
        let parts = months.flatMap { month -> [Part] in
            var result: [Part] = []
            if ledger.isConnected, let usage = ledger.usage(in: month).decimal, usage != 0 {
                result.append(Part(month: month, kind: usageLabel, amount: usage))
            }
            let subscriptions = ledger.subscriptionTotal(in: month)
            if subscriptions != 0 { result.append(Part(month: month, kind: subscriptionsLabel, amount: subscriptions)) }
            let purchases = ledger.countedPurchases(in: month)
            if purchases != 0 { result.append(Part(month: month, kind: purchasesLabel, amount: purchases)) }
            return result
        }
        VStack(alignment: .leading, spacing: 6) {
            Chart(parts) { part in
                BarMark(x: .value("Month", part.month.firstDay.date, unit: .month),
                        y: .value("USD", NSDecimalNumber(decimal: part.amount).doubleValue))
                    .foregroundStyle(by: .value("Kind", part.kind))
            }
            .monthAxis(months)
            .chartLegend(position: .bottom, alignment: .leading)
            .growingChartHeight(minimum: 180, fraction: 0.27)
            let missing = months.filter { ledger.spend(in: $0) == .noData }
            if !missing.isEmpty {
                Text("No data for: \(missing.map(Format.monthName).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// A chart height that grows with the window (REQ-014): `fraction` of the visible page height, never below `minimum`.
    func growingChartHeight(minimum: CGFloat, fraction: CGFloat) -> some View {
        containerRelativeFrame(.vertical) { height, _ in max(minimum, height * fraction) }
    }

    /// Fixed 12-month domain with every other month labelled, so labels are not truncated.
    func monthAxis(_ months: [Month]) -> some View {
        let first = months.first?.firstDay.date ?? Date()
        let end = months.last?.next.firstDay.date ?? Date()
        return chartXScale(domain: first...end)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                }
            }
    }
}
