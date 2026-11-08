import Foundation

/// Neon: usage metrics from the consumption history API (DEC-031, SRC-002). Neon reports usage, not money,
/// so spend comes from subscriptions the user enters; no cost is estimated.
struct NeonConnector: Connector {
    static let descriptor = ConnectorDescriptor(
        id: .neon,
        displayName: "Neon",
        aliases: ["neon", "neontech", "neondb", "neonpostgres"],
        credentialFields: [
            CredentialField(id: "apiKey", label: "API key",
                            help: "Create at console.neon.tech → Account settings → API keys (personal) or Organization settings → API keys. Usage history needs a paid Neon plan.",
                            isSecret: true),
        ],
        capabilities: ConnectorCapabilities(dailySpend: false, keyDetails: true, keyLastUsed: true, breakdownByLineItem: true,
                                            breakdownByProject: true, usageMetrics: true, spendIsEstimate: true),
        consoleURL: URL(string: "https://console.neon.tech/app/settings/api-keys")!,
        credentialSummary: "A Neon API key: personal (console.neon.tech → Account settings → API keys) or organization (Organization settings → API keys, admins only). The consumption history API that reports usage requires a paid plan (Launch, Scale, Agent, Business or Enterprise). Neon's API has no money data, so the plan or invoice amount is entered as a subscription."
    )

    let http: HTTPClient
    private let base = "https://console.neon.tech/api/v2"

    func fetch(_ request: FetchRequest) async throws -> ConnectorSnapshot {
        let key = try request.required("apiKey")
        let organizations = try await http.fetchJSON(Organizations.self, self.request(key: key, path: "/users/me/organizations", items: []))
            .organizations
        // Monthly history is available for the last year only.
        let firstMonth = max(request.from.calendarMonth, request.today.calendarMonth.adding(months: -11))
        var metrics: [UsageMetricRow] = []
        var notes: [ProviderNote] = []
        for organization in organizations {
            do {
                let names = try await projectNames(key: key, organizationID: organization.id)
                // Monthly buckets for history; the month in progress is not in them yet, so it is summed from
                // daily buckets (Neon keeps 60 days of daily data).
                let currentMonth = request.today.calendarMonth
                let monthly = try await consumption(key: key, organizationID: organization.id, organizationName: organization.name ?? organization.id,
                                                    from: firstMonth.firstDay, to: currentMonth.next.firstDay,
                                                    granularity: "monthly", projectNames: names)
                let daily = try await consumption(key: key, organizationID: organization.id, organizationName: organization.name ?? organization.id,
                                                  from: currentMonth.firstDay, to: request.today.nextDay,
                                                  granularity: "daily", projectNames: names)
                metrics += monthly.filter { $0.month != currentMonth } + daily.filter { $0.month == currentMonth }
            } catch let error as ConnectorError {
                // A free organization has no consumption history: informational, not an error.
                let isPlanLimit: Bool = if case .forbidden = error { true } else { false }
                notes.append(ProviderNote(id: "neon.org.\(organization.id)", kind: isPlanLimit ? .info : .warning,
                                          text: String(localized: "\(organization.name ?? organization.id): usage not available (\(error.localizedDescription))")))
            }
        }
        let keys = try? await apiKeys(key: key)
        let usage = metrics.merged()
        // The approximate cost (usage × plan rates, DEC-033) is Neon's spend, booked on the first day of each month.
        var daily: [Day: Decimal] = [:]
        var breakdown: [BreakdownRow] = []
        let severalOrganizations = Set(usage.compactMap(\.organization)).count > 1
        for row in usage {
            guard let cost = NeonPricing.cost(metric: row.metric, value: row.value, plan: row.plan), cost != 0 else { continue }
            daily[row.month.firstDay, default: 0] += cost
            let title = UsageMetricKind(rawValue: row.metric).map { String(localized: $0.title) } ?? row.metric
            breakdown.append(BreakdownRow(month: row.month, dimension: .lineItem, label: title, amount: cost))
            breakdown.append(BreakdownRow(month: row.month, dimension: .project, label: row.label(showingOrganization: severalOrganizations), amount: cost))
        }
        return ConnectorSnapshot(dailyCosts: daily, coveredFrom: firstMonth.firstDay, keys: keys, tokenUsage: nil,
                                 breakdown: breakdown.merged(), breakdownFrom: firstMonth,
                                 usageMetrics: usage, usageMetricsFrom: firstMonth, notes: notes)
    }

