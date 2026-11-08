import Foundation

/// Usage cost grouped inside a service (DEC-027, REQ-015).
enum BreakdownDimension: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Model and cost type, e.g. "gpt-5, input".
    case lineItem
    /// Provider project / workspace / repository.
    case project
    /// Account or organization (GitHub, DEC-032).
    case account

    var id: String { rawValue }
}

struct BreakdownRow: Sendable, Equatable {
    var month: Month
    var dimension: BreakdownDimension
    var label: String
    var amount: Decimal
}

extension Array where Element == BreakdownRow {
    /// Sums rows with the same month, dimension and label.
    func merged() -> [BreakdownRow] {
        var sums: [String: BreakdownRow] = [:]
        var order: [String] = []
        for row in self {
            let key = "\(row.month)|\(row.dimension.rawValue)|\(row.label)"
            if var existing = sums[key] {
                existing.amount += row.amount
                sums[key] = existing
            } else {
                sums[key] = row
                order.append(key)
            }
        }
        return order.compactMap { sums[$0] }
    }
}

/// A usage quantity reported without money (Neon, DEC-031), already converted to its billing unit.
struct UsageMetricRow: Sendable, Equatable {
    var month: Month
    var project: String
    var metric: String
    var value: Decimal
    /// Provider plan for this project and period (Neon `period_plan`), used for the ≈ cost (DEC-033).
    var plan: String? = nil
}

extension Array where Element == UsageMetricRow {
    /// Sums rows with the same month, project and metric (e.g. daily buckets of one month).
    func merged() -> [UsageMetricRow] {
        var sums: [String: UsageMetricRow] = [:]
        var order: [String] = []
        for row in self {
            let key = "\(row.month)|\(row.project)|\(row.metric)"
            if var existing = sums[key] {
                existing.value += row.value
                existing.plan = existing.plan ?? row.plan
                sums[key] = existing
            } else {
                sums[key] = row
                order.append(key)
            }
        }
        return order.compactMap { sums[$0] }
    }
}

/// Known usage metrics: display order, unit and conversion from the provider's raw value (Neon docs).
enum UsageMetricKind: String, CaseIterable, Sendable {
    case computeUnitSeconds = "compute_unit_seconds"
    case rootBranchBytesMonth = "root_branch_bytes_month"
    case childBranchBytesMonth = "child_branch_bytes_month"
    case instantRestoreBytesMonth = "instant_restore_bytes_month"
    case snapshotStorageBytesMonth = "snapshot_storage_bytes_month"
    case publicNetworkTransferBytes = "public_network_transfer_bytes"
    case privateNetworkTransferBytes = "private_network_transfer_bytes"
    case extraBranchesMonth = "extra_branches_month"

    /// Raw value → billing unit: CU-seconds/3600, byte-months/10^9, bytes/10^9, branch-hours/744.
    var divisor: Decimal {
        switch self {
        case .computeUnitSeconds: 3600
        case .extraBranchesMonth: 744
        default: 1_000_000_000
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .computeUnitSeconds: "Compute"
        case .rootBranchBytesMonth: "Storage: root branches"
        case .childBranchBytesMonth: "Storage: child branches"
        case .instantRestoreBytesMonth: "Storage: instant restore"
        case .snapshotStorageBytesMonth: "Storage: snapshots"
        case .publicNetworkTransferBytes: "Public network transfer"
        case .privateNetworkTransferBytes: "Private network transfer"
        case .extraBranchesMonth: "Extra branches"
        }
    }

    var unit: LocalizedStringResource {
        switch self {
        case .computeUnitSeconds: "CU-hours"
        case .publicNetworkTransferBytes, .privateNetworkTransferBytes: "GB"
        case .extraBranchesMonth: "branch-months"
        default: "GB-months"
        }
    }
}

