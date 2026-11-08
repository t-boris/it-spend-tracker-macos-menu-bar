import Foundation

/// A tagged target as the current month's data shows it (REQ-020). The cost belongs to that month only.
struct TagTargetState: Equatable, Sendable {
    var target: TagTarget
    var name: String
    /// `nil` when the provider reports no cost for the target this month.
    var cost: Decimal?
    var costIsEstimate = false
}

/// The tags assigned to one target (REQ-018).
struct TagAssignment: Equatable, Sendable {
    var target: TagTarget
    /// Name kept from the last edit; shown only while the target is missing (DEC-037).
    var displayName: String
    var tags: [String]
}

/// What the tag totals need to know about one tracked service for one month.
struct TagServiceInput: Sendable {
    var serviceID: UUID? = nil
    var serviceName: String
    /// The service's spend in the month from the existing ledger calculation; `nil` when there is no data.
    var spend: Decimal?
    var spendIsEstimate = false
    /// Keys, breakdown items and usage projects that exist now, with this month's cost.
    var present: [TagTargetState]
    var assignments: [TagAssignment]
}

/// Current-month spend per user tag across services (REQ-019, REQ-020, DEC-024 of the first release).
struct TagTotal: Identifiable, Equatable, Sendable {
    struct Member: Identifiable, Equatable, Sendable {
        var serviceID: UUID? = nil
        var serviceName: String
        var target: TagTarget
        /// The live name while the target exists, the stored one once it is missing.
        var name: String
        /// `false` when the provider no longer lists the target; its cost is then unavailable (REQ-018).
        var isPresent: Bool
        /// `nil` when unavailable: missing target, or the provider reports no cost for it.
        var cost: Decimal?
        var costIsEstimate = false
        /// Whether `cost` is part of the tag's total.
        var isCounted = false
        /// The tagged service of the same tag already contains this cost, so it is shown but not added (REQ-020).
        var isCoveredByService = false

        var id: String { "\(serviceID?.uuidString ?? serviceName)|\(target.kind.rawValue)|\(target.scope)|\(target.reference)" }

        /// Where opening this row goes (REQ-019). A target the provider no longer lists has no page of its own, so it
        /// opens its parent service.
        enum Destination: Equatable {
            case service
            case key(String)
            case breakdownSection
            case usageSection
        }

        var destination: Destination {
            guard isPresent else { return .service }
            switch target.kind {
            case .service: return .service
            case .key: return .key(target.reference)
            case .breakdownItem: return .breakdownSection
            case .usageProject: return .usageSection
            }
        }

        /// Costs in one class are provably disjoint from each other; costs in different classes may be the same money
        /// seen from two sides (DEC-035).
        fileprivate var disjointClass: String {
            switch target.kind {
            case .service: "service"
            case .key: "key"
            case .breakdownItem: "item:" + target.scope
            case .usageProject: "usage"
            }
        }

        fileprivate var groupKey: String { serviceID?.uuidString ?? serviceName }

        fileprivate var sortRank: Int {
            switch target.kind {
            case .service: 0
            case .key: 1
            case .breakdownItem: 2
            case .usageProject: 3
            }
        }
    }

    var tag: String
    var members: [Member]
    /// Sum of the counted members; `nil` when some service's tagged targets may overlap and the data cannot tell (DEC-034).
    var total: Decimal?
    /// Services whose part of this tag cannot be resolved, which is why `total` is `nil`.
    var unresolvedServices: [String] = []
    var id: String { tag }

    var hasUnavailable: Bool { members.contains { $0.cost == nil } }
    var isApproximate: Bool { members.contains { $0.isCounted && $0.costIsEstimate } }

    /// Groups the assignments of every service by tag (case-insensitive), sorted by total descending, then name.
    static func compute(_ services: [TagServiceInput]) -> [TagTotal] {
        var byTag: [String: TagTotal] = [:]
        for service in services {
            var present: [TagTarget: TagTargetState] = [:]
            for state in service.present where present[state.target] == nil { present[state.target] = state }
            for assignment in service.assignments {
                let member = resolve(assignment, in: service, present: present)
                for tag in assignment.tags {
                    let id = tag.lowercased()
                    var entry = byTag[id] ?? TagTotal(tag: tag, members: [], total: 0)
                    entry.members.append(member)
                    byTag[id] = entry
                }
            }
        }
        return byTag.values.map { $0.settled() }.sorted {
            ($0.total ?? -1) != ($1.total ?? -1) ? ($0.total ?? -1) > ($1.total ?? -1)
                : $0.tag.localizedStandardCompare($1.tag) == .orderedAscending
        }
    }

    /// One assignment against the month's data. A target that is not listed now keeps its stored name and has no cost:
    /// last month's figure is never reused as this month's (REQ-018).
    private static func resolve(_ assignment: TagAssignment, in service: TagServiceInput,
                                present: [TagTarget: TagTargetState]) -> Member {
        if assignment.target.kind == .service {
            return Member(serviceID: service.serviceID, serviceName: service.serviceName, target: .service,
                          name: service.serviceName, isPresent: true, cost: service.spend,
                          costIsEstimate: service.spendIsEstimate)
        }
        if let state = present[assignment.target] {
            return Member(serviceID: service.serviceID, serviceName: service.serviceName, target: state.target,
                          name: state.name, isPresent: true, cost: state.cost, costIsEstimate: state.costIsEstimate)
        }
        return Member(serviceID: service.serviceID, serviceName: service.serviceName, target: assignment.target,
                      name: assignment.displayName, isPresent: false, cost: nil)
    }

    /// Orders the members and works out which of them make up the total, one tracked service at a time (REQ-020):
    /// - a tagged service contributes its spend once and covers every other tagged target of that service;
    /// - otherwise the targets with a known cost are added only when they are provably disjoint (one class, DEC-035);
    /// - if they are not, the service is unresolved and the whole tag's total is unavailable (DEC-034).
    /// Targets without a cost are listed but take no part in any of this. Different services never overlap.
    private func settled() -> TagTotal {
        var result = self
        result.members.sort {
            if $0.serviceName != $1.serviceName { return $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending }
            if $0.sortRank != $1.sortRank { return $0.sortRank < $1.sortRank }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        var unresolved: [String] = []
        let groups = Dictionary(grouping: result.members.indices) { result.members[$0].groupKey }
        for indices in groups.values.sorted(by: { $0[0] < $1[0] }) {
            if let service = indices.first(where: { result.members[$0].target.kind == .service }) {
                for index in indices where index != service { result.members[index].isCoveredByService = true }
                result.members[service].isCounted = result.members[service].cost != nil
            } else {
                let costed = indices.filter { result.members[$0].cost != nil }
                if Set(costed.map { result.members[$0].disjointClass }).count > 1 {
                    unresolved.append(result.members[indices[0]].serviceName)
                } else {
                    for index in costed { result.members[index].isCounted = true }
                }
            }
        }
        result.unresolvedServices = unresolved
        result.total = unresolved.isEmpty ? result.members.filter(\.isCounted).compactMap(\.cost).reduce(0, +) : nil
        return result
    }
}
