import Charts
import SwiftUI

/// The page of one tag: its spend over the last 12 months, split by tracked service, and the monthly amounts of every
/// tagged target (REQ-023, DEC-042). A tag applies to every month, whenever it was assigned.
struct TagDetailView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Route?
    let tag: String
    @State private var editing: TagEditRequest?

    var body: some View {
        let history = model.tagHistory.first { $0.tag.lowercased() == tag.lowercased() }
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Button { selection = .tags } label: {
                        Label("Tags", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                if let history {
                    summary(history)
                } else {
                    // The last assignment of the tag was removed while its page was open.
                    Text("No tags yet").foregroundStyle(.secondary)
                }
            }
            if let history {
                Section("Month by month") {
                    TagMonthChart(history: history)
                    Text("◇ marks a month without a total (unavailable or no data). Faded bars are approximate (≈).")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) { TagMonthTable(history: history) }
                }
                if !history.targets.isEmpty {
                    Section("Items by month") {
                        ScrollView(.horizontal, showsIndicators: false) { TagTargetTable(history: history) }
                    }
                }
                Section {
                    ForEach(history.targets) { series in
                        TagMemberRow(member: series.member, history: series.costs,
                                     open: { if let route = model.route(opening: series.member) { selection = route } },
                                     edit: { edit(series.member) })
                    }
                } header: {
                    Text("Tagged items")
                } footer: {
                    Text("A tag applies to every month, whenever it was assigned. Months before an item's data begins have no data, and items without a cost in a month are left out of that month's total.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(tag)
        .sheet(item: $editing) { request in
            if let service = model.store.service(id: request.serviceID) {
                TagsForm(service: service, target: request.target, name: request.name)
            }
        }
    }

    private func summary(_ history: TagHistory) -> some View {
        Group {
            HStack { TagChip(tag: history.tag); Spacer() }
            LabeledContent("This month") {
                TagPointText(point: history.latest).font(.title3.weight(.semibold))
            }
            LabeledContent("Last month") { TagPointText(point: history.previous) }
            LabeledContent("Last 12 months") {
                let approximate = history.points.contains { $0.total != nil && $0.isApproximate }
                Text(verbatim: Format.usd(history.knownSum, approximate: approximate)).monospacedDigit()
            }
            if history.monthsWithoutTotal > 0 {
                Text("Months without a total: \(history.monthsWithoutTotal)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func edit(_ member: TagTotal.Member) {
        guard let serviceID = member.serviceID else { return }
        editing = TagEditRequest(serviceID: serviceID, target: member.target, name: member.name)
    }
}

/// What a tag's month is: its amount, "unavailable" or "no data". They never look alike, and none of them is zero.
struct TagPointText: View {
    let point: TagHistory.Point?

    var body: some View {
        if let point, point.state == .amount, let total = point.total {
            Text(verbatim: Format.usd(total, approximate: point.isApproximate)).monospacedDigit()
        } else if point?.state == .unavailable {
            Text("unavailable").foregroundStyle(.secondary)
        } else {
            Text("no data").foregroundStyle(.secondary)
        }
    }
}

/// The last 12 months of one tag, stacked by tracked service. Approximate parts are lighter; a month without a total is
/// marked with a diamond instead of a bar, so it is never read as zero.
struct TagMonthChart: View {
    let history: TagHistory

    var body: some View {
        let months = history.points.map(\.month)
        Chart {
            ForEach(history.points) { point in
                if point.state == .amount {
                    ForEach(point.services, id: \.serviceName) { share in
                        BarMark(x: .value("Month", point.month.firstDay.date, unit: .month),
                                y: .value("USD", NSDecimalNumber(decimal: share.amount).doubleValue))
                            .foregroundStyle(by: .value("Service", share.serviceName))
                            .opacity(share.isEstimate ? 0.55 : 1)
                    }
                } else {
                    PointMark(x: .value("Month", point.month.firstDay.date, unit: .month), y: .value("USD", 0))
                        .symbol(.diamond)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .monthAxis(months)
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 240)
    }
}

/// Every month of the tag with the amount of each tracked service and the total, newest first.
struct TagMonthTable: View {
    let history: TagHistory

    var body: some View {
        let services = Array(Set(history.points.flatMap { $0.services.map(\.serviceName) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Month").font(.caption.weight(.semibold))
                ForEach(services, id: \.self) { name in
                    Text(verbatim: name).font(.caption.weight(.semibold)).lineLimit(1).gridColumnAlignment(.trailing)
                }
                Text("Total").font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
            }
            Divider()
            ForEach(history.points.reversed()) { point in
                GridRow {
                    Text(Format.monthLong(point.month))
                    ForEach(services, id: \.self) { name in
                        if let share = point.services.first(where: { $0.serviceName == name }) {
                            Text(verbatim: Format.usd(share.amount, approximate: share.isEstimate)).monospacedDigit()
                        } else {
                            Text(verbatim: "–").foregroundStyle(.secondary)
                        }
                    }
                    TagPointText(point: point).fontWeight(.semibold)
                }
            }
        }
        .font(.callout)
    }
}

/// The amount of every tagged item in every month, newest first. A month in which the item has no cost has no amount.
/// An item's own amount is shown even where its service already covers it in the total (as on the Tags tab).
struct TagTargetTable: View {
    let history: TagHistory

    var body: some View {
        let targets = history.targets
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Month").font(.caption.weight(.semibold))
                ForEach(targets) { series in
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(verbatim: series.member.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(verbatim: series.member.serviceName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .gridColumnAlignment(.trailing)
                }
            }
            Divider()
            ForEach(history.points.reversed()) { point in
                GridRow {
                    Text(Format.monthLong(point.month))
                    ForEach(targets) { series in
                        // The month's own record of the item carries that month's estimate flag.
                        if let member = point.members.first(where: { $0.id == series.id }), let cost = member.cost {
                            Text(verbatim: Format.usd(cost, approximate: member.costIsEstimate)).monospacedDigit()
                        } else {
                            Text(verbatim: "–").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .font(.callout)
    }
}

/// A small bar chart of one target's amounts over the months; a month without a cost has no bar.
struct MonthSparkline: View {
    let costs: [Decimal?]

    var body: some View {
        Chart(Array(costs.enumerated()), id: \.offset) { index, cost in
            if let cost {
                BarMark(x: .value("Month", index), y: .value("USD", NSDecimalNumber(decimal: cost).doubleValue))
            }
        }
        .chartXScale(domain: -1...costs.count)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(width: 96, height: 22)
        .accessibilityHidden(true)
    }
}

/// One line per tag over the last 12 months, for the Tags tab (REQ-024). The lines are not stacked: the totals of
/// different tags may overlap. A month without a total is a gap, never a zero.
struct TagsOverTimeChart: View {
    let histories: [TagHistory]

    /// A line is cut at every month without a total, so that it does not run across the gap.
    private struct Segment: Identifiable {
        let tag: String
        let index: Int
        let points: [TagHistory.Point]
        var id: String { "\(tag)#\(index)" }
    }

    private var segments: [Segment] {
        histories.flatMap { history -> [Segment] in
            var result: [Segment] = []
            var current: [TagHistory.Point] = []
            for point in history.points {
                if point.total != nil {
                    current.append(point)
                } else if !current.isEmpty {
                    result.append(Segment(tag: history.tag, index: result.count, points: current))
                    current = []
                }
            }
            if !current.isEmpty { result.append(Segment(tag: history.tag, index: result.count, points: current)) }
            return result
        }
    }

    var body: some View {
        let months = histories.first?.points.map(\.month) ?? []
        Chart {
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(x: .value("Month", point.month.firstDay.date, unit: .month),
                             y: .value("USD", NSDecimalNumber(decimal: point.total ?? 0).doubleValue),
                             series: .value("Line", segment.id))
                        .foregroundStyle(by: .value("Tag", segment.tag))
                    PointMark(x: .value("Month", point.month.firstDay.date, unit: .month),
                              y: .value("USD", NSDecimalNumber(decimal: point.total ?? 0).doubleValue))
                        .foregroundStyle(by: .value("Tag", segment.tag))
                        .symbolSize(18)
                }
            }
        }
        .monthAxis(months)
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 200)
    }
}
