import Foundation

/// The provider facts on a key page, in display order. Each one has its values or is missing; a missing one is shown
/// as "unavailable": never left out and never shown as zero (REQ-016).
struct KeyFacts: Equatable {
    enum Field: Equatable, CaseIterable {
        case project, maskedValue, owner, status, scopes

        /// Detail kinds that count as this fact; empty for the facts that are plain fields of the key.
        var kinds: [KeyDetail.Kind] {
            switch self {
            case .project: [.project]
            case .owner: [.owner, .ownerEmail, .ownerRole, .ownerType, .createdBy]
            case .scopes: [.scopes, .origin, .keyType]
            case .maskedValue, .status: []
            }
        }
    }

    struct Row: Equatable {
        var field: Field
        /// Provider details for this fact (project, owner, scopes rows).
        var details: [KeyDetail]
        /// Value of a plain field (masked key, status).
        var text: String?
        var isAvailable: Bool { !details.isEmpty || text != nil }
    }

    var rows: [Row]

    init(hint: String?, status: String?, details: [KeyDetail]) {
        rows = Field.allCases.map { field in
            switch field {
            case .maskedValue: Row(field: field, details: [], text: hint?.nilIfEmpty)
            case .status: Row(field: field, details: [], text: status?.nilIfEmpty)
            default: Row(field: field, details: details.filter { field.kinds.contains($0.kind) }, text: nil)
            }
        }
    }

    /// The facts the provider does not report.
    var unavailable: [Field] { rows.filter { !$0.isAvailable }.map(\.field) }
}
