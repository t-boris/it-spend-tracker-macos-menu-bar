import Foundation

/// OpenAI organization Admin API (SRC-002): costs, project API keys, completions token usage.
struct OpenAIConnector: Connector {
    static let descriptor = ConnectorDescriptor(
        id: .openAI,
        displayName: "OpenAI",
        aliases: ["openai", "openaiapi", "openaiplatform"],
        credentialFields: [
            CredentialField(id: "adminKey", label: "Admin API key",
                            help: "Organization owners create it at platform.openai.com → Settings → Organization → Admin keys. Starts with sk-admin-.",
                            isSecret: true),
        ],
        capabilities: ConnectorCapabilities(keyDetails: true, keyLastUsed: true, keyExpiry: true,
                                            keySpend: true, tokenUsage: true,
                                            breakdownByLineItem: true, breakdownByProject: true),
        consoleURL: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!,
        credentialSummary: "An OpenAI Admin API key (prefix sk-admin-), created by an organization owner at https://platform.openai.com/settings/organization/admin-keys. Regular project keys cannot read costs."
    )

    let http: HTTPClient
    private let base = "https://api.openai.com/v1/organization"

    func fetch(_ request: FetchRequest) async throws -> ConnectorSnapshot {
        let key = try request.required("adminKey")
        let monthStart = request.today.calendarMonth.firstDay

        let projects: [Project] = try await list(key: key, path: "/projects", extra: [("include_archived", "true")])
        async let costs = fetchDailyCosts(key: key, from: request.from)
        async let keyCosts = fetchKeyCosts(key: key, from: request.from, monthStart: monthStart)
        async let keys = fetchKeys(key: key, projects: projects)
        async let usage = fetchTokenUsage(key: key, from: monthStart)
        async let breakdown = fetchBreakdown(key: key, from: request.from, monthStart: monthStart, projects: projects)
        let daily = try await costs
        let (monthlyKeyCosts, keyCostsFrom) = try await keyCosts
        var providerKeys = try await keys
        let currentMonth = monthStart.calendarMonth
        for index in providerKeys.indices {
            let id = providerKeys[index].externalID
            providerKeys[index].currentMonthCost = monthlyKeyCosts.map { costs in
                costs.filter { $0.keyExternalID == id && $0.month == currentMonth }.reduce(0) { $0 + $1.amount }
            }
        }
        let (rows, rowsFrom) = try await breakdown
        return ConnectorSnapshot(dailyCosts: daily, coveredFrom: request.coverageStart(for: daily),
                                 keys: providerKeys, tokenUsage: try await usage,
                                 breakdown: rows, breakdownFrom: rowsFrom,
                                 keyMonthlyCosts: monthlyKeyCosts, keyCostsFrom: keyCostsFrom)
    }

    // MARK: Costs

    private struct Page<Item: Decodable>: Decodable {
        let data: [Item]
        let has_more: Bool?
        let next_page: String?
    }

    private struct Bucket<Result: Decodable>: Decodable {
        let start_time: Int
        let results: [Result]
    }

    private struct CostResult: Decodable {
        struct Money: Decodable { let value: FlexibleDecimal? }
        let amount: Money?
        let api_key_id: String?
        let line_item: String?
        let project_id: String?
    }

    /// Organization costs per day for the whole range (backfill included), without grouping.
    private func fetchDailyCosts(key: String, from: Day) async throws -> [Day: Decimal] {
        var daily: [Day: Decimal] = [:]
        for bucket in try await costBuckets(key: key, from: from, groupByKey: false) {
            let day = Day(Date(timeIntervalSince1970: TimeInterval(bucket.start_time)), calendar: .utc)
            daily[day, default: 0] += bucket.results.reduce(Decimal(0)) { $0 + ($1.amount?.value?.value ?? 0) }
        }
        return daily
    }

