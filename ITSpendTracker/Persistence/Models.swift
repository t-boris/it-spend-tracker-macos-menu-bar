import Foundation
import SwiftData

/// A tracked service: built-in connector, approved AI-proposed definition, or manual entry.
/// Secrets are never stored here; they live in the Keychain under `id` (DEC-013).
@Model
final class TrackedService {
    @Attribute(.unique) var id: UUID
    var name: String
    var accountIdentifier: String
    var note: String
    /// `ConnectorID.rawValue` for built-in connectors.
    var connectorRaw: String?
    /// JSON-encoded `ConnectorDefinition` for AI-proposed connectors (DEC-022).
    var definitionJSON: Data?
    var includedInTotal: Bool
    var createdAt: Date

    var lastSuccessfulRefresh: Date?
    var lastRefreshAttempt: Date?
    var lastRefreshError: String?
    /// Why the provider cannot report spend for this account, if so (spend then shows "no data").
    var spendUnavailableReason: String?
    /// Non-fatal remarks from the last refresh (JSON-encoded `[String]`).
    var providerNotesJSON: Data?
    var usageMetricsStartMonthIndex: Int?

    /// IDs of notes the user hid.
    var hiddenNoteIDsJSON: Data?
    /// Optional https link to the provider's dashboard, for manual services (DEC-041); `nil` by default.
    var consoleLink: String? = nil

    var providerNotes: [ProviderNote] {
        providerNotesJSON.flatMap { try? JSONDecoder().decode([ProviderNote].self, from: $0) } ?? []
    }

    var hiddenNoteIDs: Set<String> {
        hiddenNoteIDsJSON.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }
    /// `Day.key` of the first day covered by provider data.
    var coverageStartKey: Int?
    var hasKeyData: Bool
    var hasTokenData: Bool
    /// Months (`Month.index`) from which breakdown rows are stored; `nil` if the connector provides none.
    var breakdownStartMonthIndex: Int?
    /// Whether the breakdown was requested for the full backfill range at least once.
    var breakdownBackfilled: Bool = false
    /// `Month.index` the stored token usage belongs to.
    var tokenUsageMonthIndex: Int?


    var balanceSnapshotAmount: Decimal?
    var balanceSnapshotDayKey: Int?

    @Relationship(deleteRule: .cascade, inverse: \DailyCost.service) var dailyCosts: [DailyCost] = []
    @Relationship(deleteRule: .cascade, inverse: \KeyRecord.service) var keys: [KeyRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \TokenUsageRecord.service) var tokenUsage: [TokenUsageRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \SubscriptionRecord.service) var subscriptionRecords: [SubscriptionRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \BreakdownRecord.service) var breakdown: [BreakdownRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \KeyCostRecord.service) var keyCosts: [KeyCostRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \UsageMetricRecord.service) var usageMetrics: [UsageMetricRecord] = []
    /// `Month.index` from which per-key monthly costs are stored.
    var keyCostsStartMonthIndex: Int?
    @Relationship(deleteRule: .cascade, inverse: \CreditPurchaseRecord.service) var creditPurchases: [CreditPurchaseRecord] = []
    /// User tags per key; kept separately because key records are replaced on every refresh (DEC-024).
    @Relationship(deleteRule: .cascade, inverse: \KeyTagRecord.service) var keyTags: [KeyTagRecord] = []

    init(name: String, accountIdentifier: String = "", note: String = "", connector: ConnectorID? = nil,
         definition: ConnectorDefinition? = nil) {
        id = UUID()
        self.name = name
        self.accountIdentifier = accountIdentifier
        self.note = note
        connectorRaw = connector?.rawValue
        definitionJSON = definition.flatMap { try? JSONEncoder().encode($0) }
        includedInTotal = true
        createdAt = .now
        hasKeyData = false
        hasTokenData = false
    }

    var connector: ConnectorID? { connectorRaw.flatMap(ConnectorID.init(rawValue:)) }

    var definition: ConnectorDefinition? {
        definitionJSON.flatMap { try? JSONDecoder().decode(ConnectorDefinition.self, from: $0) }
    }

    /// The console link when it is a valid https URL.
    var consoleLinkURL: URL? { consoleLink.flatMap(Self.httpsURL) }

