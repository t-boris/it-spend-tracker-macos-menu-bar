import Charts
import SwiftUI

/// Everything known about one key (REQ-016, DEC-030): provider metadata, tags, cost history and token usage.
struct KeyDetailView: View {
    @Environment(AppModel.self) private var model
    let serviceID: UUID
    let keyID: String
    @Binding var selection: Route?
    @State private var editingTags = false

    var body: some View {
        if let service = model.store.service(id: serviceID),
           let key = service.keys.first(where: { $0.externalID == keyID }) {
            content(service: service, key: key)
                .sheet(isPresented: $editingTags) { KeyTagsForm(service: service, key: key) }
        } else {
            ContentUnavailableView("Key not found", systemImage: "key",
                                   description: Text("The provider no longer reports this key."))
        }
    }

    private func content(service: TrackedService, key: KeyRecord) -> some View {
        let availability = KeyFieldAvailability(service: service)
        let today = model.today
        let month = today.calendarMonth
        let serviceUsage = service.ledger.usage(in: month).decimal
        return Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Button { selection = .service(service.id) } label: {
                        Label(service.name, systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                LabeledContent("This month") {
                    if availability.spend, let cost = key.currentMonthCost {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(verbatim: (availability.spendIsEstimate ? "≈ " : "") + Format.usd(cost))
                                .font(.title3.weight(.semibold)).monospacedDigit()
                            if let serviceUsage, serviceUsage > 0 {
                                Text("\(Self.percent(cost / serviceUsage)) of \(service.name) usage")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("unavailable").foregroundStyle(.secondary)
                    }
                }
                if service.connector?.descriptor.capabilities.keyRequests == true {
                    LabeledContent("Requests this month") {
                        if let requests = key.requestsThisMonth {
                            Text(requests.formatted()).monospacedDigit()
                        } else {
                            Text("unavailable").foregroundStyle(.secondary)
                        }
                    }
                }
                if availability.spendIsEstimate, key.currentMonthCost != nil {
                    Label("Approximate: this project's cost per Google service is split across its keys by their share of requests. Requests differ in size, so this is an estimate.",
                          systemImage: "equal.circle").font(.caption).foregroundStyle(.secondary)
                }
                if WarningRules.isExpiringSoon(expiresAt: key.expiresAt, now: Date()) {
                    Label("Expires within 14 days", systemImage: "key.fill").foregroundStyle(.orange)
                }
                if let url = key.consoleURL ?? service.connector?.keysConsoleURL {
                    Link(destination: url) { Label("Open in provider console", systemImage: "arrow.up.right.square") }
                }
            } header: {
                Text(key.name).font(.title2.weight(.semibold)).foregroundStyle(.primary)
            }

            Section("Key") {
                LabeledContent("Service", value: service.name)
                LabeledContent("ID") { Text(key.externalID).font(.callout.monospaced()).textSelection(.enabled) }
                ForEach(KeyFacts(hint: key.hint, status: key.status, details: key.details).rows, id: \.field.rawValue) { row in
                    factRow(row)
                }
                dateRow("Created", available: key.createdAt != nil, date: key.createdAt, emptyText: "unavailable")
                dateRow("Last used", available: availability.lastUsed, date: key.lastUsedAt, emptyText: "never")
                dateRow("Expires", available: availability.expiry, date: key.expiresAt, emptyText: "no expiry")
            }

            Section("Tags") {
                HStack {
                    let tags = service.tags(forKey: key.externalID)
                    if tags.isEmpty {
                        Text("No tags").foregroundStyle(.secondary)
                    } else {
                        ForEach(tags, id: \.self) { TagChip(tag: $0) }
                    }
                    Spacer()
                    Button(tags.isEmpty ? "Add tag…" : "Edit tags…") { editingTags = true }
                }
            }

            Section("Cost by month") {
                KeyCostHistory(service: service, keyID: key.externalID, available: availability.spend, today: today)
            }

            Section("Token usage this month") {
                KeyTokenUsage(service: service, keyID: key.externalID)
            }
        }
        .formStyle(.grouped)
    }

    /// A provider fact of the key: its values, or "unavailable" when the provider does not report it (REQ-016).
    @ViewBuilder
    private func factRow(_ row: KeyFacts.Row) -> some View {
        switch row.field {
        case .maskedValue:
            LabeledContent("Key") {
                if let text = row.text {
                    Text(OpenAIConnector.compactRedacted(text)).font(.callout.monospaced()).textSelection(.enabled)
                } else {
                    Text("unavailable").foregroundStyle(.secondary)
                }
            }
        case .status:
            LabeledContent("Status") {
                if let text = row.text { Text(text) } else { Text("unavailable").foregroundStyle(.secondary) }
            }
        case .project, .owner, .scopes:
            if row.details.isEmpty {
                LabeledContent(row.field.title) { Text("unavailable").foregroundStyle(.secondary) }
            } else {
                ForEach(Array(row.details.enumerated()), id: \.offset) { _, detail in
                    LabeledContent { Text(detail.value).textSelection(.enabled) } label: { Text(detail.kind.title) }
                }
            }
        }
    }

    private func dateRow(_ title: LocalizedStringKey, available: Bool, date: Date?, emptyText: LocalizedStringKey) -> some View {
        LabeledContent(title) {
            if !available {
                Text("unavailable").foregroundStyle(.secondary)
            } else if let date {
                Text("\(Format.date(date)) (\(Format.relative(date)))")
            } else {
                Text(emptyText).foregroundStyle(.secondary)
            }
        }
    }

    static func percent(_ fraction: Decimal) -> String {
        NSDecimalNumber(decimal: fraction).doubleValue.formatted(.percent.precision(.fractionLength(0...1)))
    }
}

/// Per-key cost by month where the provider reports it (DEC-030).
struct KeyCostHistory: View {
    let service: TrackedService
    let keyID: String
    let available: Bool
    let today: Day

