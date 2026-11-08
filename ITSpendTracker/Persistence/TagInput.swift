import Foundation

extension TrackedService {
    /// This service's tags and tagged targets as the data of `month` shows them (REQ-020, DEC-025).
    ///
    /// Only rows of `month` count, so a key, breakdown item or project that has no row now has no cost; an earlier
    /// month's figure is never reused (REQ-018). Whether the service is included in the main total is irrelevant here.
    func tagInput(in month: Month) -> TagServiceInput {
        let assignments = tagAssignments.compactMap { record in
            record.target.map { TagAssignment(target: $0, displayName: record.displayName, tags: record.tags) }
        }
        guard !assignments.isEmpty else {
            return TagServiceInput(serviceID: id, serviceName: name, spend: nil, present: [], assignments: [])
        }
        let sections = ServiceSections(isConnected: isConnected,
                                       hasUsageMetrics: connector?.descriptor.capabilities.usageMetrics == true)
        var present: [TagTargetState] = []

        let availability = KeyFieldAvailability(service: self)
        for key in keys {
            present.append(TagTargetState(target: .key(key.externalID), name: key.name,
                                          cost: availability.spend ? key.monthCost(in: month) : nil,
                                          costIsEstimate: availability.spendIsEstimate))
        }

        // Breakdown rows exist for the month only when the connector's coverage starts at or before it.
        if sections.breakdown, breakdownStartMonthIndex.map({ month.index >= $0 }) == true {
            for row in breakdown where row.monthIndex == month.index {
                guard let dimension = BreakdownDimension(rawValue: row.dimensionRaw) else { continue }
                present.append(TagTargetState(target: .breakdownItem(dimension: dimension, label: row.label), name: row.label,
                                              cost: row.amount, costIsEstimate: spendIsEstimate))
            }
        }

        // A Neon project's cost is the ≈ sum of its metrics' approximate costs, always marked ≈ (DEC-025).
        if sections.usageMetrics, usageMetricsStartMonthIndex.map({ month.index >= $0 }) == true {
            let several = Set(usageMetrics.compactMap(\.organization)).count > 1
            let rows = Dictionary(grouping: usageMetrics.filter { $0.monthIndex == month.index }) {
                TagTarget.usageProject(organization: $0.organization, name: $0.project)
            }
            for (target, records) in rows.sorted(by: { $0.key.reference < $1.key.reference }) {
                let costs = records.compactMap(\.approximateCost)
                present.append(TagTargetState(target: target, name: records[0].label(showingOrganization: several),
                                              cost: costs.isEmpty ? nil : costs.reduce(0, +), costIsEstimate: true))
            }
        }

        return TagServiceInput(serviceID: id, serviceName: name, spend: ledger.spend(in: month).decimal,
                               spendIsEstimate: isApproximate(in: month), present: present, assignments: assignments)
    }
}
