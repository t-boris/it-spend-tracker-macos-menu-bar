import SwiftUI

/// Which key fields a service's connector provides; others show as unavailable (REQ-003).
struct KeyFieldAvailability {
    var lastUsed: Bool
    var expiry: Bool
    var spend: Bool
    /// Per-key spend is an approximation shown with "≈" (DEC-036).
    var spendIsEstimate = false

    init(service: TrackedService) {
        if let connector = service.connector {
            let capabilities = connector.descriptor.capabilities
            self.init(lastUsed: capabilities.keyLastUsed, expiry: capabilities.keyExpiry, spend: capabilities.keySpend)
            spendIsEstimate = capabilities.keySpendIsEstimate
        } else if let keys = service.definition?.keys {
            self.init(lastUsed: keys.lastUsedPath != nil, expiry: keys.expiresPath != nil, spend: false)
        } else {
            self.init(lastUsed: false, expiry: false, spend: false)
        }
    }

    init(lastUsed: Bool, expiry: Bool, spend: Bool) {
        self.lastUsed = lastUsed
        self.expiry = expiry
        self.spend = spend
    }
}

/// Which optional sections a service page shows. A usage-metrics connector (Neon) shows its metrics instead of the money
/// breakdown and tokens, but still lists its keys so they can be opened and tagged (REQ-003, REQ-013).
struct ServiceSections: Equatable {
    var usageMetrics: Bool
    var breakdown: Bool
    var keys: Bool
    var tokens: Bool

    init(isConnected: Bool, hasUsageMetrics: Bool) {
        usageMetrics = hasUsageMetrics
        breakdown = isConnected && !hasUsageMetrics
        keys = isConnected
        tokens = isConnected && !hasUsageMetrics
    }
}

struct ServiceDetailView: View {
    @Environment(AppModel.self) private var model
    let serviceID: UUID
    @Binding var selection: Route?
    @State private var sheet: Sheet?
    @State private var confirmingRemoval = false
    @State private var actionError: String?
    @State private var selectedMonth: Month?
    @State private var pickingInvoice = false
    @State private var invoiceFile: InvoiceFile?

    enum Sheet: Identifiable {
        case subscription(SubscriptionRecord?), price(SubscriptionRecord), purchase(CreditPurchaseRecord?), balance, credentials
        case invoice(InvoiceFile)
        var id: String {
            switch self {
            case .subscription(let record): "subscription-\(record.map { "\($0.id)" } ?? "new")"
            case .price(let record): "price-\(record.id)"
            case .purchase(let record): "purchase-\(record.map { "\($0.id)" } ?? "new")"
            case .balance: "balance"
            case .credentials: "credentials"
            case .invoice(let file): "invoice-\(file.id)"
            }
        }
    }

    var body: some View {
        if let service = model.store.service(id: serviceID) {
            content(service)
                .invoicePicker(isPresented: $pickingInvoice, file: $invoiceFile)
                .onChange(of: invoiceFile?.id) { if let invoiceFile { sheet = .invoice(invoiceFile) } }
                .sheet(item: $sheet) { sheet in
                    switch sheet {
                    case .subscription(let record): SubscriptionForm(service: service, record: record)
                    case .price(let record): PriceChangeForm(record: record)
                    case .purchase(let record): CreditPurchaseForm(service: service, purchase: record)
                    case .balance: BalanceSnapshotForm(service: service)
                    case .invoice(let file): InvoiceImportSheet(file: file.url, preselected: service.id)
                    case .credentials:
                        if service.connector == .cline { ClineReauthForm(service: service) } else { CredentialsUpdateForm(service: service) }
                    }
                }
        } else {
            ContentUnavailableView("Service removed", systemImage: "trash")
        }
    }