/// Neon's published rates (neon.com/docs/introduction/usage-calculations, 2026-09-30) for an approximate cost,
/// shown for orientation only and never counted as spend (DEC-033).
enum NeonPricing {
    /// Exact decimal from text; `Decimal` float literals go through `Double` and lose precision.
    private static func exact(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    struct Rates: Equatable, Sendable {
        var computePerCUHour: Decimal
        var storagePerGBMonth: Decimal = exact("0.35")
        var instantRestorePerGBMonth: Decimal = exact("0.20")
        var snapshotsPerGBMonth: Decimal = exact("0.09")
        var publicTransferPerGB: Decimal = exact("0.10")
        var includedPublicTransferGB: Decimal = 500
        var privateTransferPerGB: Decimal?
        var extraBranchPerMonth: Decimal = exact("1.50")
        var includedBranches: Decimal
    }

    static let launch = Rates(computePerCUHour: exact("0.106"), privateTransferPerGB: nil, includedBranches: 9)
    static let scale = Rates(computePerCUHour: exact("0.222"), privateTransferPerGB: exact("0.01"), includedBranches: 24)
    /// Agent: Launch compute rate, other rates as Scale.
    static let agent = Rates(computePerCUHour: exact("0.106"), privateTransferPerGB: exact("0.01"), includedBranches: 24)
    static let free = Rates(computePerCUHour: 0, storagePerGBMonth: 0, instantRestorePerGBMonth: 0, snapshotsPerGBMonth: 0,
                            publicTransferPerGB: 0, privateTransferPerGB: 0, extraBranchPerMonth: 0, includedBranches: 0)

    /// Rates for a Neon plan name (e.g. "launch", "scale_v2", "free_v3"); `nil` when unknown.
    static func rates(plan: String?) -> Rates? {
        guard let name = plan?.lowercased() else { return nil }
        if name.hasPrefix("free") { return free }
        if name.hasPrefix("launch") { return launch }
        if name.hasPrefix("agent") { return agent }
        if name.hasPrefix("scale") || name.hasPrefix("business") || name.hasPrefix("enterprise") { return scale }
        return nil
    }

    /// Approximate cost of one metric for one project and month, after that project's allowances.
    static func cost(metric: String, value: Decimal, plan: String?) -> Decimal? {
        guard let kind = UsageMetricKind(rawValue: metric), let rates = rates(plan: plan) else { return nil }
        switch kind {
        case .computeUnitSeconds: return value * rates.computePerCUHour
        case .rootBranchBytesMonth, .childBranchBytesMonth: return value * rates.storagePerGBMonth
        case .instantRestoreBytesMonth: return value * rates.instantRestorePerGBMonth
        case .snapshotStorageBytesMonth: return value * rates.snapshotsPerGBMonth
        case .publicNetworkTransferBytes: return max(0, value - rates.includedPublicTransferGB) * rates.publicTransferPerGB
        case .privateNetworkTransferBytes: return rates.privateTransferPerGB.map { value * $0 }
        case .extraBranchesMonth: return max(0, value - rates.includedBranches) * rates.extraBranchPerMonth
        }
    }
}

/// Approximate cost per API key (Google, DEC-036): a (project, service) month cost is split across the keys
/// that called that service in proportion to their request counts. Keys without requests get nothing.
enum KeyCostSplit {
    struct ServiceCost: Hashable, Sendable {
        var project: String
        var service: String
    }

    /// `requests[key][service]` → `[key: ≈ cost]`. `costs` keys are (project ID, service ID).
    static func split(costs: [ServiceCost: Decimal], requests: [String: [String: Int]],
                      keyProjects: [String: String]) -> [String: Decimal] {
        var result: [String: Decimal] = [:]
        for (entry, cost) in costs where cost != 0 {
            let callers = requests.compactMap { key, byService -> (String, Int)? in
                guard keyProjects[key] == entry.project, let count = byService[entry.service], count > 0 else { return nil }
                return (key, count)
            }
            let total = callers.reduce(0) { $0 + $1.1 }
            guard total > 0 else { continue }
            for (key, count) in callers {
                result[key, default: 0] += cost * Decimal(count) / Decimal(total)
            }
        }
        return result
    }
}
