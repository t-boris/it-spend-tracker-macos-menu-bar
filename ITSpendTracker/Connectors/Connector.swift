import Foundation

/// Built-in v1 connectors (DEC-012, DEC-028, DEC-040, REQ-011). Neon and Fly.io have no usable spend API (SRC-002)
/// and, like every other service, are added through manual entry.
enum ConnectorID: String, Codable, CaseIterable, Sendable, Identifiable {
    case openAI = "openai"
    case anthropic
    case vercel
    case googleCloud = "gcp"
    case gitHub = "github"
    case neon
    case cline

    var id: String { rawValue }

    var descriptor: ConnectorDescriptor {
        switch self {
        case .openAI: OpenAIConnector.descriptor
        case .anthropic: AnthropicConnector.descriptor
        case .vercel: VercelConnector.descriptor
        case .googleCloud: GoogleCloudConnector.descriptor
        case .gitHub: GitHubConnector.descriptor
        case .neon: NeonConnector.descriptor
        case .cline: ClineConnector.descriptor
        }
    }

    func makeConnector(http: HTTPClient) -> any Connector {
        switch self {
        case .openAI: OpenAIConnector(http: http)
        case .anthropic: AnthropicConnector(http: http)
        case .vercel: VercelConnector(http: http)
        case .googleCloud: GoogleCloudConnector(http: http)
        case .gitHub: GitHubConnector(http: http)
        case .neon: NeonConnector(http: http)
        case .cline: ClineConnector(http: http)
        }
    }

    /// Provider consoles for billing and for managing keys (DEC-035).
    var billingConsoleURL: URL {
        let address: String = switch self {
        case .openAI: "https://platform.openai.com/settings/organization/billing/overview"
        case .anthropic: "https://platform.claude.com/settings/billing"
        case .vercel: "https://vercel.com/dashboard/usage"
        case .googleCloud: "https://console.cloud.google.com/billing"
        case .gitHub: "https://github.com/settings/billing"
        case .neon: "https://console.neon.tech/app/billing"
        case .cline: "https://app.cline.bot/dashboard/account?tab=credits"
        }
        return URL(string: address)!
    }

    var keysConsoleURL: URL {
        let address: String = switch self {
        case .openAI: "https://platform.openai.com/api-keys"
        case .anthropic: "https://platform.claude.com/settings/keys"
        case .vercel: "https://vercel.com/account/tokens"
        case .googleCloud: "https://console.cloud.google.com/apis/credentials"
        case .gitHub: "https://github.com/settings/tokens"
        case .neon: "https://console.neon.tech/app/settings/api-keys"
        case .cline: "https://app.cline.bot/dashboard"
        }
        return URL(string: address)!
    }

    /// Deterministic match of a user-entered service name to a built-in connector.
    static func match(serviceName: String) -> ConnectorID? {
        let normalized = serviceName.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !normalized.isEmpty else { return nil }
        return allCases.first { id in
            id.descriptor.aliases.contains { normalized == $0 || normalized.hasPrefix($0) }
        }
    }
}

/// A credential or configuration field the connector needs, entered in a native form (DEC-011).
struct CredentialField: Sendable, Identifiable {
    let id: String
    let label: LocalizedStringResource
    let help: LocalizedStringResource
    let isSecret: Bool
    let isOptional: Bool
    let isMultiline: Bool

    init(id: String, label: LocalizedStringResource, help: LocalizedStringResource,
         isSecret: Bool, isOptional: Bool = false, isMultiline: Bool = false) {
        self.id = id
        self.label = label
        self.help = help
        self.isSecret = isSecret
        self.isOptional = isOptional
        self.isMultiline = isMultiline
    }
}

