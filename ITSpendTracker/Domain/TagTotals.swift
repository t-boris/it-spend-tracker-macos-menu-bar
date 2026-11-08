import Foundation

/// Current-month spend per user tag across services (DEC-024, REQ-013).
struct TagTotal: Identifiable, Equatable, Sendable {
    struct Member: Equatable, Sendable {
        var serviceID: UUID? = nil
        var keyExternalID: String = ""
        var serviceName: String
        var keyName: String
        /// `nil` when the provider does not expose per-key spend.
        var cost: Decimal?
        var costIsEstimate: Bool = false
    }

    var tag: String
    var members: [Member]
    var id: String { tag }

    /// Sum of the members whose cost is known.
    var total: Decimal { members.compactMap(\.cost).reduce(0, +) }
    var hasUnavailable: Bool { members.contains { $0.cost == nil } }
    var isApproximate: Bool { members.contains { $0.cost != nil && $0.costIsEstimate } }

    struct TaggedKey: Sendable {
        var serviceID: UUID? = nil
        var keyExternalID: String = ""
        var serviceName: String
        var keyName: String
        var cost: Decimal?
        var costIsEstimate: Bool = false
        var tags: [String]
    }

    /// Groups tagged keys by tag (case-insensitive), sorted by total descending, then name.
    static func compute(_ keys: [TaggedKey]) -> [TagTotal] {
        var byTag: [String: TagTotal] = [:]
        for key in keys {
            for tag in key.tags {
                let id = tag.lowercased()
                var entry = byTag[id] ?? TagTotal(tag: tag, members: [])
                entry.members.append(Member(serviceID: key.serviceID, keyExternalID: key.keyExternalID,
                                            serviceName: key.serviceName, keyName: key.keyName, cost: key.cost,
                                            costIsEstimate: key.costIsEstimate))
                byTag[id] = entry
            }
        }
        return byTag.values.sorted {
            $0.total != $1.total ? $0.total > $1.total : $0.tag.localizedStandardCompare($1.tag) == .orderedAscending
        }
    }
}
