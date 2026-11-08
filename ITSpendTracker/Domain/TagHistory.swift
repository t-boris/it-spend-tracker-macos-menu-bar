import Foundation

/// The spend of one tag over the last months (REQ-023, REQ-024, DEC-042). Every month is calculated by the same rules
/// as the current month (`TagTotal.compute`: nothing is counted twice, an unresolved overlap makes the month's total
/// unavailable), from that month's data. A tag applies to every month: an assignment has no start date.
struct TagHistory: Identifiable, Equatable, Sendable {
    /// The same range as the history page.
    static let monthsShown = 12

    /// The last `monthsShown` months, oldest first, ending with `current`.
    static func months(endingAt current: Month) -> [Month] {
        current.adding(months: -(monthsShown - 1)).through(current)
    }

    /// What the tag's amount in a month is, so that "unavailable", "no data" and zero never look alike.
    enum State: Equatable, Sendable {
        /// The total is known; it may be zero.
        case amount
        /// Tagged costs of a service may overlap and the data cannot tell, so no total is shown (DEC-034).
        case unavailable
        /// Nothing is known about the tag in this month: no target reports a cost.
        case noData
    }

    /// The part of one tracked service in a tag's month; the parts of different services never overlap.
    struct ServiceShare: Equatable, Sendable {
        var serviceName: String
        var amount: Decimal
        var isEstimate: Bool
    }

    struct Point: Identifiable, Equatable, Sendable {
        var month: Month
        var state: State
        /// The tag's total in the month; `nil` unless the state is `.amount`.
        var total: Decimal?
        /// Part of the total is an estimate (≈).
        var isApproximate: Bool
        /// The amounts that make up the total, per tracked service, ordered by name. Present in every state, so an
        /// unavailable month can still show what is known.
        var services: [ServiceShare]
        /// Services whose tagged targets may overlap; not empty exactly when the state is `.unavailable`.
        var unresolvedServices: [String]
        /// Some tagged target has no cost in the month, so the total leaves it out.
        var hasUnavailableTargets: Bool
        /// Every tagged target with what is known about it in the month (its amount, whether it is counted).
        var members: [TagTotal.Member]
        var id: Int { month.index }
    }

    var tag: String
    /// One point for every month asked for, oldest first.
    var points: [Point]
    var id: String { tag }

    var latest: Point? { points.last }
    /// The month before the latest one.
    var previous: Point? { points.dropLast().last }
    /// Sum of the months whose total is known.
    var knownSum: Decimal { points.compactMap(\.total).reduce(0, +) }
    /// Months without a known total (unavailable or no data).
    var monthsWithoutTotal: Int { points.filter { $0.total == nil }.count }

    /// The history of every tag that has an assignment, for `months` (oldest first). `inputs` returns what each tracked
    /// service knows about the given month. Tags are matched case-insensitively and keep the spelling they have in the
    /// newest month; the result is ordered by the newest month's total, like the Tags tab.
    static func compute(months: [Month], inputs: (Month) -> [TagServiceInput]) -> [TagHistory] {
        var spelling: [String: String] = [:]
        var points: [String: [Point]] = [:]
        var order: [String] = []
        for month in months {
            for total in TagTotal.compute(inputs(month)) {
                let id = total.tag.lowercased()
                if points[id] == nil { order.append(id) }
                spelling[id] = total.tag
                points[id, default: []].append(point(for: total, in: month))
            }
        }
        let histories = order.map { TagHistory(tag: spelling[$0] ?? $0, points: points[$0] ?? []) }
        return histories.sorted {
            let (left, right) = ($0.latest?.total, $1.latest?.total)
            if left != right { return (left ?? -1) > (right ?? -1) }
            return $0.tag.localizedStandardCompare($1.tag) == .orderedAscending
        }
    }

    private static func point(for total: TagTotal, in month: Month) -> Point {
        let counted = total.members.filter(\.isCounted)
        let state: State = total.total == nil ? .unavailable : (counted.isEmpty ? .noData : .amount)
        // Grouped like `TagTotal` does it, by the tracked service and not by its name, which two services may share.
        let shares = Dictionary(grouping: counted) { $0.serviceID?.uuidString ?? $0.serviceName }.values.map { members in
            ServiceShare(serviceName: members[0].serviceName, amount: members.compactMap(\.cost).reduce(0, +),
                         isEstimate: members.contains { $0.costIsEstimate })
        }
        .sorted { $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending }
        return Point(month: month, state: state, total: state == .amount ? total.total : nil,
                     isApproximate: total.isApproximate, services: shares, unresolvedServices: total.unresolvedServices,
                     hasUnavailableTargets: total.hasUnavailable, members: total.members)
    }
}