/// Which data a connector provides; anything else is shown as "no data" (DEC-012).
struct ConnectorCapabilities: Sendable {
    /// Usage is reported per day; `false` when it is booked once per month (Neon, DEC-031, DEC-039).
    var dailySpend = true
    var backfillMonths = 12
    var keyDetails = false
    var keyLastUsed = false
    var keyExpiry = false
    var keySpend = false
    /// Per-key spend is an approximation (Google: project/service cost split by request share, DEC-036).
    var keySpendIsEstimate = false
    var tokenUsage = false
    var breakdownByLineItem = false
    var breakdownByProject = false
    var breakdownByAccount = false
    /// Usage quantities without money (DEC-031).
    var usageMetrics = false
    /// Requests per key this month (Google, DEC-035).
    var keyRequests = false
    /// Spend is an approximation computed from usage and published rates; shown with "≈" (DEC-033).
    var spendIsEstimate = false
    /// The provider reports the credit balance, so it is not entered by hand (Cline, DEC-040).
    var reportsBalance = false
}

struct ConnectorDescriptor: Sendable {
    let id: ConnectorID
    let displayName: String
    /// Lowercased, alphanumeric-only names that identify this provider.
    let aliases: [String]
    let credentialFields: [CredentialField]
    let capabilities: ConnectorCapabilities
    let consoleURL: URL
    /// Non-secret description of how the credential is obtained; given to the onboarding AI.
    let credentialSummary: String
    /// Keychain fields of a sign-in session, for connectors without entered credentials (Cline, DEC-040).
    var sessionFields: [String] = []
}

/// A fact about a key reported by the provider, shown on the key page (DEC-030).
struct KeyDetail: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case project, owner, ownerEmail, ownerRole, ownerType, createdBy, keyType, origin, scopes
    }
    var kind: Kind
    var value: String
}

/// A non-fatal remark from a refresh. `id` is stable across refreshes so the user can hide it.
struct ProviderNote: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// Something the user can fix (e.g. missing token scope).
        case warning
        /// A fact about the account, nothing to fix (e.g. no billing data exists).
        case info
    }
    var id: String
    var kind: Kind
    var text: String
}

/// Cost of one key in one month (DEC-030).
struct KeyMonthCost: Sendable, Equatable {
    var keyExternalID: String
    var month: Month
    var amount: Decimal
}

/// One API key (or token) as reported by the provider (REQ-003). `nil` fields are unavailable.
struct ProviderKey: Sendable, Equatable {
    var externalID: String
    var name: String
    var hint: String?
    var createdAt: Date?
    var lastUsedAt: Date?
    var expiresAt: Date?
    var status: String?
    /// Provider-reported cost for the current month; `nil` when not exposed.
    var currentMonthCost: Decimal?
    var details: [KeyDetail] = []
    /// Requests made with the key this month, where the provider reports them (Google, DEC-035).
    var requestsThisMonth: Int? = nil
    /// The key's own page in the provider console, if the provider has one (DEC-035).
    var consoleURL: URL? = nil
}

/// Token counts for one key and model in the current month (DEC-017).
struct TokenUsageRow: Sendable, Equatable {
    var keyExternalID: String?
    var model: String
    var inputTokens: Int
    var cachedInputTokens: Int?
    var outputTokens: Int
    /// Number of model requests, when the provider reports it.
    var requests: Int? = nil
}