    // MARK: Organizations and projects

    private struct Organizations: Decodable {
        struct Organization: Decodable { let id: String; let name: String? }
        let organizations: [Organization]
    }

    private struct Projects: Decodable {
        struct Project: Decodable { let id: String; let name: String? }
        struct Pagination: Decodable { let cursor: String? }
        let projects: [Project]
        let pagination: Pagination?
    }

    private func projectNames(key: String, organizationID: String) async throws -> [String: String] {
        var names: [String: String] = [:]
        var cursor: String?
        repeat {
            var items = [("org_id", organizationID), ("limit", "400")]
            if let cursor { items.append(("cursor", cursor)) }
            let page = try await http.fetchJSON(Projects.self, request(key: key, path: "/projects", items: items))
            for project in page.projects { names[project.id] = project.name ?? project.id }
            let next = page.pagination?.cursor
            cursor = page.projects.isEmpty || next == cursor ? nil : next
        } while cursor != nil
        return names
    }

    // MARK: Consumption

    private struct Consumption: Decodable {
        struct Project: Decodable {
            struct Period: Decodable {
                let period_plan: String?
                struct Timeframe: Decodable {
                    struct Metric: Decodable { let metric_name: String; let value: FlexibleDecimal? }
                    let timeframe_start: String
                    let metrics: [Metric]?
                }
                let consumption: [Timeframe]?
            }
            let project_id: String
            let periods: [Period]?
        }
        struct Pagination: Decodable { let cursor: String? }
        let projects: [Project]
        let pagination: Pagination?
    }

    /// `to` is the exclusive end of the bucket that contains now. Neon rounds `from` and `to` down to the bucket
    /// start, so `to = now` would drop the bucket in progress and, on its first day, send an empty range (HTTP 400).
    private func consumption(key: String, organizationID: String, organizationName: String, from: Day, to: Day,
                             granularity: String, projectNames: [String: String]) async throws -> [UsageMetricRow] {
        let metricNames = UsageMetricKind.allCases.map(\.rawValue).joined(separator: ",")
        var rows: [UsageMetricRow] = []
        var cursor: String?
        repeat {
            var items = [("org_id", organizationID), ("from", "\(from)T00:00:00Z"),
                         ("to", "\(to)T00:00:00Z"), ("granularity", granularity),
                         ("metrics", metricNames), ("limit", "100")]
            if let cursor { items.append(("cursor", cursor)) }
            let page = try await http.fetchJSON(Consumption.self, request(key: key, path: "/consumption_history/v2/projects", items: items))
            for project in page.projects {
                let name = projectNames[project.project_id] ?? project.project_id
                for period in project.periods ?? [] {
                    for timeframe in period.consumption ?? [] {
                        guard let month = Day(isoPrefix: timeframe.timeframe_start)?.calendarMonth else { continue }
                        for metric in timeframe.metrics ?? [] {
                            guard let kind = UsageMetricKind(rawValue: metric.metric_name), let raw = metric.value?.value else { continue }
                            rows.append(UsageMetricRow(month: month, project: name, metric: kind.rawValue,
                                                       value: raw / kind.divisor, plan: period.period_plan,
                                                       organization: organizationName))
                        }
                    }
                }
            }
            let next = page.pagination?.cursor
            cursor = page.projects.isEmpty || next == cursor ? nil : next
        } while cursor != nil
        return rows
    }

    // MARK: API keys

    private struct APIKey: Decodable {
        let id: FlexibleNumber
        let name: String?
        let created_at: String?
        let last_used_at: String?
        let revoked: Bool?
    }

    private func apiKeys(key: String) async throws -> [ProviderKey] {
        let keys = try await http.fetchJSON([APIKey].self, request(key: key, path: "/api_keys", items: []))
        let parser = ISO8601DateFormatter()
        return keys.filter { $0.revoked != true }.map { apiKey in
            ProviderKey(externalID: apiKey.id.text, name: apiKey.name ?? apiKey.id.text, hint: nil,
                        createdAt: apiKey.created_at.flatMap(parser.date(from:)),
                        lastUsedAt: apiKey.last_used_at.flatMap(parser.date(from:)),
                        expiresAt: nil, status: nil, currentMonthCost: nil)
        }
    }

    private func request(key: String, path: String, items: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: .api(base + path, items))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