    private func content(_ service: TrackedService) -> some View {
        let summary = model.summary(for: service)
        let ledger = service.ledger
        let today = model.today
        return Form {
            Section {
                LabeledContent("This month") {
                    AmountText(amount: summary.currentMonthSpend, approximate: summary.isApproximate).font(.title3.weight(.semibold))
                }
                if service.spendIsEstimate {
                    Label("Approximate: computed from usage and Neon's published rates for your plan.", systemImage: "equal.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if service.isConnected {
                    LabeledContent("Last successful update") {
                        if let last = service.lastSuccessfulRefresh { Text(Format.relative(last)) } else { Text("never") }
                    }
                    if let reason = service.spendUnavailableReason {
                        Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    ProviderNotesView(service: service)
                    if let error = service.lastRefreshError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.callout)
                            .textSelection(.enabled)
                    }
                    Button("Refresh now") { Task { await model.refresh.refresh(serviceID: service.id) } }
                        .disabled(model.refresh.refreshing.contains(service.id))
                }
                TextField("Name", text: Binding(
                    get: { service.name },
                    set: { name in
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { try? model.store.rename(service, to: trimmed) }
                    }))
                if !service.accountIdentifier.isEmpty {
                    LabeledContent("Account", value: service.accountIdentifier)
                }
                ConsoleLinks(service: service)
                if !service.note.isEmpty {
                    LabeledContent("Note", value: service.note)
                }
                if summary.hasWarning {
                    VStack(alignment: .leading, spacing: 4) {
                        if !summary.expiringKeys.isEmpty {
                            Label("Keys expiring within 14 days: \(summary.expiringKeys.joined(separator: ", "))",
                                  systemImage: "key.fill").foregroundStyle(.orange)
                        }
                        if let increase = summary.increase {
                            Label("Spend is up: \(Format.usd(increase.monthToDate, approximate: summary.isApproximate)) vs \(Format.usd(increase.previousSamePeriod, approximate: summary.isApproximate)) in the same days of last month",
                                  systemImage: "arrow.up.right.circle.fill").foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)
                }
            } header: {
                Text(service.name).font(.title2.weight(.semibold)).foregroundStyle(.primary)
            }

            monthSection(service, today: today)
            subscriptionsSection(service, today: today)
            let sections = ServiceSections(isConnected: service.isConnected,
                                           hasUsageMetrics: service.connector?.descriptor.capabilities.usageMetrics == true)
            if sections.usageMetrics {
                UsageMetricsSection(service: service, today: today)
            }
            if sections.breakdown { breakdownSection(service, today: today) }
            if sections.keys { keysSection(service) }
            if sections.tokens { tokensSection(service) }
            creditsSection(service, ledger: ledger, today: today)

            Section("History") {
                ServiceHistoryChart(ledger: ledger, currentMonth: today.calendarMonth, isEstimate: service.spendIsEstimate)
                PaymentsList(ledger: ledger, today: today)
            }

            Section {
                if service.isConnected {
                    Button(service.connector == .cline ? "Sign in to Cline again…" : "Update credentials…") { sheet = .credentials }
                }
                if confirmingRemoval {
                    Text("This deletes the service, its saved credentials and all its spend, key, credit and history data.")
                        .font(.callout)
                    HStack {
                        Button("Cancel") { confirmingRemoval = false }
                        Button("Delete permanently", role: .destructive) { remove(service) }
                            .buttonStyle(.borderedProminent).tint(.red)
                    }
                } else {
                    Button("Remove service…", role: .destructive) { confirmingRemoval = true }
                }
                if let actionError {
                    Text(actionError).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(service.name)
    }

    // MARK: Keys (REQ-003)

    @ViewBuilder
    private func keysSection(_ service: TrackedService) -> some View {
        let availability = KeyFieldAvailability(service: service)
        let month = model.today.calendarMonth
        Section("Keys") {
            if !service.hasKeyData {
                Text("no data").foregroundStyle(.secondary)
            } else if service.keys.isEmpty {
                Text("The provider reports no keys.").foregroundStyle(.secondary)
            } else {
                // Most expensive first, then by name; each row opens the key page (REQ-016).
                ForEach(service.keys.sorted { ($0.monthCost(in: month) ?? -1, $1.name) > ($1.monthCost(in: month) ?? -1, $0.name) }) { key in
                    Button { selection = .key(service: service.id, key: key.externalID) } label: {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(key.name).font(.body.weight(.medium))
                                    if WarningRules.isExpiringSoon(expiresAt: key.expiresAt, now: Date()) {
                                        Image(systemName: "key.fill").foregroundStyle(.orange)
                                            .help(Text("Expires within 14 days"))
                                            .accessibilityLabel(Text("Expires within 14 days"))
                                    }
                                    if let status = key.status, status != "active" {
                                        Text(status).font(.caption).foregroundStyle(.secondary)
                                    }
                                    ForEach(service.tags(forKey: key.externalID), id: \.self) { TagChip(tag: $0) }
                                }
                                HStack(spacing: 12) {
                                    if let hint = key.hint, !hint.isEmpty {
                                        Text(OpenAIConnector.compactRedacted(hint)).font(.caption.monospaced())
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    field("Last used", available: availability.lastUsed, date: key.lastUsedAt, emptyText: "never")
                                    field("Expires", available: availability.expiry, date: key.expiresAt, emptyText: "no expiry")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if availability.spend, let cost = key.monthCost(in: month) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(verbatim: (availability.spendIsEstimate ? "≈ " : "") + Format.usd(cost)).monospacedDigit()
                                    if let requests = key.requestsThisMonth {
                                        Text("\(requests) requests this month").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            } else if let requests = key.requestsThisMonth {
                                Text("\(requests) requests this month").font(.callout).monospacedDigit()
                            } else if availability.spend {
                                Text("unavailable").foregroundStyle(.secondary)
                            } else {
                                Text("Spend: unavailable").font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func field(_ title: LocalizedStringResource, available: Bool, date: Date?, emptyText: LocalizedStringResource) -> Text {
        let value: String
        if !available {
            value = String(localized: "unavailable")
        } else if let date {
            value = Format.date(date)
        } else {
            value = String(localized: emptyText)
        }
        return Text("\(String(localized: title)): \(value)")
    }

    // MARK: Token usage (REQ-010, DEC-017)

    @ViewBuilder
    private func tokensSection(_ service: TrackedService) -> some View {
        Section("Token usage this month") {
            let rows = service.tokenUsage
            if !service.hasTokenData || service.tokenUsageMonthIndex != Month(Date(), calendar: .utc).index {
                Text("no data").foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text("No token usage this month.").foregroundStyle(.secondary)
            } else {
                let keyNames = Dictionary(service.keys.map { ($0.externalID, $0.name) }, uniquingKeysWith: { a, _ in a })
                let groups = Dictionary(grouping: rows) { $0.keyExternalID ?? "" }
                ForEach(groups.keys.sorted(), id: \.self) { keyID in
                    let keyRows = groups[keyID] ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        Text(keyID.isEmpty ? String(localized: "Without key (e.g. console)") : (keyNames[keyID] ?? keyID))
                            .font(.callout.weight(.medium))
                        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 2) {
                            GridRow {
                                Text("Model").gridColumnAlignment(.leading)
                                Text("Input")
                                Text("Cached")
                                Text("Output")
                            }
                            .font(.caption.weight(.semibold))
                            ForEach(keyRows.sorted { $0.model < $1.model }) { row in
                                GridRow {
                                    Text(row.model).lineLimit(1).truncationMode(.middle)
                                    Text(Format.tokens(row.inputTokens))
                                    Text(row.cachedInputTokens.map(Format.tokens) ?? "—")
                                    Text(Format.tokens(row.outputTokens))
                                }
                                .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
                let input = rows.reduce(0) { $0 + $1.inputTokens }
                let output = rows.reduce(0) { $0 + $1.outputTokens }
                LabeledContent("Total") {
                    Text("\(Format.tokens(input)) in · \(Format.tokens(output)) out").monospacedDigit()
                }
            }
        }
    }

    // MARK: Credits (REQ-010, DEC-008, DEC-021)

    @ViewBuilder
    private func creditsSection(_ service: TrackedService, ledger: ServiceLedger, today: Day) -> some View {
        Section {
            LabeledContent("Purchased (recorded)") { Text(Format.usd(ledger.totalPurchased)).monospacedDigit() }
            LabeledContent("Remaining") {
                switch ledger.remainingBalance(today: today) {
                case .noData: Text("no data").foregroundStyle(.secondary)
                case .estimate(let value): Text("≈ \(Format.usd(value)) (estimate)").monospacedDigit()
                case .asOfSnapshot(let value, let day):
                    Text("\(Format.usd(value)) as of \(Format.day(day))").monospacedDigit()
                }
            }
            ForEach(service.creditPurchases.sorted { $0.dayKey > $1.dayKey }) { purchase in
                HStack {
                    Text(Day(key: purchase.dayKey).map(Format.day) ?? "")
                    if !purchase.volume.isEmpty { Text(purchase.volume).foregroundStyle(.secondary) }
                    Spacer()
                    Text(Format.usd(purchase.amount)).monospacedDigit()
                    // Imported purchases are replaced on every refresh, so only the user's own ones are editable.
                    if purchase.externalID == nil {
                        Button { sheet = .purchase(purchase) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).accessibilityLabel(Text("Edit"))
                        Button { try? model.store.deleteCreditPurchase(purchase, from: service) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel(Text("Delete"))
                    } else {
                        Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                            .help(Text("Imported from the provider"))
                    }
                }
                .font(.callout)
            }
            HStack {
                Button("Add credit purchase…") { sheet = .purchase(nil) }
                if !service.isConnected {
                    Button("Add invoice from PDF…") { pickingInvoice = true }
                }
                // A balance the provider reports would be overwritten on the next refresh.
                if service.connector?.descriptor.capabilities.reportsBalance != true {
                    Button("Set balance…") { sheet = .balance }
                }
            }
        } header: {
            Text("Credits")
        } footer: {
            if service.connector == .cline {
                Text("Spend is the Cline credits used plus Cline Pass payments. Credit top-ups and the balance come from Cline and are for information only.")
            } else if service.isConnected {
                Text("For API services, spend is the usage cost reported by the provider. Credit purchases and balance are for information only.")
            } else {
                Text("Credit purchases count as spend in the month of purchase.")
            }
        }
    }

    // MARK: Subscriptions (REQ-007, DEC-014, DEC-026)

    @ViewBuilder
    private func subscriptionsSection(_ service: TrackedService, today: Day) -> some View {
        Section {
            if service.subscriptionRecords.isEmpty {
                Text("No fixed subscriptions.").foregroundStyle(.secondary)
            }
            ForEach(service.sortedSubscriptions) { record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.name).font(.body.weight(.medium))
                        Spacer()
                        if let current = record.plan?.price(on: today) {
                            Text("\(Format.usd(current)) / \(String(localized: record.period.unit))").monospacedDigit()
                        }
                    }
                    Group {
                        if let start = record.start {
                            if let end = record.end {
                                Text("\(Format.day(start)) – \(Format.day(end))")
                            } else if let next = record.plan?.nextCharge(onOrAfter: today) {
                                Text("Since \(Format.day(start)) · next payment \(Format.day(next.day)): \(Format.usd(next.amount))")
                            } else {
                                Text("Since \(Format.day(start))")
                            }
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if record.prices.count > 1 {
                        ForEach(record.sortedPrices) { price in
                            HStack {
                                Text("From \(Day(key: price.effectiveFromKey).map(Format.day) ?? ""): \(Format.usd(price.amount))")
                                Button { try? model.store.deletePrice(price, from: record) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).accessibilityLabel(Text("Delete"))
                            }
                            .font(.caption)
                        }
                    }
                    HStack {
                        Button("Edit…") { sheet = .subscription(record) }
                        Button("Change price…") { sheet = .price(record) }
                        Button("Delete", role: .destructive) { try? model.store.deleteSubscription(record, from: service) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            Button("Add subscription…") { sheet = .subscription(nil) }
        } header: {
            Text("Subscriptions")
        } footer: {
            if service.isConnected {
                Text("Fixed payments the provider API does not report, e.g. a ChatGPT plan or seats. They are added to the usage cost.")
            }
        }
    }

    // MARK: Selected month (REQ-015)

    /// Usage, subscriptions and total for the month chosen here; the breakdown below follows the same month.
    @ViewBuilder
    private func monthSection(_ service: TrackedService, today: Day) -> some View {
        let month = selectedMonth ?? today.calendarMonth
        let months = today.calendarMonth.adding(months: -11).through(today.calendarMonth).reversed()
        let composition = MonthComposition(ledger: service.ledger, month: month)
        Section {
            Picker("Month", selection: Binding(get: { month }, set: { selectedMonth = $0 })) {
                ForEach(Array(months), id: \.self) { Text(Format.monthLong($0)).tag($0) }
            }
            if let usage = composition.usage {
                LabeledContent("Usage") { AmountText(amount: usage, approximate: service.spendIsEstimate) }
            }
            if let subscriptions = composition.subscriptions {
                LabeledContent("Subscriptions") { Text(Format.usd(subscriptions)).monospacedDigit() }
            }
            LabeledContent("Total") {
                AmountText(amount: composition.total, approximate: service.spendIsEstimate).fontWeight(.semibold)
            }
        } header: {
            Text("Month")
        }
    }

    // MARK: Breakdown (REQ-015, DEC-027)

    @ViewBuilder
    private func breakdownSection(_ service: TrackedService, today: Day) -> some View {
        let capabilities = service.connector?.descriptor.capabilities
        let supported = capabilities.map { $0.breakdownByLineItem || $0.breakdownByProject || $0.breakdownByAccount } ?? false
        let month = selectedMonth ?? today.calendarMonth
        Section {
            if !supported {
                Text("no data").foregroundStyle(.secondary)
            } else {
                let covered = service.breakdownStartMonthIndex.map { month.index >= $0 } ?? false
                let rows = service.breakdown.filter { $0.monthIndex == month.index }
                if !covered {
                    Text("no data").foregroundStyle(.secondary)
                } else if rows.isEmpty {
                    Text("No usage this month.").foregroundStyle(.secondary)
                } else {
                    let counts = Dictionary(grouping: rows.compactMap { BreakdownDimension(rawValue: $0.dimensionRaw) }, by: { $0 })
                        .mapValues(\.count)
                    ForEach(BreakdownGroup.groups(offered: capabilities?.breakdownDimensions ?? [], counts: counts)) { group in
                        if group.hasData {
                            BreakdownList(title: Self.title(of: group.dimension),
                                          rows: rows.filter { $0.dimensionRaw == group.dimension.rawValue })
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.title(of: group.dimension)).font(.callout.weight(.semibold))
                                Text("no data").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Usage breakdown")
        }
    }

    private static func title(of dimension: BreakdownDimension) -> LocalizedStringKey {
        switch dimension {
        case .account: "By account / organization"
        case .lineItem: "By model / line item"
        case .project: "By project"
        }
    }

    private func remove(_ service: TrackedService) {
        do {
            try model.store.remove(service)
            selection = .services
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// Top entries of one breakdown dimension with proportional bars.
struct BreakdownList: View {
    let title: LocalizedStringKey
    let rows: [BreakdownRecord]
    @Environment(\.isLargeLayout) private var isLargeLayout
    @State private var showAll = false

    var body: some View {
        let sorted = rows.sorted { $0.amount > $1.amount }
        let limit = isLargeLayout ? 20 : 8
        let shown = showAll ? sorted : Array(sorted.prefix(limit))
        let maximum = max(sorted.first?.amount ?? 0, 0.000_001)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            ForEach(shown, id: \.label) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.label).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Format.usd(row.amount)).monospacedDigit()
                    }
                    .font(.caption)
                    GeometryReader { geometry in
                        Capsule().fill(Color.accentColor.opacity(0.35))
                            .frame(width: max(2, geometry.size.width * CGFloat(NSDecimalNumber(decimal: row.amount / maximum).doubleValue)))
                    }
                    .frame(height: 4)
                }
            }
            if sorted.count > limit {
                Button(showAll ? "Show less" : "Show all (\(sorted.count))") { showAll.toggle() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }
}

/// Subscription payments and credit purchases with their dates, last 12 months plus the next payments.
struct PaymentsList: View {
    let ledger: ServiceLedger
    let today: Day

    var body: some View {
        let from = today.calendarMonth.adding(months: -11).firstDay
        let past = ledger.payments(from: from, through: today).reversed()
        let upcoming = ledger.subscriptions.compactMap { plan in plan.nextCharge(after: today).map { (plan.name, $0) } }
        if !past.isEmpty || !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Payments").font(.callout.weight(.semibold))
                ForEach(Array(upcoming.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(Format.day(item.1.day))
                        Text("\(item.0) (next)").foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.usd(item.1.amount)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(past.enumerated()), id: \.offset) { _, payment in
                    HStack {
                        Text(Format.day(payment.day))
                        Text(payment.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.usd(payment.amount)).monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
    }
}

/// Usage quantities without money, per month, in total and by project (REQ-017, DEC-031).
struct UsageMetricsSection: View {
    let service: TrackedService
    let today: Day
    @State private var month: Month?

    /// Metrics shown in the monthly overview table.
    private static let overview: [UsageMetricKind] = [.computeUnitSeconds, .rootBranchBytesMonth, .publicNetworkTransferBytes]

    var body: some View {
        let months = Array(today.calendarMonth.adding(months: -11).through(today.calendarMonth).reversed())
        let latestWithData = service.usageMetrics.map(\.monthIndex).max().map { Month(index: $0) }
        let selected = month ?? latestWithData ?? today.calendarMonth
        let records = service.usageMetrics.filter { $0.monthIndex == selected.index }
        let covered = service.usageMetricsStartMonthIndex.map { selected.index >= $0 } ?? false
        // With several organizations a project is shown as "Project (Org)", so equal names stay apart.
        let severalOrganizations = Set(service.usageMetrics.compactMap(\.organization)).count > 1
        Section {
            if !service.usageMetrics.isEmpty {
                overviewTable(months: months, selected: selected)
            }
            Picker("Month", selection: Binding(get: { selected }, set: { month = $0 })) {
                ForEach(months, id: \.self) { Text(Format.monthLong($0)).tag($0) }
            }
            if !covered {
                Text("no data").foregroundStyle(.secondary)
            } else if records.isEmpty {
                Text("No usage this month.").foregroundStyle(.secondary)
            } else {
                ForEach(UsageMetricKind.allCases, id: \.self) { kind in
                    let rows = records.filter { $0.metric == kind.rawValue }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(kind.title).font(.callout.weight(.semibold))
                                Spacer()
                                Text("\(Self.number(rows.reduce(0) { $0 + $1.value })) \(String(localized: kind.unit))").monospacedDigit()
                                Self.approximate(rows).frame(minWidth: 80, alignment: .trailing)
                            }
                            ForEach(rows.sorted { $0.value > $1.value }, id: \.persistentModelID) { row in
                                HStack {
                                    Text(row.label(showingOrganization: severalOrganizations)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Self.number(row.value)).monospacedDigit()
                                    Self.approximate([row]).frame(minWidth: 80, alignment: .trailing)
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if covered, !records.isEmpty {
                LabeledContent("≈ Total for the month") {
                    Self.approximate(records).font(.body.weight(.semibold))
                }
            }
        } header: {
            Text("Usage")
        } footer: {
            let plans = Set(service.usageMetrics.compactMap(\.plan)).sorted().joined(separator: ", ")
            Text("≈ is an approximate cost from Neon's published rates for your plan (\(plans.isEmpty ? "—" : plans)), after included allowances. It is counted in totals and history, marked ≈.")
        }
    }

    /// Months with usage and their main metrics; clicking a row selects the month.
    private func overviewTable(months: [Month], selected: Month) -> some View {
        let byMonth = Dictionary(grouping: service.usageMetrics, by: \.monthIndex)
        return Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Month").gridColumnAlignment(.leading)
                ForEach(Self.overview, id: \.self) { kind in
                    Text("\(String(localized: kind.title)), \(String(localized: kind.unit))")
                }
                Text("≈ cost")
            }
            .font(.caption.weight(.semibold))
            ForEach(months.filter { byMonth[$0.index] != nil }, id: \.self) { month in
                let rows = byMonth[month.index] ?? []
                GridRow {
                    Button(Format.monthLong(month)) { self.month = month }
                        .buttonStyle(.borderless)
                        .fontWeight(month == selected ? .semibold : .regular)
                    ForEach(Self.overview, id: \.self) { kind in
                        Text(Self.number(rows.filter { $0.metric == kind.rawValue }.reduce(0) { $0 + $1.value }))
                            .monospacedDigit()
                    }
                    Self.approximate(rows)
                }
                .font(.callout)
            }
        }
    }

    /// "≈ $X" for the rows' approximate cost; "≈ ?" when a plan's rates are unknown.
    static func approximate(_ rows: [UsageMetricRecord]) -> Text {
        let costs = rows.map(\.approximateCost)
        if costs.contains(where: { $0 == nil }) && costs.allSatisfy({ $0 == nil }) {
            return Text(verbatim: "≈ ?").foregroundStyle(.secondary)
        }
        let total = costs.compactMap { $0 }.reduce(0, +)
        return Text(verbatim: "≈ \(Format.usd(total))").monospacedDigit()
    }

    static func number(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).doubleValue.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// Notes from the last refresh: warnings in orange, facts in neutral grey; each can be hidden.
struct ProviderNotesView: View {
    @Environment(AppModel.self) private var model
    let service: TrackedService
    @State private var showHidden = false

    var body: some View {
        let hiddenIDs = service.hiddenNoteIDs
        let notes = service.providerNotes
        let hidden = notes.filter { hiddenIDs.contains($0.id) }
        ForEach(notes.filter { showHidden || !hiddenIDs.contains($0.id) }) { note in
            HStack(alignment: .firstTextBaseline) {
                Label(note.text, systemImage: note.kind == .warning ? "exclamationmark.circle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(note.kind == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Spacer()
                let isHidden = hiddenIDs.contains(note.id)
                Button(isHidden ? "Show" : "Hide") {
                    try? model.store.setNoteHidden(note.id, hidden: !isHidden, in: service)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        if !hidden.isEmpty {
            Button(showHidden ? "Collapse hidden notes" : "Hidden notes: \(hidden.count) · Show") { showHidden.toggle() }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Links to the provider consoles where billing and keys can be changed (DEC-035).
struct ConsoleLinks: View {
    let service: TrackedService

    enum Kind: Equatable { case billing, keys, documentation }
    struct Item: Equatable {
        let kind: Kind
        let url: URL
    }

    /// Built-in connectors link to their consoles; an approved definition links to what the AI found (https only), and
    /// falls back to the service's own link; manual services carry an optional link of their own (DEC-041).
    static func items(connector: ConnectorID?, definition: ConnectorDefinition?, manualLink: URL?) -> [Item] {
        if let connector {
            return [Item(kind: .billing, url: connector.billingConsoleURL), Item(kind: .keys, url: connector.keysConsoleURL)]
        }
        var items: [Item] = []
        if let definition {
            if let url = ConnectorDefinition.safeLink(definition.consoleURL) { items.append(Item(kind: .billing, url: url)) }
            if let url = ConnectorDefinition.safeLink(definition.keysConsoleURL) { items.append(Item(kind: .keys, url: url)) }
            if let url = ConnectorDefinition.safeLink(definition.docsURL) { items.append(Item(kind: .documentation, url: url)) }
        }
        if items.isEmpty, let manualLink { items.append(Item(kind: .billing, url: manualLink)) }
        return items
    }

    var body: some View {
        let items = Self.items(connector: service.connector, definition: service.definition, manualLink: service.consoleLinkURL)
        if !items.isEmpty {
            HStack(spacing: 16) {
                ForEach(items, id: \.url) { item in
                    switch item.kind {
                    case .billing: Link(destination: item.url) { Label("Billing console", systemImage: "creditcard") }
                    case .keys: Link(destination: item.url) { Label("Manage keys", systemImage: "key") }
                    case .documentation: Link(destination: item.url) { Label("Provider documentation", systemImage: "safari") }
                    }
                }
            }
            .font(.callout)
        }
    }
}