    /// Cost per API key and month (DEC-030). OpenAI offers `group_by=api_key_id` only for recent ranges and
    /// rejects older start times with HTTP 400 naming the earliest allowed time ("on or after <unix>"), so the
    /// request is retried from that time, then from the current month; if all fail, per-key cost is unavailable.
    private func fetchKeyCosts(key: String, from: Day, monthStart: Day) async throws -> ([KeyMonthCost]?, Month?) {
        var start = from
        var attempts = 0
        while attempts < 3 {
            attempts += 1
            do {
                let buckets = try await costBuckets(key: key, from: start, groupByKey: true)
                struct KeyMonth: Hashable { let key: String; let month: Month }
                var sums: [KeyMonth: Decimal] = [:]
                for bucket in buckets {
                    let month = Day(Date(timeIntervalSince1970: TimeInterval(bucket.start_time)), calendar: .utc).calendarMonth
                    for result in bucket.results {
                        guard let keyID = result.api_key_id else { continue }
                        sums[KeyMonth(key: keyID, month: month), default: 0] += result.amount?.value?.value ?? 0
                    }
                }
                let costs = sums.map { KeyMonthCost(keyExternalID: $0.key.key, month: $0.key.month, amount: $0.value) }
                return (costs, start.calendarMonth)
            } catch ConnectorError.http(status: 400, let message) {
                if let earliest = Self.earliestAllowedDay(in: message), earliest > start, earliest <= monthStart {
                    start = earliest
                } else if start < monthStart {
                    start = monthStart
                } else {
                    return (nil, nil)
                }
            }
        }
        return (nil, nil)
    }

    /// Parses "Try a start_time on or after 1764979200" into the first whole UTC day at or after that time.
    static func earliestAllowedDay(in message: String) -> Day? {
        guard let match = message.firstMatch(of: /on or after (\d{9,11})/), let seconds = TimeInterval(match.1) else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        let day = Day(date, calendar: .utc)
        return day.startDate(calendar: .utc) < date ? day.nextDay : day
    }

    /// Monthly cost by line item and by project (DEC-027). Falls back to the current month, then to
    /// "not provided", when OpenAI rejects the grouping for the range (HTTP 400).
    private func fetchBreakdown(key: String, from: Day, monthStart: Day, projects: [Project]) async throws
        -> ([BreakdownRow]?, Month?) {
        let names = Dictionary(projects.map { ($0.id, $0.name ?? $0.id) }, uniquingKeysWith: { a, _ in a })
        for start in from < monthStart ? [from, monthStart] : [monthStart] {
            do {
                let buckets = try await costBuckets(key: key, from: start, groupBy: ["line_item", "project_id"])
                var rows: [BreakdownRow] = []
                for bucket in buckets {
                    let month = Day(Date(timeIntervalSince1970: TimeInterval(bucket.start_time)), calendar: .utc).calendarMonth
                    for result in bucket.results {
                        let amount = result.amount?.value?.value ?? 0
                        rows.append(BreakdownRow(month: month, dimension: .lineItem,
                                                 label: result.line_item ?? String(localized: "Other"), amount: amount))
                        let project = result.project_id.map { names[$0] ?? $0 } ?? String(localized: "No project")
                        rows.append(BreakdownRow(month: month, dimension: .project, label: project, amount: amount))
                    }
                }
                return (rows.merged(), start.calendarMonth)
            } catch ConnectorError.http(status: 400, _) {
                continue
            }
        }
        return (nil, nil)
    }

    private func costBuckets(key: String, from: Day, groupByKey: Bool) async throws -> [Bucket<CostResult>] {
        try await costBuckets(key: key, from: from, groupBy: groupByKey ? ["api_key_id"] : [])
    }

    private func costBuckets(key: String, from: Day, groupBy: [String]) async throws -> [Bucket<CostResult>] {
        var items = [
            ("start_time", String(Int(from.startDate(calendar: .utc).timeIntervalSince1970))),
            ("bucket_width", "1d"),
            ("limit", "180"),
        ]
        items += groupBy.map { ("group_by[]", $0) }
        return try await paginate(key: key, path: "/costs", items: items)
    }

    // MARK: Keys

    private struct ListPage<Item: Decodable>: Decodable {
        let data: [Item]
        let has_more: Bool?
        let last_id: String?
    }

    private struct Project: Decodable { let id: String; let name: String?; let status: String? }

    private struct APIKey: Decodable {
        struct Owner: Decodable {
            struct Person: Decodable { let name: String?; let email: String?; let role: String? }
            let type: String?
            let user: Person?
            let service_account: Person?
        }
        let id: String
        let name: String?
        let redacted_value: String?
        let created_at: Int?
        let last_used_at: Int?
        let expires_at: Int?
        let owner: Owner?

