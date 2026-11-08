import SwiftUI

/// Tagged services, keys and provider items with their current-month spend, per tag across services (REQ-019, REQ-020).
struct TagsView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Route?
    @State private var editing: TagEditRequest?

    var body: some View {
        let totals = model.tagTotals
        // Only tags with at least one known monthly total get a line (REQ-024).
        let charted = model.tagHistory.filter { history in history.points.contains { $0.total != nil } }
        Group {
            if totals.isEmpty {
                ContentUnavailableView {
                    Label("No tags yet", systemImage: "tag")
                } description: {
                    Text("Tag a service, a key or a breakdown row, e.g. by project or client. Each tag's spend is summed here across services.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    if !charted.isEmpty {
                        Section {
                            TagsOverTimeChart(histories: charted)
                        } header: {
                            Text("Tags over time")
                        } footer: {
                            Text("Tag totals can overlap, so the lines are not added up.")
                        }
                    }
                    ForEach(totals) { total in
                        Section {
                            ForEach(total.members) { member in
                                TagMemberRow(member: member, open: { open(member) }, edit: { edit(member) })
                            }
                        } header: {
                            // The header opens the page of the tag with its history (REQ-023).
                            Button { selection = .tag(total.tag) } label: {
                                HStack {
                                    TagChip(tag: total.tag)
                                    Spacer()
                                    if let sum = total.total {
                                        Text(verbatim: (total.isApproximate ? "≈ " : "") + Format.usd(sum)).font(.headline).monospacedDigit()
                                    } else {
                                        Text("unavailable").font(.headline).foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } footer: {
                            if !total.unresolvedServices.isEmpty {
                                Text("The tagged costs in \(total.unresolvedServices.joined(separator: ", ")) may overlap, so this total is not shown. Each item shows its own amount.")
                            } else if total.hasUnavailable {
                                Text("Items without a cost this month are not included in the total.")
                            }
                        }
                    }
                    Text("This month").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $editing) { request in
            if let service = model.store.service(id: request.serviceID) {
                TagsForm(service: service, target: request.target, name: request.name)
            }
        }
    }

    private func open(_ member: TagTotal.Member) {
        if let route = model.route(opening: member) { selection = route }
    }

    private func edit(_ member: TagTotal.Member) {
        guard let serviceID = member.serviceID else { return }
        editing = TagEditRequest(serviceID: serviceID, target: member.target, name: member.name)
    }
}

/// Asks the Tags view to open the tag editor of one listed target, which may be missing from the provider's data.
struct TagEditRequest: Identifiable {
    let serviceID: UUID
    let target: TagTarget
    let name: String
    var id: String { "\(serviceID)|\(target.kind.rawValue)|\(target.scope)|\(target.reference)" }
}

extension AppModel {
    /// Where opening a tagged target goes: a key its page, a breakdown row or Neon project its section of the service
    /// page (which is asked to scroll there), anything else, including a target that is missing now, the service page (REQ-019).
    func route(opening member: TagTotal.Member) -> Route? {
        guard let serviceID = member.serviceID else { return nil }
        switch member.destination {
        case .key(let id): return .key(service: serviceID, key: id)
        case .breakdownSection:
            pendingServiceSection = .breakdown
            return .service(serviceID)
        case .usageSection:
            pendingServiceSection = .usage
            return .service(serviceID)
        case .service: return .service(serviceID)
        }
    }
}

/// One tagged target: its name, type and parent service, and its current-month amount or "unavailable". With `history`
/// (its amount in each of the last months) a small chart of those months is drawn before the amount.
struct TagMemberRow: View {
    let member: TagTotal.Member
    var history: [Decimal?]?
    let open: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: member.name)
                        HStack(spacing: 4) {
                            Text(member.target.typeTitle)
                            if member.target.kind != .service {
                                Text(verbatim: "·")
                                Text(verbatim: member.serviceName)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if !member.isPresent {
                            Text("Not listed this month").font(.caption).foregroundStyle(.orange)
                        } else if member.isCoveredByService {
                            Text("Included in the tagged service").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let history, history.contains(where: { $0 != nil }) { MonthSparkline(costs: history) }
                    amount
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: edit) { Image(systemName: "tag") }
                .buttonStyle(.borderless)
                .help(Text("Edit tags…"))
                .accessibilityLabel(Text("Edit tags…"))
        }
        .font(.callout)
    }

    @ViewBuilder private var amount: some View {
        if let cost = member.cost {
            // An amount that is not added (covered by the tagged service, or part of an unresolved overlap) is dimmed.
            Text(verbatim: (member.costIsEstimate ? "≈ " : "") + Format.usd(cost)).monospacedDigit()
                .foregroundStyle(member.isCounted ? .primary : .secondary)
        } else {
            Text("unavailable").foregroundStyle(.secondary)
        }
    }
}

private struct LargeLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Enlarges charts and lists in the main window (DEC-029).
    var isLargeLayout: Bool {
        get { self[LargeLayoutKey.self] }
        set { self[LargeLayoutKey.self] = newValue }
    }
}
