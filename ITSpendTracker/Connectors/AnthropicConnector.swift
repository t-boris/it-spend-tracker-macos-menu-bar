import Foundation

/// Anthropic Admin API (SRC-002): cost report, API keys, messages token usage.
/// The cost report cannot be grouped by key and keys have no last-used field, so both show as unavailable.
struct AnthropicConnector: Connector {
    static let descriptor = ConnectorDescriptor(
        id: .anthropic,
        displayName: "Anthropic",
        aliases: ["anthropic", "anthropicapi", "claudeapi", "claudeplatform", "claudeconsole"],
        credentialFields: [
            CredentialField(id: "adminKey", label: "Admin API key",
                            help: "Created at platform.claude.com → Settings → Admin keys by an organization admin; starts with sk-ant-admin. Individual accounts (“… Individual Org”) have no Admin keys page: first click “Convert to team” in Console → Settings → Organization.",
                            isSecret: true),
        ],
        capabilities: ConnectorCapabilities(keyDetails: true, keyLastUsed: false, keyExpiry: true,
                                            keySpend: false, tokenUsage: true,
                                            breakdownByLineItem: true, breakdownByProject: true),
        consoleURL: URL(string: "https://platform.claude.com/settings/admin-keys")!,
        credentialSummary: "An Anthropic Admin API key (prefix sk-ant-admin), created by an organization admin at https://platform.claude.com/settings/admin-keys. The Admin API is unavailable for individual accounts: if the Admin keys page is missing (the organization is named '... Individual Org'), the user must first click 'Convert to team' under 'Convert to team organization' in Console → Settings → Organization; an admin of the individual org remains admin. Regular workspace API keys cannot read costs. A Claude Pro/Max subscription on claude.ai is billed separately and has no API; it is entered as a subscription."
    )

    let http: HTTPClient
    private let base = "https://api.anthropic.com/v1/organizations"

    func fetch(_ request: FetchRequest) async throws -> ConnectorSnapshot {
        let key = try request.required("adminKey")
        let monthStart = request.today.calendarMonth.firstDay
        async let costs = fetchCosts(key: key, from: request.from)
        async let keys = fetchKeys(key: key)
        async let usage = fetchTokenUsage(key: key, from: monthStart)
        async let breakdown = fetchBreakdown(key: key, from: request.from)
        let rows = try await breakdown
        let daily = try await costs
        return ConnectorSnapshot(dailyCosts: daily, coveredFrom: request.coverageStart(for: daily),
                                 keys: try await keys, tokenUsage: try await usage,
                                 breakdown: rows, breakdownFrom: rows == nil ? nil : request.from.calendarMonth)
    }

    private struct Page<Item: Decodable>: Decodable {
        let data: [Item]
        let has_more: Bool?
        let next_page: String?
    }

    private struct Bucket<Result: Decodable>: Decodable {
        let starting_at: String
        let results: [Result]
    }

    private struct CostResult: Decodable {
        /// Decimal string in cents, e.g. "123.45" = 1.2345 USD.
        let amount: FlexibleDecimal?
    }

    private func fetchCosts(key: String, from: Day) async throws -> [Day: Decimal] {
        let buckets: [Bucket<CostResult>] = try await paginate(key: key, path: "/cost_report", items: [
            ("starting_at", Self.rfc3339(from)),
            ("bucket_width", "1d"),
            ("limit", "31"),
        ])
        var daily: [Day: Decimal] = [:]
        for bucket in buckets {
            guard let day = Day(isoPrefix: bucket.starting_at) else {
                throw ConnectorError.malformedResponse("bucket date \(bucket.starting_at)")
            }
            let cents = bucket.results.reduce(Decimal(0)) { $0 + ($1.amount?.value ?? 0) }
            daily[day, default: 0] += cents / 100
        }
        return daily
    }

    private struct GroupedCost: Decodable {
        let amount: FlexibleDecimal?
        let description: String?
        let model: String?
        let cost_type: String?
        let workspace_id: String?
    }

    private struct Workspace: Decodable { let id: String; let name: String? }

    private struct WorkspacePage: Decodable {
        let data: [Workspace]
        let has_more: Bool?
        let last_id: String?
    }

    /// Monthly cost by description (model / cost type) and by workspace (DEC-027).
    /// A rejected grouping returns `nil` instead of failing the refresh.
    private func fetchBreakdown(key: String, from: Day) async throws -> [BreakdownRow]? {
        let buckets: [Bucket<GroupedCost>]
        do {
            buckets = try await paginate(key: key, path: "/cost_report", items: [
                ("starting_at", Self.rfc3339(from)),
                ("bucket_width", "1d"),
                ("group_by[]", "description"),
                ("group_by[]", "workspace_id"),
                ("limit", "31"),
            ])
        } catch ConnectorError.http(status: 400, _) {
            return nil
        }
        let names = await workspaceNames(key: key)
        var rows: [BreakdownRow] = []
        for bucket in buckets {
            guard let month = Day(isoPrefix: bucket.starting_at)?.calendarMonth else { continue }
            for result in bucket.results {
                let amount = (result.amount?.value ?? 0) / 100
                let item = result.description ?? [result.model, result.cost_type].compactMap { $0 }.joined(separator: ", ")
                rows.append(BreakdownRow(month: month, dimension: .lineItem,
                                         label: item.isEmpty ? String(localized: "Other") : item, amount: amount))
                let workspace = result.workspace_id.map { names[$0] ?? $0 } ?? String(localized: "Default workspace")
                rows.append(BreakdownRow(month: month, dimension: .project, label: workspace, amount: amount))
            }
        }
        return rows.merged()
    }