    /// Accepts only well-formed `https` URLs with a host (DEC-041).
    static func httpsURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host()?.isEmpty == false else { return nil }
        return url
    }

    /// Whether data is fetched from a provider API (built-in or approved definition).
    var isConnected: Bool { connector != nil || definitionJSON != nil }

    /// Whether provider spend is an approximation from usage × published rates (DEC-033).
    var spendIsEstimate: Bool { connector?.descriptor.capabilities.spendIsEstimate ?? false }

    /// Whether the spend of `month` contains an approximation (and therefore shows "≈").
    func isApproximate(in month: Month) -> Bool {
        spendIsEstimate && (ledger.usage(in: month).decimal ?? 0) != 0
    }

    /// A full 12-month fetch is needed when there is no history yet, or when the connector offers a
    /// breakdown that was never backfilled (services connected before breakdowns existed, DEC-027).
    var needsFullBackfill: Bool {
        guard coverageStartKey != nil else { return true }
        let capabilities = connector?.descriptor.capabilities
        let offersBreakdown = capabilities.map { $0.breakdownByLineItem || $0.breakdownByProject } ?? false
        let offersKeyCosts = capabilities?.keySpend ?? false
        return (offersBreakdown && !breakdownBackfilled) || (offersKeyCosts && keyCostsStartMonthIndex == nil)
    }

    func tags(forKey externalID: String) -> [String] {
        keyTags.first { $0.keyExternalID == externalID }?.tags ?? []
    }

    /// Subscriptions sorted by start date.
    var sortedSubscriptions: [SubscriptionRecord] {
        subscriptionRecords.sorted { $0.startKey < $1.startKey }
    }

    var ledger: ServiceLedger {
        ServiceLedger(
            isConnected: isConnected,
            providerDailyCosts: Dictionary(dailyCosts.compactMap { cost in Day(key: cost.dayKey).map { ($0, cost.amount) } },
                                           uniquingKeysWith: +),
            providerCoverageStart: coverageStartKey.flatMap(Day.init(key:)),
            usageIsDaily: connector?.descriptor.capabilities.dailySpend ?? true,
            subscriptions: sortedSubscriptions.compactMap(\.plan),
            creditPurchases: creditPurchases.compactMap { purchase in
                Day(key: purchase.dayKey).map { (day: $0, amount: purchase.amount) }
            },
            balanceSnapshot: balanceSnapshotDayKey.flatMap(Day.init(key:)).flatMap { day in
                balanceSnapshotAmount.map { (day: day, amount: $0) }
            }
        )
    }
}

@Model
final class DailyCost {
    var dayKey: Int
    var amount: Decimal
    var service: TrackedService?

    init(dayKey: Int, amount: Decimal) {
        self.dayKey = dayKey
        self.amount = amount
    }
}

@Model
final class KeyRecord {
    var externalID: String
    var name: String
    var hint: String?
    var createdAt: Date?
    var lastUsedAt: Date?
    var expiresAt: Date?
    var status: String?
    var currentMonthCost: Decimal?
    /// Month (`Month.index`) the cost was fetched for. `nil` in records saved before this was stored.
    var currentMonthIndex: Int?
    /// JSON-encoded `[KeyDetail]` (DEC-030).
    var detailsJSON: Data?
    var requestsThisMonth: Int?
    var consoleURLString: String?

    var consoleURL: URL? { consoleURLString.flatMap(URL.init(string:)) }
    var service: TrackedService?

    var details: [KeyDetail] {
        detailsJSON.flatMap { try? JSONDecoder().decode([KeyDetail].self, from: $0) } ?? []
    }

    /// Cost of this key in `month`, or `nil` when it is not known for that month. The stored figure belongs to the month it
    /// was fetched in, so after a month change it is not shown as "this month" until the next refresh (REQ-013).
    func monthCost(in month: Month) -> Decimal? {
        guard let currentMonthCost else { return nil }
        // A record saved before the month was stored cannot be checked; trust it until the next refresh replaces it.
        return currentMonthIndex.map { $0 == month.index } ?? true ? currentMonthCost : nil
    }

    init(_ key: ProviderKey, fetchedIn month: Month? = nil) {
        externalID = key.externalID
        name = key.name
        hint = key.hint
        createdAt = key.createdAt
        lastUsedAt = key.lastUsedAt
        expiresAt = key.expiresAt
        status = key.status
        currentMonthCost = key.currentMonthCost
        currentMonthIndex = month?.index
        detailsJSON = key.details.isEmpty ? nil : try? JSONEncoder().encode(key.details)
        requestsThisMonth = key.requestsThisMonth
        consoleURLString = key.consoleURL?.absoluteString
    }
}

@Model
final class TokenUsageRecord {
    var keyExternalID: String?
    var model: String
    var inputTokens: Int
    var cachedInputTokens: Int?
    var outputTokens: Int
    var requests: Int?
    var service: TrackedService?