    var body: some View {
        let months = today.calendarMonth.adding(months: -11).through(today.calendarMonth)
        let startIndex = service.keyCostsStartMonthIndex
        let costs = Dictionary(service.keyCosts.filter { $0.keyExternalID == keyID }.map { ($0.monthIndex, $0.amount) },
                               uniquingKeysWith: +)
        if !available || startIndex == nil {
            Text("The provider does not report cost per key.").foregroundStyle(.secondary)
        } else {
            let covered = months.filter { $0.index >= (startIndex ?? .max) }
            VStack(alignment: .leading, spacing: 6) {
                Chart(covered, id: \.self) { month in
                    BarMark(x: .value("Month", month.firstDay.date, unit: .month),
                            y: .value("USD", NSDecimalNumber(decimal: costs[month.index] ?? 0).doubleValue))
                        .foregroundStyle(Color.accentColor.gradient)
                }
                .monthAxis(months)
                .growingChartHeight(minimum: 160, fraction: 0.22)
                if let first = covered.first, first != months.first {
                    Text("Per-key cost is available from \(Format.monthLong(first)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    ForEach(covered.reversed(), id: \.self) { month in
                        GridRow {
                            Text(Format.monthLong(month))
                            Text(Format.usd(costs[month.index] ?? 0)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.callout)
                let total = covered.reduce(Decimal(0)) { $0 + (costs[$1.index] ?? 0) }
                LabeledContent("Total for the period") { Text(Format.usd(total)).monospacedDigit().fontWeight(.semibold) }
            }
        }
    }
}

/// This month's tokens of one key by model (REQ-010, DEC-017).
struct KeyTokenUsage: View {
    let service: TrackedService
    let keyID: String

    var body: some View {
        let rows = service.tokenUsage.filter { $0.keyExternalID == keyID }.sorted { $0.inputTokens + $0.outputTokens > $1.inputTokens + $1.outputTokens }
        if !service.hasTokenData || service.tokenUsageMonthIndex != Month(Date(), calendar: .utc).index {
            Text("no data").foregroundStyle(.secondary)
        } else if rows.isEmpty {
            Text("No token usage this month.").foregroundStyle(.secondary)
        } else {
            let showRequests = rows.contains { $0.requests != nil }
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Model").gridColumnAlignment(.leading)
                    Text("Input")
                    Text("Cached")
                    Text("Output")
                    if showRequests { Text("Requests") }
                }
                .font(.caption.weight(.semibold))
                ForEach(rows) { row in
                    GridRow {
                        Text(row.model).lineLimit(1).truncationMode(.middle)
                        Text(Format.tokens(row.inputTokens))
                        Text(row.cachedInputTokens.map(Format.tokens) ?? "—")
                        Text(Format.tokens(row.outputTokens))
                        if showRequests { Text(row.requests.map { $0.formatted() } ?? "—") }
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }
}

extension KeyFacts.Field {
    var rawValue: String { String(describing: self) }

    var title: LocalizedStringKey {
        switch self {
        case .project: "Project / workspace"
        case .maskedValue: "Key"
        case .owner: "Owner"
        case .status: "Status"
        case .scopes: "Scopes"
        }
    }
}

extension KeyDetail.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .project: "Project / workspace"
        case .owner: "Owner"
        case .ownerEmail: "Owner e-mail"
        case .ownerRole: "Owner role"
        case .ownerType: "Owner type"
        case .createdBy: "Created by"
        case .keyType: "Type"
        case .origin: "Origin"
        case .scopes: "Scopes"
        }
    }
}
