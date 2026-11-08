import SwiftUI

/// Current-month spend per user tag across services (REQ-013).
struct TagsView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Route?

    var body: some View {
        let totals = model.tagTotals
        if totals.isEmpty {
            ContentUnavailableView {
                Label("No tags yet", systemImage: "tag")
            } description: {
                Text("Open a service and tag its keys, e.g. by project or client. Each tag's spend is summed here across services.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(totals) { total in
                    Section {
                        ForEach(Array(total.members.enumerated()), id: \.offset) { _, member in
                            Button {
                                if let serviceID = member.serviceID {
                                    selection = .key(service: serviceID, key: member.keyExternalID)
                                }
                            } label: {
                            HStack {
                                Text(member.keyName)
                                Text(member.serviceName).foregroundStyle(.secondary)
                                Spacer()
                                if let cost = member.cost {
                                    Text(verbatim: (member.costIsEstimate ? "≈ " : "") + Format.usd(cost)).monospacedDigit()
                                } else {
                                    Text("unavailable").foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .font(.callout)
                            .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            TagChip(tag: total.tag)
                            Spacer()
                            Text(verbatim: (total.isApproximate ? "≈ " : "") + Format.usd(total.total)).font(.headline).monospacedDigit()
                        }
                    } footer: {
                        if total.hasUnavailable {
                            Text("Keys without per-key spend from the provider are not included in the total.")
                        }
                    }
                }
                Text("This month").font(.caption).foregroundStyle(.secondary)
            }
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