    /// Workspace names for labels; IDs are shown if the list cannot be read.
    private func workspaceNames(key: String) async -> [String: String] {
        var names: [String: String] = [:]
        var after: String?
        repeat {
            let query = [("limit", "100"), ("include_archived", "true")] + (after.map { [("after_id", $0)] } ?? [])
            guard let page = try? await http.fetchJSON(WorkspacePage.self, request(key: key, path: "/workspaces", items: query))
            else { return names }
            for workspace in page.data { names[workspace.id] = workspace.name ?? workspace.id }
            after = page.has_more == true ? page.last_id : nil
        } while after != nil
        return names
    }

    private struct KeyPage: Decodable {
        let data: [APIKey]
        let has_more: Bool?
        let last_id: String?
    }

    private struct APIKey: Decodable {
        let id: String
        let name: String?
        let partial_key_hint: String?
        let created_at: String?
        let expires_at: String?
        let status: String?
        let workspace_id: String?
        let created_by: Creator?

        struct Creator: Decodable { let id: String?; let type: String? }

        func details(workspaces: [String: String]) -> [KeyDetail] {
            let workspace = workspace_id.map { workspaces[$0] ?? $0 } ?? String(localized: "Default workspace")
            var result = [KeyDetail(kind: .project, value: workspace)]
            if let creator = [created_by?.type, created_by?.id].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                result.append(KeyDetail(kind: .createdBy, value: creator))
            }
            return result
        }
    }

    private func fetchKeys(key: String) async throws -> [ProviderKey] {
        let workspaces = await workspaceNames(key: key)
        var result: [ProviderKey] = []
        var after: String?
        repeat {
            let query = [("limit", "1000")] + (after.map { [("after_id", $0)] } ?? [])
            let page = try await http.fetchJSON(KeyPage.self, request(key: key, path: "/api_keys", items: query))
            result += page.data.filter { $0.status != "archived" }.map { apiKey in
                ProviderKey(externalID: apiKey.id,
                            name: apiKey.name ?? apiKey.id,
                            hint: apiKey.partial_key_hint,
                            createdAt: apiKey.created_at.flatMap(Self.parseDate),
                            lastUsedAt: nil,
                            expiresAt: apiKey.expires_at.flatMap(Self.parseDate),
                            status: apiKey.status,
                            currentMonthCost: nil,
                            details: apiKey.details(workspaces: workspaces))
            }
            after = page.has_more == true ? page.last_id : nil
        } while after != nil
        return result
    }

    private struct UsageResult: Decodable {
        struct CacheCreation: Decodable {
            let ephemeral_1h_input_tokens: Int?
            let ephemeral_5m_input_tokens: Int?
        }
        let api_key_id: String?
        let model: String?
        let uncached_input_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation: CacheCreation?
        let output_tokens: Int?
    }

    private func fetchTokenUsage(key: String, from: Day) async throws -> [TokenUsageRow] {
        let buckets: [Bucket<UsageResult>] = try await paginate(key: key, path: "/usage_report/messages", items: [
            ("starting_at", Self.rfc3339(from)),
            ("bucket_width", "1d"),
            ("group_by[]", "api_key_id"),
            ("group_by[]", "model"),
            ("limit", "31"),
        ])
        var rows: [String: TokenUsageRow] = [:]
        for result in buckets.flatMap(\.results) {
            let model = result.model ?? "—"
            let id = "\(result.api_key_id ?? "")|\(model)"
            let cacheWrite = (result.cache_creation?.ephemeral_1h_input_tokens ?? 0)
                + (result.cache_creation?.ephemeral_5m_input_tokens ?? 0)
            let cacheRead = result.cache_read_input_tokens ?? 0
            var row = rows[id] ?? TokenUsageRow(keyExternalID: result.api_key_id, model: model,
                                                inputTokens: 0, cachedInputTokens: 0, outputTokens: 0)
            row.inputTokens += (result.uncached_input_tokens ?? 0) + cacheRead + cacheWrite
            row.cachedInputTokens = (row.cachedInputTokens ?? 0) + cacheRead
            row.outputTokens += result.output_tokens ?? 0
            rows[id] = row
        }
        return rows.values.sorted { ($0.keyExternalID ?? "", $0.model) < ($1.keyExternalID ?? "", $1.model) }
    }

    private func request(key: String, path: String, items: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: .api(base + path, items))
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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

    private static func rfc3339(_ day: Day) -> String { "\(day)T00:00:00Z" }

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