        func details(project: String?) -> [KeyDetail] {
            let person = owner?.user ?? owner?.service_account
            let pairs: [(KeyDetail.Kind, String?)] = [
                (.project, project),
                (.owner, person?.name),
                (.ownerEmail, person?.email),
                (.ownerRole, person?.role),
                (.ownerType, owner?.type.map { $0 == "service_account" ? "service account" : $0 }),
            ]
            return pairs.compactMap { kind, value in
                value.flatMap { $0.isEmpty ? nil : KeyDetail(kind: kind, value: $0) }
            }
        }
    }

    private func fetchKeys(key: String, projects: [Project]) async throws -> [ProviderKey] {
        var result: [ProviderKey] = []
        // Archived projects are listed only to name their historical costs.
        for project in projects where project.status != "archived" {
            let keys: [APIKey] = try await list(key: key, path: "/projects/\(project.id)/api_keys")
            result += keys.map { apiKey in
                ProviderKey(externalID: apiKey.id,
                            name: apiKey.name ?? apiKey.id,
                            hint: [project.name, apiKey.redacted_value.map(Self.compactRedacted)].compactMap { $0 }.joined(separator: " · "),
                            createdAt: apiKey.created_at.map(Self.date),
                            lastUsedAt: apiKey.last_used_at.map(Self.date),
                            expiresAt: apiKey.expires_at.map(Self.date),
                            status: nil,
                            currentMonthCost: nil,
                            details: apiKey.details(project: project.name))
            }
        }
        return result
    }

    // MARK: Token usage

    private struct UsageResult: Decodable {
        let input_tokens: Int?
        let input_cached_tokens: Int?
        let output_tokens: Int?
        let num_model_requests: Int?
        let api_key_id: String?
        let model: String?
    }

    private func fetchTokenUsage(key: String, from: Day) async throws -> [TokenUsageRow] {
        let buckets: [Bucket<UsageResult>] = try await paginate(key: key, path: "/usage/completions", items: [
            ("start_time", String(Int(from.startDate(calendar: .utc).timeIntervalSince1970))),
            ("bucket_width", "1d"),
            ("group_by[]", "api_key_id"),
            ("group_by[]", "model"),
            ("limit", "31"),
        ])
        var rows: [String: TokenUsageRow] = [:]
        for result in buckets.flatMap(\.results) {
            let model = result.model ?? "—"
            let id = "\(result.api_key_id ?? "")|\(model)"
            var row = rows[id] ?? TokenUsageRow(keyExternalID: result.api_key_id, model: model,
                                                inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, requests: 0)
            row.inputTokens += result.input_tokens ?? 0
            row.cachedInputTokens = (row.cachedInputTokens ?? 0) + (result.input_cached_tokens ?? 0)
            row.outputTokens += result.output_tokens ?? 0
            row.requests = (row.requests ?? 0) + (result.num_model_requests ?? 0)
            rows[id] = row
        }
        return rows.values.sorted { ($0.keyExternalID ?? "", $0.model) < ($1.keyExternalID ?? "", $1.model) }
    }

    // MARK: Plumbing

    private func request(key: String, path: String, items: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: .api(base + path, items))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func paginate<Item: Decodable>(key: String, path: String, items: [(String, String)]) async throws -> [Item] {
        var all: [Item] = []
        var cursor: String?
        repeat {
            let query = items + (cursor.map { [("page", $0)] } ?? [])
            let page = try await http.fetchJSON(Page<Item>.self, request(key: key, path: path, items: query))
            all += page.data
            cursor = page.has_more == true ? page.next_page : nil
        } while cursor != nil
        return all
    }

    private func list<Item: Decodable>(key: String, path: String, extra: [(String, String)] = []) async throws -> [Item] {
        var all: [Item] = []
        var after: String?
        repeat {
            let query = [("limit", "100")] + extra + (after.map { [("after", $0)] } ?? [])
            let page = try await http.fetchJSON(ListPage<Item>.self, request(key: key, path: path, items: query))
            all += page.data
            after = page.has_more == true ? page.last_id : nil
        } while after != nil
        return all
    }

    /// Service-account keys come back as "sk-svcac" followed by ~150 asterisks; collapse masks to "…".
    static func compactRedacted(_ value: String) -> String {
        value.replacingOccurrences(of: #"\*+"#, with: "…", options: .regularExpression)
    }

    private static func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
}