    init(_ row: TokenUsageRow) {
        keyExternalID = row.keyExternalID
        model = row.model
        inputTokens = row.inputTokens
        cachedInputTokens = row.cachedInputTokens
        outputTokens = row.outputTokens
        requests = row.requests
    }
}

/// A fixed subscription on any service (DEC-026).
@Model
final class SubscriptionRecord {
    var id: UUID
    var name: String
    var periodRaw: String
    var startKey: Int
    var endKey: Int?
    @Relationship(deleteRule: .cascade, inverse: \SubscriptionPriceRecord.subscription) var prices: [SubscriptionPriceRecord] = []
    var service: TrackedService?

    init(name: String, period: SubscriptionPlan.Period, start: Day, end: Day?) {
        id = UUID()
        self.name = name
        periodRaw = period.rawValue
        startKey = start.key
        endKey = end?.key
    }

    var period: SubscriptionPlan.Period { SubscriptionPlan.Period(rawValue: periodRaw) ?? .monthly }
    var start: Day? { Day(key: startKey) }
    var end: Day? { endKey.flatMap(Day.init(key:)) }
    var sortedPrices: [SubscriptionPriceRecord] { prices.sorted { $0.effectiveFromKey < $1.effectiveFromKey } }

    var plan: SubscriptionPlan? {
        guard let start else { return nil }
        let priceList = prices.compactMap { price in
            Day(key: price.effectiveFromKey).map { SubscriptionPlan.Price(effectiveFrom: $0, amount: price.amount) }
        }
        return SubscriptionPlan(name: name, period: period, start: start, end: end, prices: priceList)
    }
}

@Model
final class SubscriptionPriceRecord {
    var effectiveFromKey: Int
    var amount: Decimal
    var subscription: SubscriptionRecord?

    init(effectiveFrom: Day, amount: Decimal) {
        effectiveFromKey = effectiveFrom.key
        self.amount = amount
    }
}

/// A usage quantity in its billing unit for one project, metric and month (DEC-031).
@Model
final class UsageMetricRecord {
    var monthIndex: Int
    var project: String
    var metric: String
    var value: Decimal
    var plan: String?
    var service: TrackedService?

    init(_ row: UsageMetricRow) {
        monthIndex = row.month.index
        project = row.project
        metric = row.metric
        value = row.value
        plan = row.plan
    }

    /// ≈ cost for orientation (DEC-033); `nil` when the plan's rates are unknown.
    var approximateCost: Decimal? { NeonPricing.cost(metric: metric, value: value, plan: plan) }
}

/// Cost of one key in one month (DEC-030).
@Model
final class KeyCostRecord {
    var keyExternalID: String
    var monthIndex: Int
    var amount: Decimal
    var service: TrackedService?

    init(_ cost: KeyMonthCost) {
        keyExternalID = cost.keyExternalID
        monthIndex = cost.month.index
        amount = cost.amount
    }
}

/// Monthly usage cost grouped by line item or provider project (DEC-027).
@Model
final class BreakdownRecord {
    var monthIndex: Int
    var dimensionRaw: String
    var label: String
    var amount: Decimal
    var service: TrackedService?

    init(_ row: BreakdownRow) {
        monthIndex = row.month.index
        dimensionRaw = row.dimension.rawValue
        label = row.label
        amount = row.amount
    }
}

@Model
final class CreditPurchaseRecord {
    var id: UUID
    var dayKey: Int
    var amount: Decimal
    /// Optional purchased volume, e.g. "1 000 000 tokens" or "100 credits".
    var volume: String
    /// Provider's payment ID for imported purchases (DEC-040); `nil` for purchases entered by the user.
    var externalID: String? = nil
    var service: TrackedService?

    init(day: Day, amount: Decimal, volume: String, externalID: String? = nil) {
        id = UUID()
        dayKey = day.key
        self.amount = amount
        self.volume = volume
        self.externalID = externalID
    }
}

@Model
final class KeyTagRecord {
    var keyExternalID: String
    var tags: [String]
    var service: TrackedService?

    init(keyExternalID: String, tags: [String]) {
        self.keyExternalID = keyExternalID
        self.tags = tags
    }
}

enum Persistence {
    static let schema = Schema([TrackedService.self, DailyCost.self, KeyRecord.self, TokenUsageRecord.self,
                                SubscriptionRecord.self, SubscriptionPriceRecord.self, CreditPurchaseRecord.self, KeyTagRecord.self,
                                BreakdownRecord.self, KeyCostRecord.self, UsageMetricRecord.self])

    /// The store lives in the app's Application Support directory (DEC-013).
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        let directory = URL.applicationSupportDirectory.appending(path: "ITSpendTracker", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "spend.store"))
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
