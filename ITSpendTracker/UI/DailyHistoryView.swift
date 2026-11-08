import Charts
import SwiftUI

/// The last `days` days of the selected services: summary, daily chart with a 7-day average, this month against
/// last month with the forecast, and per-service changes (REQ-019, DEC-039).
struct DailyHistory: View {
    let days: Int
    @Environment(AppModel.self) private var model
    @State private var hoveredDate: Date?

    struct Series {
        let name: String
        let service: TrackedService
        let ledger: ServiceLedger

        /// Whether the total of `days` over `series` contains an approximate amount (DEC-033).
        static func isApproximate(_ series: [Series], on days: [Day], today: Day) -> Bool {
            series.contains { item in days.contains { item.service.isApproximate(on: $0, today: today) } }
        }
    }

    struct DayPoint: Identifiable {
        let day: Day
        let service: String
        let amount: Double
        var id: String { "\(day)-\(service)" }
    }

    struct AveragePoint: Identifiable {
        let day: Day
        let amount: Double
        var id: Day { day }
    }

    var body: some View {
        let today = model.today
        let month = today.calendarMonth
        // Services whose spend is approximate carry "≈" in the legend (DEC-033).
        let series = model.store.services.filter(\.includedInTotal).map { service in
            Series(name: service.spendIsEstimate ? "≈ \(service.name)" : service.name, service: service, ledger: service.ledger)
        }
        let ledgers = series.map(\.ledger)
        let approximate = series.contains { $0.service.spendIsEstimate }
        let range = today.adding(days: -(days - 1)).through(today)
        let totals = SpendTrends.dailyTotals(ledgers, days: range, today: today)
        let points = range.flatMap { day in
            series.compactMap { item -> DayPoint? in
                guard let amount = item.ledger.spend(on: day, today: today).decimal, amount != 0 else { return nil }
                return DayPoint(day: day, service: item.name, amount: amount.double)
            }
        }
        let average = zip(range, SpendTrends.movingAverage(totals, window: 7)).compactMap { day, value in
            value.map { AveragePoint(day: day, amount: $0.double) }
        }
        let comparison = SpendTrends.comparison(ledgers, days: days, today: today)
        let forecast = SpendTrends.forecast(ledgers, today: today)
        let withoutForecast = series.filter { $0.ledger.forecast(today: today) == .noData }.map(\.service.name)

        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                summary(ledgers: ledgers, month: month, today: today, comparison: comparison, forecast: forecast, approximate: approximate)
                if !comparison.excluded.isEmpty {
                    Text("* The change leaves out services without data for the whole \(2 * days) days: \(comparison.excluded.map { series[$0].service.name }.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Spend per day").font(.headline)
                dailyChart(points: points, average: average, range: range, totals: totals, series: series, today: today)
                    .growingChartHeight(minimum: 220, fraction: 0.33)
                Text("Bars: spend per day by service. Line: 7-day average. Today is incomplete.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("\(Format.monthLong(month)) against \(Format.monthLong(month.previous))").font(.headline)
                monthChart(ledgers: ledgers, month: month, today: today, forecast: forecast)
                    .growingChartHeight(minimum: 180, fraction: 0.27)
                Text("Forecast ≈ spend so far + the average daily usage of the last \(ServiceLedger.runRateDays) full days for the days left + subscription charges due this month. Usage reported per month (GitHub, Neon): last month's amount during the first \(ServiceLedger.monthlyPaceMinimumDays) days, then this month's pace.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !withoutForecast.isEmpty {
                    Text("No forecast (not enough data yet): \(withoutForecast.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            serviceTable(series: series, today: today)

            DisclosureGroup("Day by day") {
                dayTable(range: range, totals: totals, series: series, today: today)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: Summary

    private func summary(ledgers: [ServiceLedger], month: Month, today: Day, comparison: SpendTrends.Comparison, forecast: Amount,
                         approximate: Bool) -> some View {
        let lastMonth = model.total(in: month.previous)
        let forecastChange = SpendTrends.Comparison(current: forecast, previous: lastMonth).change
        // The figures cover every service with data for the period; the change compares like with like.
        let current = ledgers.map { SpendTrends.comparison($0, days: days, today: today).current }.reduce(Amount.noData, +)
        let likeForLike = comparison.excluded.isEmpty
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .topLeading)],
                         alignment: .leading, spacing: 12) {
            Tile(title: Text("\(Format.monthLong(month)) so far")) {
                AmountText(amount: SpendTrends.monthToDate(ledgers, today: today), approximate: model.totalIsApproximate(in: month))
            } footer: {
                Text("Day \(today.day) of \(month.dayCount)")
            }
            Tile(title: Text("Forecast for \(Format.monthLong(month))")) {
                AmountText(amount: forecast, approximate: true)
            } footer: {
                HStack(spacing: 4) {
                    Text("Last month:")
                    AmountText(amount: lastMonth, approximate: model.totalIsApproximate(in: month.previous))
                    ChangeBadge(change: forecastChange)
                }
            }
            Tile(title: Text("Last \(days) full days")) {
                AmountText(amount: current, approximate: approximate)
            } footer: {
                HStack(spacing: 4) {
                    if likeForLike {
                        Text("Previous \(days):")
                        AmountText(amount: comparison.previous, approximate: approximate)
                    } else {
                        Text("Change*:")
                    }
                    ChangeBadge(change: comparison.change)
                }
            }
            Tile(title: Text("Average per day")) {
                AmountText(amount: current.dividedBy(days), approximate: approximate)
            } footer: {
                HStack(spacing: 4) {
                    if likeForLike {
                        Text("Before:")
                        AmountText(amount: comparison.previous.dividedBy(days), approximate: approximate)
                    } else {
                        Text("Change*:")
                        ChangeBadge(change: comparison.change)
                    }
                }
            }
        }
    }

    // MARK: Charts

    private func dailyChart(points: [DayPoint], average: [AveragePoint], range: [Day], totals: [Decimal?],
                            series: [Series], today: Day) -> some View {
        let hovered = hoveredDate.map { Day($0) }.flatMap { day in range.contains(day) ? day : nil }
        let averageLabel = String(localized: "7-day average")
        return Chart {
            ForEach(points) { point in
                BarMark(x: .value("Day", point.day.date, unit: .day), y: .value("USD", point.amount))
                    .foregroundStyle(by: .value("Service", point.service))
                    .opacity(hovered == nil || hovered == point.day ? 1 : 0.5)
            }
            ForEach(average) { point in
                LineMark(x: .value("Day", point.day.date, unit: .day), y: .value("USD", point.amount),
                         series: .value("Series", averageLabel))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            if let hovered, let index = range.firstIndex(of: hovered) {
                RuleMark(x: .value("Day", hovered.date, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, alignment: .center, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        DayDetail(day: hovered, total: totals[index], series: series, today: today)
                    }
            }
        }
        .chartXSelection(value: $hoveredDate)
        .chartXScale(domain: (range.first ?? today).date...today.adding(days: 1).date)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days <= 30 ? 7 : 14)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
    }

    private func monthChart(ledgers: [ServiceLedger], month: Month, today: Day, forecast: Amount) -> some View {
        let thisMonth = String(localized: "This month")
        let lastMonth = String(localized: "Last month")
        let forecastLabel = String(localized: "Forecast")
        let current = SpendTrends.cumulative(ledgers, month: month, through: today, today: today)
        let previous = SpendTrends.cumulative(ledgers, month: month.previous, through: month.previous.lastDay, today: today)
        var projection: [(day: Int, total: Decimal)] = []
        if let last = current.last, let value = forecast.decimal {
            projection = [(last.day.day, last.total), (month.dayCount, max(value, last.total))]
        }
        return Chart {
            ForEach(previous, id: \.day) { point in
                LineMark(x: .value("Day of month", point.day.day), y: .value("USD", point.total.double),
                         series: .value("Series", lastMonth))
                    .foregroundStyle(by: .value("Series", lastMonth))
            }
            ForEach(current, id: \.day) { point in
                LineMark(x: .value("Day of month", point.day.day), y: .value("USD", point.total.double),
                         series: .value("Series", thisMonth))
                    .foregroundStyle(by: .value("Series", thisMonth))
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            ForEach(projection, id: \.day) { point in
                LineMark(x: .value("Day of month", point.day), y: .value("USD", point.total.double),
                         series: .value("Series", forecastLabel))
                    .foregroundStyle(by: .value("Series", forecastLabel))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            if let last = current.last {
                PointMark(x: .value("Day of month", last.day.day), y: .value("USD", last.total.double))
                    .foregroundStyle(by: .value("Series", thisMonth))
            }
            if let end = projection.last {
                PointMark(x: .value("Day of month", end.day), y: .value("USD", end.total.double))
                    .foregroundStyle(by: .value("Series", forecastLabel))
                    .annotation(position: .leading) {
                        Text(verbatim: "≈ " + Format.usd(end.total)).font(.caption.weight(.semibold))
                    }
            }
        }
        .chartForegroundStyleScale([lastMonth: Color.secondary, thisMonth: Color.accentColor, forecastLabel: Color.orange])
        .chartXScale(domain: 1...31)
        .chartXAxis { AxisMarks(values: [1, 5, 10, 15, 20, 25, 31]) }
        .chartLegend(position: .bottom, alignment: .leading)
    }

    // MARK: Tables

    private func serviceTable(series: [Series], today: Day) -> some View {
        let month = today.calendarMonth
        let rows = series.map { item in
            (item: item,
             comparison: SpendTrends.comparison(item.ledger, days: days, today: today),
             soFar: SpendTrends.monthToDate([item.ledger], today: today),
             forecast: item.ledger.forecast(today: today))
        }.sorted { ($0.comparison.current.decimal ?? -1) > ($1.comparison.current.decimal ?? -1) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("By service").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Service").gridColumnAlignment(.leading)
                    Text("Last \(days) days")
                    Text("Previous \(days)")
                    Text("Change")
                    Text("Month so far")
                    Text("Forecast")
                }
                .font(.caption.weight(.semibold))
                Divider()
                ForEach(rows, id: \.item.service.id) { row in
                    let approximate = row.item.service.spendIsEstimate
                    GridRow {
                        Text(row.item.service.name).lineLimit(1).gridColumnAlignment(.leading)
                        AmountText(amount: row.comparison.current, approximate: approximate)
                        AmountText(amount: row.comparison.previous, approximate: approximate)
                        ChangeBadge(change: row.comparison.change)
                        AmountText(amount: row.soFar, approximate: row.item.service.isApproximate(in: month))
                        AmountText(amount: row.forecast, approximate: true)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func dayTable(range: [Day], totals: [Decimal?], series: [Series], today: Day) -> some View {
        let average = SpendTrends.movingAverage(totals, window: 7)
        return Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Day").gridColumnAlignment(.leading)
                Text("Total")
                Text("7-day average")
                Text("Largest").gridColumnAlignment(.leading)
            }
            .font(.caption.weight(.semibold))
            Divider()
            ForEach(Array(range.enumerated().reversed()), id: \.element) { index, day in
                let largest = series.compactMap { item in
                    item.ledger.spend(on: day, today: today).decimal.map {
                        (name: item.service.name, amount: $0, approximate: item.service.isApproximate(on: day, today: today))
                    }
                }.filter { $0.amount > 0 }.max { $0.amount < $1.amount }
                // The 7-day average contains an estimate when any of the days it averages does.
                let window = Array(range[max(0, index - 6)...index])
                GridRow {
                    Text(Format.day(day)).gridColumnAlignment(.leading)
                    AmountText(amount: totals[index].map(Amount.value) ?? .noData,
                               approximate: DailyHistory.Series.isApproximate(series, on: [day], today: today))
                    AmountText(amount: average[index].map(Amount.value) ?? .noData,
                               approximate: DailyHistory.Series.isApproximate(series, on: window, today: today))
                        .foregroundStyle(.secondary)
                    Text(largest.map { "\($0.name) · \(Format.usd($0.amount, approximate: $0.approximate))" } ?? "—")
                        .foregroundStyle(.secondary).lineLimit(1).gridColumnAlignment(.leading)
                }
            }
        }
        .font(.callout)
    }
}

/// One summary figure with a caption above and context below.
private struct Tile<Value: View, Footer: View>: View {
    let title: Text
    @ViewBuilder let value: Value
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            title.font(.caption).foregroundStyle(.secondary)
            value.font(.system(size: 22, weight: .semibold, design: .rounded))
            footer.font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A signed percent change; higher spend is orange, lower is green.
struct ChangeBadge: View {
    let change: Decimal?

    var body: some View {
        if let change {
            let rising = change > 0
            Label {
                Text(change.double.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false))))
                    .monospacedDigit()
            } icon: {
                Image(systemName: change == 0 ? "equal" : rising ? "arrow.up.right" : "arrow.down.right")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(change == 0 ? Color.secondary : rising ? Color.orange : Color.green)
        } else {
            Text(verbatim: "—").foregroundStyle(.secondary)
        }
    }
}

/// Hover details for one day of the daily chart.
private struct DayDetail: View {
    let day: Day
    let total: Decimal?
    let series: [DailyHistory.Series]
    let today: Day

    var body: some View {
        let parts = series.compactMap { item in
            item.ledger.spend(on: day, today: today).decimal.map {
                (name: item.name, amount: $0, approximate: item.service.isApproximate(on: day, today: today))
            }
        }.filter { $0.amount != 0 }.sorted { $0.amount > $1.amount }
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.day(day)).font(.caption.weight(.semibold))
            AmountText(amount: total.map(Amount.value) ?? .noData, approximate: parts.contains { $0.approximate })
                .font(.callout.weight(.semibold))
            ForEach(parts.prefix(6), id: \.name) { part in
                HStack {
                    Text(part.name)
                    Spacer(minLength: 12)
                    Text(Format.usd(part.amount, approximate: part.approximate)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

extension Decimal {
    var double: Double { NSDecimalNumber(decimal: self).doubleValue }
}

extension Amount {
    func dividedBy(_ count: Int) -> Amount {
        guard let value = decimal, count > 0 else { return self }
        return .value(value / Decimal(count))
    }
}
