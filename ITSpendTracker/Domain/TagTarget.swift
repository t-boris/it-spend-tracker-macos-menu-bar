import Foundation

/// What a tag is attached to inside one tracked service (REQ-017, REQ-018, DEC-036).
///
/// Identity never contains the month, so an assignment survives refreshes and month changes. The tracked service is
/// part of the identity too, through the record that owns the assignment.
struct TagTarget: Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// The tracked service as a whole, including manual services.
        case service
        /// A key, identified by the provider's key ID.
        case key
        /// A breakdown row, identified by its dimension and exact label.
        case breakdownItem
        /// A Neon project, identified by organization and project name (DEC-025).
        case usageProject
    }

    var kind: Kind
    /// Breakdown dimension (breakdown item) or organization (usage project); empty otherwise.
    var scope: String
    /// Provider key ID, exact label or project name; empty for the service itself.
    var reference: String

    static let service = TagTarget(kind: .service, scope: "", reference: "")

    static func key(_ externalID: String) -> TagTarget {
        TagTarget(kind: .key, scope: "", reference: externalID)
    }

    static func breakdownItem(dimension: BreakdownDimension, label: String) -> TagTarget {
        TagTarget(kind: .breakdownItem, scope: dimension.rawValue, reference: label)
    }

    /// `organization` is `nil` for records saved before it was stored; such a project has an empty scope.
    static func usageProject(organization: String?, name: String) -> TagTarget {
        TagTarget(kind: .usageProject, scope: organization ?? "", reference: name)
    }

    /// The breakdown dimension of a breakdown item.
    var dimension: BreakdownDimension? {
        kind == .breakdownItem ? BreakdownDimension(rawValue: scope) : nil
    }
}

extension Array where Element == String {
    /// Trims, drops empty entries and de-duplicates case-insensitively, keeping entry order (AC-002).
    func cleanedTags() -> [String] {
        var seen = Set<String>()
        return map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