/// Everything a connector returns for one refresh.
struct ConnectorSnapshot: Sendable {
    /// Provider-reported cost per UTC day for the covered range.
    var dailyCosts: [Day: Decimal]
    /// First day covered by this snapshot; stored days from here on are replaced.
    var coveredFrom: Day
    /// `nil` when the connector does not provide key details.
    var keys: [ProviderKey]?
    /// `nil` when the connector does not provide token usage.
    var tokenUsage: [TokenUsageRow]?
    /// Monthly usage cost by line item / project (DEC-027); `nil` when not provided.
    var breakdown: [BreakdownRow]? = nil
    /// First month covered by `breakdown`; stored months from here on are replaced.
    var breakdownFrom: Month? = nil
    /// Set when the provider answered but cannot report spend for this account; spend then shows "no data"
    /// with this explanation, and nothing else in the snapshot is affected.
    var spendUnavailableReason: String? = nil
    /// Usage quantities by month and project (DEC-031); `nil` when not provided.
    var usageMetrics: [UsageMetricRow]? = nil
    var usageMetricsFrom: Month? = nil
    /// Non-fatal remarks shown on the service page, e.g. organizations that could not be read (DEC-032).
    var notes: [ProviderNote] = []
    /// Per-key cost by month (DEC-030); `nil` when not provided.
    var keyMonthlyCosts: [KeyMonthCost]? = nil
    /// First month covered by `keyMonthlyCosts`.
    var keyCostsFrom: Month? = nil
    /// Credit balance reported by the provider, USD; stored as the service's balance snapshot (DEC-040).
    var providerBalance: Decimal? = nil
    /// The provider normally reports the balance but could not this time: the stored balance is dropped
    /// ("no data") instead of being shown as current.
    var providerBalanceUnavailable = false
    /// All credit purchases reported by the provider; replaces earlier imported ones, manual ones are kept (DEC-040).
    var creditPurchases: [ProviderCreditPurchase]? = nil
}

/// A credit top-up reported by the provider. Informational for API services (DEC-023).
struct ProviderCreditPurchase: Sendable, Equatable {
    var externalID: String
    var day: Day
    var amount: Decimal
    var volume: String
}

struct FetchRequest: Sendable {
    var credentials: [String: String]
    var from: Day
    var now: Date

    /// First day the provider's answer covers (DEC-015): the start of the first month with any cost, never before `from`.
    /// Months before an account existed come back empty; they are "no data", not a real $0. With no cost at all the
    /// whole request stays covered: an idle account has genuine zero months. Zero-valued entries do not count as data.
    func coverageStart(for dailyCosts: [Day: Decimal]) -> Day {
        dailyCosts.filter { $0.value != 0 }.keys.min().map { max($0.calendarMonth.firstDay, from) } ?? from
    }
}

protocol Connector: Sendable {
    static var descriptor: ConnectorDescriptor { get }
    func fetch(_ request: FetchRequest) async throws -> ConnectorSnapshot
}

/// A connector whose credential is a sign-in session rather than a pasted key (Cline, DEC-040).
/// Before each fetch the refresh engine asks for renewed credentials and saves them to the Keychain at once,
/// so rotated tokens survive a fetch that fails afterwards.
protocol SessionConnector: Connector {
    /// New credentials when the session had to be renewed, `nil` when the stored ones are still valid.
    func refreshedCredentials(_ credentials: [String: String], now: Date) async throws -> [String: String]?
    /// The credentials with the access token marked as expired, so the next refresh renews it.
    func markedExpired(_ credentials: [String: String]) -> [String: String]
}

enum ConnectorError: LocalizedError, Equatable {
    case missingCredential(String)
    case invalidConfiguration(String)
    case http(status: Int, message: String)
    case unauthorized
    /// HTTP 403 with the provider's message.
    case forbidden(String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let field):
            String(localized: "Missing credential field: \(field)")
        case .invalidConfiguration(let detail):
            String(localized: "Invalid configuration: \(detail)")
        case .http(let status, let message):
            String(localized: "Provider returned HTTP \(status): \(message)")
        case .unauthorized:
            String(localized: "The provider rejected the credentials (unauthorized).")
        case .forbidden(let message):
            String(localized: "The provider denied access: \(message)")
        case .malformedResponse(let detail):
            String(localized: "Unexpected provider response: \(detail)")
        }
    }
}

extension FetchRequest {
    func required(_ field: String) throws -> String {
        let value = credentials[field]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { throw ConnectorError.missingCredential(field) }
        return value
    }

    func optional(_ field: String) -> String? {
        let value = credentials[field]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var today: Day { Day(now, calendar: .utc) }
}
