import Foundation
import Security
import Testing
@testable import ITSpendTracker

/// Returns canned responses by URL path (+ optional query match) and records requests.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    struct Route {
        let path: String
        let query: String?
        let status: Int
        let body: String
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private(set) var requests: [URLRequest] = []

    func on(_ path: String, query: String? = nil, status: Int = 200, _ body: String) {
        routes.append(Route(path: path, query: query, status: status, body: body))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let url = request.url!
        let query = url.query(percentEncoded: false) ?? ""
        guard let route = routes.last(where: { $0.path == url.path() && ($0.query.map { query.contains($0) } ?? true) }) else {
            return (Data("not found".utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (Data(route.body.utf8), HTTPURLResponse(url: url, statusCode: route.status, httpVersion: nil, headerFields: nil)!)
    }

    var allRequests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private let now = Date(timeIntervalSince1970: 1_790_726_400) // 2026-09-30 00:00 UTC
private func fetch(_ credentials: [String: String], from: Day = Day(year: 2026, month: 9, day: 1)) -> FetchRequest {
    FetchRequest(credentials: credentials, from: from, now: now)
}

@Suite struct OpenAIConnectorTests {
    @Test func aggregatesCostsKeysAndTokens() async throws {
        let http = StubHTTP()
        // Full-range daily costs (no grouping), paginated.
        http.on("/v1/organization/costs", """
        {"data":[{"start_time":1788220800,"results":[{"amount":{"value":1.75,"currency":"usd"}}]}],
         "has_more":true,"next_page":"p2"}
        """)
        http.on("/v1/organization/costs", query: "page=p2", """
        {"data":[{"start_time":1788307200,"results":[{"amount":{"value":2,"currency":"usd"}}]}],
         "has_more":false,"next_page":null}
        """)
        // Current-month costs grouped by key.
        http.on("/v1/organization/costs", query: "group_by[]=api_key_id", """
        {"data":[{"start_time":1788220800,"results":[{"amount":{"value":1.5,"currency":"usd"},"api_key_id":"key_a"},
                                                     {"amount":{"value":0.25,"currency":"usd"},"api_key_id":null}]},
                 {"start_time":1788307200,"results":[{"amount":{"value":2,"currency":"usd"},"api_key_id":"key_a"}]}],
         "has_more":false,"next_page":null}
        """)
        http.on("/v1/organization/projects", #"{"data":[{"id":"proj_1","name":"Main"},{"id":"proj_old","name":"Old","status":"archived"}],"has_more":false}"#)
        http.on("/v1/organization/costs", query: "group_by[]=line_item", """
        {"data":[{"start_time":1788220800,"results":[
          {"amount":{"value":1.5,"currency":"usd"},"line_item":"gpt-6, input","project_id":"proj_1"},
          {"amount":{"value":0.25,"currency":"usd"},"line_item":"web search","project_id":null}]}],"has_more":false}
        """)
        http.on("/v1/organization/projects/proj_1/api_keys", """
        {"data":[{"id":"key_a","name":"Bot","redacted_value":"sk-...xyz","created_at":1780000000,
                  "last_used_at":1790000000,"expires_at":1791000000,
                  "owner":{"type":"user","user":{"name":"Alex","email":"b@example.com","role":"owner"}}}],"has_more":false}
        """)
        http.on("/v1/organization/usage/completions", """
        {"data":[{"start_time":1788220800,"results":[
          {"input_tokens":1000,"input_cached_tokens":400,"output_tokens":50,"api_key_id":"key_a","model":"gpt-6"},
          {"input_tokens":10,"input_cached_tokens":0,"output_tokens":5,"api_key_id":"key_a","model":"gpt-6"}]}],"has_more":false}
        """)
        let snapshot = try await OpenAIConnector(http: http).fetch(fetch(["adminKey": "sk-admin-test"]))
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 1)] == 1.75)
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 2)] == 2)
        let key = try #require(snapshot.keys?.first)
        #expect(key.name == "Bot")
        #expect(key.currentMonthCost == 3.5)
        #expect(key.expiresAt == Date(timeIntervalSince1970: 1_791_000_000))
        #expect(key.details.contains(KeyDetail(kind: .owner, value: "Alex")))
        #expect(key.details.contains(KeyDetail(kind: .ownerEmail, value: "b@example.com")))
        #expect(key.details.contains(KeyDetail(kind: .project, value: "Main")))
        #expect(snapshot.keyMonthlyCosts?.contains(KeyMonthCost(keyExternalID: "key_a", month: Month(year: 2026, month: 9), amount: 3.5)) == true)
        #expect(snapshot.tokenUsage == [TokenUsageRow(keyExternalID: "key_a", model: "gpt-6", inputTokens: 1010,
                                                      cachedInputTokens: 400, outputTokens: 55, requests: 0)])
        #expect(http.allRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-admin-test" })
        #expect(http.allRequests.allSatisfy { $0.url?.host() == "api.openai.com" })
        let rows = try #require(snapshot.breakdown)
        #expect(rows.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .project, label: "Main", amount: 1.5)))
        #expect(rows.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .lineItem, label: "web search", amount: 0.25)))
        #expect(snapshot.breakdownFrom == Month(year: 2026, month: 9))
        // Keys of archived projects are not listed.
        #expect(!http.allRequests.contains { $0.url?.path() == "/v1/organization/projects/proj_old/api_keys" })
        // Key grouping is only requested from the start of the current month (OpenAI rejects older ranges).
        let grouped = http.allRequests.filter { $0.url?.query(percentEncoded: false)?.contains("group_by[]=api_key_id") == true
            && $0.url?.path() == "/v1/organization/costs" }
        #expect(grouped.count == 1) // the line_item/project grouping is a separate request
        #expect(grouped.first?.url?.query(percentEncoded: false)?.contains("start_time=1788220800") == true)
    }

    @Test func backfillSucceedsWhenKeyGroupingIsRejected() async throws {
        let http = StubHTTP()
        http.on("/v1/organization/costs", """
        {"data":[{"start_time":1757030400,"results":[{"amount":{"value":3,"currency":"usd"}}]}],"has_more":false}
        """)
        http.on("/v1/organization/costs", query: "group_by[]=api_key_id", status: 400, """
        {"error":{"message":"group_by=api_key_id is not available for this time range.","param":"start_time"}}
        """)
        http.on("/v1/organization/costs", query: "group_by[]=line_item", status: 400, """
        {"error":{"message":"group_by=line_item is not available for this time range.","param":"start_time"}}
        """)
        http.on("/v1/organization/projects", #"{"data":[{"id":"proj_1"}],"has_more":false}"#)
        http.on("/v1/organization/projects/proj_1/api_keys", #"{"data":[{"id":"key_a","name":"Bot"}],"has_more":false}"#)
        http.on("/v1/organization/usage/completions", #"{"data":[],"has_more":false}"#)
        let snapshot = try await OpenAIConnector(http: http)
            .fetch(fetch(["adminKey": "k"], from: Day(year: 2025, month: 9, day: 1)))
        #expect(snapshot.dailyCosts[Day(year: 2025, month: 9, day: 5)] == 3)
        #expect(snapshot.keys?.first?.currentMonthCost == nil)
        #expect(snapshot.breakdown == nil) // grouping rejected for both ranges → not provided
    }

    @Test func parsesEarliestAllowedTimeFromError() {
        let message = #"{"error":{"message":"group_by=api_key_id is not available for this time range. Try a start_time on or after 1764979200."}}"#
        #expect(OpenAIConnector.earliestAllowedDay(in: message) == Day(year: 2025, month: 12, day: 6))
        #expect(OpenAIConnector.earliestAllowedDay(in: "something else") == nil)
    }

    @Test func perKeyHistoryRetriesFromEarliestAllowedTime() async throws {
        let http = StubHTTP()
        http.on("/v1/organization/costs", #"{"data":[],"has_more":false}"#)
        http.on("/v1/organization/costs", query: "group_by[]=api_key_id", status: 400, """
        {"error":{"message":"group_by=api_key_id is not available for this time range. Try a start_time on or after 1764979200."}}
        """)
        http.on("/v1/organization/costs", query: "start_time=1764979200&bucket_width=1d&limit=180&group_by[]=api_key_id", """
        {"data":[{"start_time":1767225600,"results":[{"amount":{"value":2,"currency":"usd"},"api_key_id":"key_a"}]}],"has_more":false}
        """)
        http.on("/v1/organization/projects", #"{"data":[],"has_more":false}"#)
        http.on("/v1/organization/usage/completions", #"{"data":[],"has_more":false}"#)
        let snapshot = try await OpenAIConnector(http: http).fetch(fetch(["adminKey": "k"], from: Day(year: 2025, month: 9, day: 1)))
        #expect(snapshot.keyCostsFrom == Month(year: 2025, month: 12))
        #expect(snapshot.keyMonthlyCosts == [KeyMonthCost(keyExternalID: "key_a", month: Month(year: 2026, month: 1), amount: 2)])
    }

    @Test func redactedKeysAreCompacted() {
        #expect(OpenAIConnector.compactRedacted("sk-svcac" + String(repeating: "*", count: 150) + "AB12") == "sk-svcac…AB12")
    }

    @Test func unauthorizedIsReported() async {
        let http = StubHTTP()
        http.on("/v1/organization/costs", status: 401, "{}")
        http.on("/v1/organization/projects", #"{"data":[],"has_more":false}"#)
        http.on("/v1/organization/usage/completions", #"{"data":[],"has_more":false}"#)
        await #expect(throws: ConnectorError.unauthorized) {
            try await OpenAIConnector(http: http).fetch(fetch(["adminKey": "bad"]))
        }
    }

    @Test func missingKeyIsReported() async {
        await #expect(throws: ConnectorError.missingCredential("adminKey")) {
            try await OpenAIConnector(http: StubHTTP()).fetch(fetch([:]))
        }
    }
}

@Suite struct AnthropicConnectorTests {
    @Test func convertsCentStringsAndReadsKeys() async throws {
        let http = StubHTTP()
        http.on("/v1/organizations/cost_report", """
        {"data":[{"starting_at":"2026-09-01T00:00:00Z","ending_at":"2026-09-02T00:00:00Z",
                  "results":[{"amount":"123.45","currency":"USD"},{"amount":"76.55","currency":"USD"}]}],
         "has_more":false,"next_page":null}
        """)
        http.on("/v1/organizations/cost_report", query: "group_by[]=description", """
        {"data":[{"starting_at":"2026-09-01T00:00:00Z","results":[
          {"amount":"50","currency":"USD","description":"Claude Opus 5 Usage - Input Tokens","workspace_id":"wrkspc_1"},
          {"amount":"25","currency":"USD","description":"Claude Opus 5 Usage - Input Tokens","workspace_id":null}]}],"has_more":false}
        """)
        http.on("/v1/organizations/workspaces", #"{"data":[{"id":"wrkspc_1","name":"Research"}],"has_more":false}"#)
        http.on("/v1/organizations/api_keys", """
        {"data":[{"id":"apikey_1","name":"Prod","partial_key_hint":"sk-ant-api03-R2D...igAA","created_at":"2026-01-01T00:00:00Z",
                  "expires_at":"2026-10-05T00:00:00Z","status":"active"},
                 {"id":"apikey_2","name":"Old","status":"archived"}],"has_more":false,"last_id":"apikey_2"}
        """)
        http.on("/v1/organizations/usage_report/messages", """
        {"data":[{"starting_at":"2026-09-01T00:00:00Z","results":[{"api_key_id":"apikey_1","model":"claude-opus-5",
          "uncached_input_tokens":100,"cache_read_input_tokens":20,"cache_creation":{"ephemeral_1h_input_tokens":5,"ephemeral_5m_input_tokens":0},
          "output_tokens":7}]}],"has_more":false}
        """)
        let snapshot = try await AnthropicConnector(http: http).fetch(fetch(["adminKey": "sk-ant-admin01-x"]))
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 1)] == 2)
        #expect(snapshot.keys?.map(\.name) == ["Prod"])
        #expect(snapshot.keys?.first?.lastUsedAt == nil)
        #expect(snapshot.keys?.first?.currentMonthCost == nil)
        let rows = try #require(snapshot.breakdown)
        #expect(rows.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .project, label: "Research", amount: 0.5)))
        #expect(rows.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .project, label: "Default workspace", amount: 0.25)))
        #expect(rows.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .lineItem, label: "Claude Opus 5 Usage - Input Tokens", amount: 0.75)))
        #expect(snapshot.tokenUsage?.first == TokenUsageRow(keyExternalID: "apikey_1", model: "claude-opus-5",
                                                            inputTokens: 125, cachedInputTokens: 20, outputTokens: 7))
        let request = try #require(http.allRequests.first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-admin01-x")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }
}

@Suite struct VercelConnectorTests {
    @Test func sumsBilledCostPerDayFromJSONL() async throws {
        let http = StubHTTP()
        http.on("/v1/billing/charges", """
        {"BilledCost":"0","EffectiveCost":"1.50","BillingCurrency":"USD","ChargePeriodStart":"2026-09-03T00:00:00Z","ServiceName":"Functions","Tags":{"ProjectName":"site"}}
        {"BilledCost":0,"EffectiveCost":2.25,"BillingCurrency":"USD","ChargePeriodStart":"2026-09-03T00:00:00Z"}

        {"BilledCost":"-0.75","BillingCurrency":"USD","ChargePeriodStart":"2026-09-04T00:00:00Z"}
        """)
        http.on("/v6/user/tokens", """
        {"tokens":[{"id":"t1","name":"CI","prefix":"vcp_","suffix":"abcd","createdAt":1780000000000,
                    "activeAt":1790000000000,"expiresAt":null}],"pagination":{"next":null}}
        """)
        let snapshot = try await VercelConnector(http: http).fetch(fetch(["token": "vcp_x", "teamId": "team_1"]))
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 3)] == 3.75)
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 4)] == -0.75)
        #expect(snapshot.keys?.first?.lastUsedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(snapshot.tokenUsage == nil)
        #expect(snapshot.breakdown?.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .project, label: "site", amount: 1.5)) == true)
        let charges = try #require(http.allRequests.first { $0.url?.path() == "/v1/billing/charges" })
        #expect(charges.url?.query()?.contains("teamId=team_1") == true)
    }

    @Test func acceptsStringPaginationAndTimestamps() async throws {
        let http = StubHTTP()
        http.on("/v1/billing/charges", #"{"BilledCost":"2","ChargePeriodStart":"2026-09-03T00:00:00Z"}"#)
        http.on("/v6/user/tokens", """
        {"tokens":[{"id":"t1","name":"CI","createdAt":"1780000000000","activeAt":1790000000000}],"pagination":{"next":"1779999999999"}}
        """)
        http.on("/v6/user/tokens", query: "until=1779999999999", #"{"tokens":[],"pagination":{"next":null}}"#)
        let snapshot = try await VercelConnector(http: http).fetch(fetch(["token": "t"]))
        #expect(snapshot.keys?.map(\.name) == ["CI"])
        #expect(snapshot.keys?.first?.createdAt == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 3)] == 2)
    }

    @Test func rangesWithoutDataAreSkippedAndCoverageStartsAtData() async throws {
        let http = StubHTTP()
        http.on("/v1/billing/charges", status: 404, #"{"error":{"code":"costs_not_found","message":"Costs not found"}}"#)
        http.on("/v1/billing/charges", query: "from=2026-09-01", """
        {"BilledCost":0,"EffectiveCost":"0.6667","ChargePeriodStart":"2026-09-10T00:00:00Z","ServiceName":"Pro"}
        {"BilledCost":0,"EffectiveCost":"0.05","ChargePeriodStart":"2026-09-11T00:00:00Z","ServiceName":"Build CPU Minutes"}
        """)
        http.on("/v6/user/tokens", #"{"tokens":[]}"#)
        let snapshot = try await VercelConnector(http: http).fetch(fetch(["token": "t"], from: Day(year: 2025, month: 9, day: 1)))
        #expect(snapshot.spendUnavailableReason == nil)
        #expect(snapshot.coveredFrom == Day(year: 2026, month: 9, day: 1))
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 10)] == Decimal(string: "0.6667"))
        #expect(snapshot.breakdown?.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .lineItem, label: "Pro",
                                                          amount: Decimal(string: "0.6667")!)) == true)
    }

    @Test func missingBillingDataIsNoDataNotZero() async throws {
        let http = StubHTTP()
        http.on("/v1/billing/charges", status: 404, #"{"error":{"code":"costs_not_found","message":"Costs not found"}}"#)
        http.on("/v6/user/tokens", #"{"tokens":[{"id":"t1","name":"CI"}]}"#)
        let snapshot = try await VercelConnector(http: http).fetch(fetch(["token": "t"]))
        #expect(snapshot.spendUnavailableReason != nil)
        #expect(snapshot.keys?.map(\.name) == ["CI"])
    }

    @Test func otherNotFoundErrorsStillFail() async {
        let http = StubHTTP()
        http.on("/v1/billing/charges", status: 404, #"{"error":{"code":"team_not_found","message":"Team not found"}}"#)
        http.on("/v6/user/tokens", #"{"tokens":[]}"#)
        await #expect(throws: ConnectorError.self) {
            try await VercelConnector(http: http).fetch(fetch(["token": "t"]))
        }
    }

    @Test func unreadableTokenListDoesNotFailSpend() async throws {
        let http = StubHTTP()
        http.on("/v1/billing/charges", #"{"BilledCost":"2","ChargePeriodStart":"2026-09-03T00:00:00Z"}"#)
        http.on("/v6/user/tokens", #"{"unexpected":true}"#)
        let snapshot = try await VercelConnector(http: http).fetch(fetch(["token": "t"]))
        #expect(snapshot.keys == nil)
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 3)] == 2)
    }

    @Test func splitsLongRangesIntoChunks() async throws {
        let http = StubHTTP()
        http.on("/v1/billing/charges", "")
        http.on("/v6/user/tokens", #"{"tokens":[]}"#)
        _ = try await VercelConnector(http: http).fetch(fetch(["token": "t"], from: Day(year: 2025, month: 9, day: 1)))
        let chunks = http.allRequests.filter { $0.url?.path() == "/v1/billing/charges" }
        #expect(chunks.count == 3)
    }
}

@Suite struct GitHubConnectorTests {
    @Test func sumsNetAmountPerDayAcrossYearsWithBreakdown() async throws {
        let http = StubHTTP()
        http.on("/users/octocat/settings/billing/usage", query: "year=2025", """
        {"usageItems":[{"date":"2025-08-31","product":"Actions","sku":"Actions Linux","netAmount":9},
                       {"date":"2025-12-01","product":"Actions","sku":"Actions Linux","grossAmount":1.2,"discountAmount":0.4,"netAmount":0.8,"repositoryName":"octocat/app"}]}
        """)
        http.on("/users/octocat/settings/billing/usage", query: "year=2026", """
        {"usageItems":[{"date":"2026-09-02","product":"Copilot","sku":"Copilot Premium Request","netAmount":"2.40"}]}
        """)
        http.on("/organizations/acme/settings/billing/usage", query: "year=2025", #"{"usageItems":[]}"#)
        http.on("/organizations/acme/settings/billing/usage", query: "year=2026", """
        {"usageItems":[{"date":"2026-09-02","product":"Packages","sku":"Packages storage","netAmount":1,"organizationName":"acme"}]}
        """)
        let snapshot = try await GitHubConnector(http: http).fetch(fetch(["token": "ghp_x", "username": "octocat", "organization": "acme"],
                                                                         from: Day(year: 2025, month: 9, day: 1)))
        #expect(snapshot.dailyCosts[Day(year: 2025, month: 8, day: 31)] == nil) // before the requested range
        #expect(snapshot.dailyCosts[Day(year: 2025, month: 12, day: 1)] == 0.8)
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 2)] == 3.4)
        let rows = try #require(snapshot.breakdown)
        #expect(rows.contains(BreakdownRow(month: Month(year: 2025, month: 12), dimension: .project, label: "octocat/app", amount: 0.8)))
        #expect(rows.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .lineItem, label: "Copilot · Copilot Premium Request", amount: 2.4)))
        #expect(rows.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .project, label: "acme (no repository)", amount: 1)))
        #expect(rows.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .account, label: "acme", amount: 1)))
        #expect(rows.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .account, label: "octocat", amount: 2.4)))
        let first = try #require(http.allRequests.first)
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_x")
        #expect(first.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
        #expect(http.allRequests.allSatisfy { $0.url?.host() == "api.github.com" })
    }

    @Test func readsAllOrganizationsAndReportsUnreadableOnes() async throws {
        let http = StubHTTP()
        http.on("/user/orgs", #"[{"login":"acme"},{"login":"secret-org"}]"#)
        http.on("/users/octocat/settings/billing/usage", #"{"usageItems":[{"date":"2026-09-02","product":"Actions","sku":"Linux","netAmount":1,"repositoryName":"app"}]}"#)
        http.on("/organizations/acme/settings/billing/usage", #"{"usageItems":[{"date":"2026-09-03","product":"Copilot","sku":"Business","netAmount":19,"repositoryName":"acme/site"}]}"#)
        http.on("/organizations/secret-org/settings/billing/usage", status: 403, #"{"message":"Must be an organization admin"}"#)
        let snapshot = try await GitHubConnector(http: http).fetch(fetch(["token": "t", "username": "octocat"]))
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 3)] == 19)
        let rows = try #require(snapshot.breakdown)
        let september = Month(year: 2026, month: 9)
        #expect(rows.contains(BreakdownRow(month: september, dimension: .account, label: "acme", amount: 19)))
        #expect(rows.contains(BreakdownRow(month: september, dimension: .account, label: "octocat", amount: 1)))
        #expect(rows.contains(BreakdownRow(month: september, dimension: .project, label: "octocat/app", amount: 1)))
        #expect(rows.contains(BreakdownRow(month: september, dimension: .project, label: "acme/site", amount: 19)))
        #expect(snapshot.notes.count == 1)
        #expect(snapshot.notes.first?.text.contains("secret-org") == true)
        #expect(snapshot.notes.first?.kind == .warning)
    }

    @Test func unreadablePersonalAccountDoesNotHideOrganizations() async throws {
        let http = StubHTTP()
        http.on("/user/orgs", #"[{"login":"Sample-Events"}]"#)
        http.on("/users/octocat/settings/billing/usage", status: 404, #"{"message":"Not Found"}"#)
        http.on("/organizations/Sample-Events/settings/billing/usage", query: "year=2026",
                #"{"usageItems":[{"date":"2026-09-01T00:00:00Z","product":"actions","sku":"Actions Linux","grossAmount":40,"discountAmount":8,"netAmount":32,"organizationName":"Sample-Events","repositoryName":"platform"}]}"#)
        http.on("/organizations/Sample-Events/settings/billing/usage", query: "year=2025", #"{"usageItems":[]}"#)
        let snapshot = try await GitHubConnector(http: http).fetch(fetch(["token": "t", "username": "octocat"], from: Day(year: 2025, month: 10, day: 1)))
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 1)] == Decimal(string: "32"))
        #expect(snapshot.breakdown?.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .project,
                                                          label: "Sample-Events/platform", amount: Decimal(string: "32")!)) == true)
        #expect(snapshot.notes.count == 1 && snapshot.notes[0].text.contains("octocat"))
    }

    @Test func organizationWithoutBillingDataIsInformational() async throws {
        let http = StubHTTP()
        http.on("/user/orgs", #"[{"login":"Sample-Platform"}]"#)
        http.on("/users/octocat/settings/billing/usage", #"{"usageItems":[]}"#)
        http.on("/organizations/Sample-Platform/settings/billing/usage", status: 403,
                #"{"message":"No access to billing usage data.","status":"403"}"#)
        let snapshot = try await GitHubConnector(http: http).fetch(fetch(["token": "t", "username": "octocat"]))
        let note = try #require(snapshot.notes.first)
        #expect(note.kind == .info)
        #expect(note.id == "github.org.sample-platform")
        #expect(note.text.contains("No access to billing usage data"))
    }

    @Test func failsWhenNothingIsReadable() async {
        let http = StubHTTP()
        http.on("/user/orgs", #"[]"#)
        http.on("/users/octocat/settings/billing/usage", status: 404, #"{"message":"Not Found"}"#)
        await #expect(throws: ConnectorError.self) {
            try await GitHubConnector(http: http).fetch(fetch(["token": "t", "username": "octocat"]))
        }
    }

    @Test func rejectsUnsafeUsernames() async {
        await #expect(throws: ConnectorError.invalidConfiguration("GitHub username or organization")) {
            try await GitHubConnector(http: StubHTTP()).fetch(fetch(["token": "t", "username": "../orgs/x"]))
        }
    }

    @Test func matchesServiceNames() {
        #expect(ConnectorID.match(serviceName: "GitHub") == .gitHub)
        #expect(ConnectorID.match(serviceName: "GitHub Copilot") == .gitHub)
    }
}

@Suite struct NeonConnectorTests {
    @Test func readsUsageMetricsPerOrganizationAndProject() async throws {
        let http = StubHTTP()
        http.on("/api/v2/users/me/organizations", #"{"organizations":[{"id":"org-1","name":"Example Org"},{"id":"org-free","name":"Free org"}]}"#)
        http.on("/api/v2/projects", query: "org_id=org-1", #"{"projects":[{"id":"p1","name":"web-app"}]}"#)
        http.on("/api/v2/projects", query: "org_id=org-free", #"{"projects":[]}"#)
        http.on("/api/v2/consumption_history/v2/projects", query: "granularity=daily", """
        {"projects":[{"project_id":"p1","periods":[{"consumption":[
          {"timeframe_start":"2026-09-01T00:00:00Z","metrics":[{"metric_name":"compute_unit_seconds","value":3600}]},
          {"timeframe_start":"2026-09-02T00:00:00Z","metrics":[{"metric_name":"compute_unit_seconds","value":1800}]}]}]}]}
        """)
        http.on("/api/v2/consumption_history/v2/projects", query: "org_id=org-1&from=2025-10-01", """
        {"projects":[{"project_id":"p1","periods":[{"period_plan":"launch","consumption":[
          {"timeframe_start":"2026-08-01T00:00:00Z","timeframe_end":"2026-09-01T00:00:00Z","metrics":[
            {"metric_name":"compute_unit_seconds","value":7200},
            {"metric_name":"root_branch_bytes_month","value":2500000000},
            {"metric_name":"extra_branches_month","value":1488}]}]}]}]}
        """)
        http.on("/api/v2/consumption_history/v2/projects", query: "org_id=org-free", status: 403,
                #"{"message":"consumption history is available on paid plans"}"#)
        http.on("/api/v2/api_keys", #"[{"id":123,"name":"tracker","created_at":"2026-01-01T00:00:00Z","last_used_at":"2026-09-29T10:00:00Z","revoked":false}]"#)
        let snapshot = try await NeonConnector(http: http).fetch(fetch(["apiKey": "napi_x"], from: Day(year: 2025, month: 9, day: 1)))
        let september = Month(year: 2026, month: 9)
        let metrics = try #require(snapshot.usageMetrics)
        // The month in progress comes from daily buckets (1 + 0.5 CU-hours), not from the monthly bucket.
        #expect(metrics.contains(UsageMetricRow(month: september, project: "web-app", metric: "compute_unit_seconds", value: 1.5, organization: "Example Org")))
        #expect(metrics.first { $0.month == september }?.plan == nil) // the daily stub has no period_plan
        #expect(metrics.filter { $0.month == september && $0.metric == "compute_unit_seconds" }.count == 1)
        #expect(metrics.contains(UsageMetricRow(month: Month(year: 2026, month: 8), project: "web-app", metric: "root_branch_bytes_month", value: 2.5, plan: "launch", organization: "Example Org")))
        #expect(metrics.contains(UsageMetricRow(month: Month(year: 2026, month: 8), project: "web-app", metric: "extra_branches_month", value: 2, plan: "launch", organization: "Example Org")))
        #expect(snapshot.usageMetricsFrom == Month(year: 2025, month: 10)) // monthly history: last year only
        #expect(snapshot.spendUnavailableReason == nil)
        // ≈ spend (DEC-033): August on Launch — compute 2 CU-h × 0.106 = 0.212, storage 2.5 GB-mo × 0.35 = 0.875,
        // extra branches 2 ≤ 9 free.
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 8, day: 1)] == Decimal(string: "1.087"))
        #expect(snapshot.breakdown?.contains { $0.dimension == .project && $0.label == "web-app" } == true)
        #expect(snapshot.notes.count == 1 && snapshot.notes[0].text.contains("Free org"))
        #expect(snapshot.keys?.first?.name == "tracker")
        #expect(snapshot.keys?.first?.externalID == "123")
    }

    /// Project names are only unique inside an organization (REQ-011): two organizations can each have "app".
    @Test func sameProjectNameInTwoOrganizationsStaysSeparate() async throws {
        let http = StubHTTP()
        http.on("/api/v2/users/me/organizations", #"{"organizations":[{"id":"org-a","name":"Alpha"},{"id":"org-b","name":"Beta"}]}"#)
        http.on("/api/v2/projects", query: "org_id=org-a", #"{"projects":[{"id":"pa","name":"app"}]}"#)
        http.on("/api/v2/projects", query: "org_id=org-b", #"{"projects":[{"id":"pb","name":"app"}]}"#)
        http.on("/api/v2/consumption_history/v2/projects", query: "granularity=daily", #"{"projects":[]}"#)
        func monthly(_ project: String, seconds: Int) -> String {
            """
            {"projects":[{"project_id":"\(project)","periods":[{"period_plan":"launch","consumption":[
              {"timeframe_start":"2026-08-01T00:00:00Z","metrics":[{"metric_name":"compute_unit_seconds","value":\(seconds)}]}]}]}]}
            """
        }
        http.on("/api/v2/consumption_history/v2/projects", query: "org_id=org-a&from=2025-10-01", monthly("pa", seconds: 3600))
        http.on("/api/v2/consumption_history/v2/projects", query: "org_id=org-b&from=2025-10-01", monthly("pb", seconds: 7200))
        http.on("/api/v2/api_keys", "[]")
        let snapshot = try await NeonConnector(http: http).fetch(fetch(["apiKey": "napi_x"], from: Day(year: 2025, month: 9, day: 1)))
        let august = Month(year: 2026, month: 8)
        let metrics = try #require(snapshot.usageMetrics)
        #expect(metrics.contains(UsageMetricRow(month: august, project: "app", metric: "compute_unit_seconds", value: 1, plan: "launch", organization: "Alpha")))
        #expect(metrics.contains(UsageMetricRow(month: august, project: "app", metric: "compute_unit_seconds", value: 2, plan: "launch", organization: "Beta")))
        #expect(metrics.count == 2)  // not merged into one "app" of 3 CU-hours
        // The project breakdown tells them apart as "Project (Org)".
        let projects = (snapshot.breakdown ?? []).filter { $0.dimension == .project }.map(\.label).sorted()
        #expect(projects == ["app (Alpha)", "app (Beta)"])
    }

    /// Neon rounds `from`/`to` down to the bucket start; `to` must be the end of the bucket in progress, or the first
    /// UTC day of a month (and a service added this month) sends an empty range and gets HTTP 400.
    @Test func requestsEndAfterBucketInProgress() async throws {
        let http = StubHTTP()
        http.on("/api/v2/users/me/organizations", #"{"organizations":[{"id":"org-1","name":"Example Org"}]}"#)
        http.on("/api/v2/projects", #"{"projects":[{"id":"p1","name":"web-app"}]}"#)
        http.on("/api/v2/consumption_history/v2/projects", query: "granularity=daily", """
        {"projects":[{"project_id":"p1","periods":[{"period_plan":"launch","consumption":[
          {"timeframe_start":"2026-10-01T00:00:00Z","metrics":[{"metric_name":"compute_unit_seconds","value":720}]}]}]}]}
        """)
        http.on("/api/v2/consumption_history/v2/projects", query: "granularity=monthly", #"{"projects":[]}"#)
        http.on("/api/v2/api_keys", "[]")
        let firstOfMonth = Date(timeIntervalSince1970: 1_790_814_600) // 2026-10-01 00:30 UTC
        let request = FetchRequest(credentials: ["apiKey": "napi_x"], from: Day(year: 2026, month: 10, day: 1), now: firstOfMonth)
        let snapshot = try await NeonConnector(http: http).fetch(request)
        let queries = http.allRequests.compactMap { $0.url?.query(percentEncoded: false) }
            .filter { $0.contains("granularity=") }
        #expect(queries.contains { $0.contains("from=2026-10-01T00:00:00Z&to=2026-10-02T00:00:00Z&granularity=daily") })
        #expect(queries.contains { $0.contains("from=2026-10-01T00:00:00Z&to=2026-11-01T00:00:00Z&granularity=monthly") })
        #expect(snapshot.notes.isEmpty)
        #expect(snapshot.usageMetrics?.contains(UsageMetricRow(month: Month(year: 2026, month: 10), project: "web-app",
                                                              metric: "compute_unit_seconds", value: 0.2, plan: "launch", organization: "Example Org")) == true)
    }
}

@Suite struct GoogleCloudConnectorTests {
    @Test func tableReferenceValidatesIdentifiers() throws {
        let table = try GoogleCloudConnector.tableReference(dataset: "billing", billingAccount: "0123AB-4567CD-89EF01",
                                                            defaultProject: "my-project")
        #expect(table.fullName == "`my-project.billing.gcp_billing_export_v1_0123AB_4567CD_89EF01`")
        #expect(throws: ConnectorError.self) {
            try GoogleCloudConnector.tableReference(dataset: "x`; DROP", billingAccount: "0123AB-4567CD-89EF01", defaultProject: "p")
        }
        #expect(throws: ConnectorError.self) {
            try GoogleCloudConnector.tableReference(dataset: "billing", billingAccount: "' OR 1=1", defaultProject: "my-project")
        }
    }

    @Test func signsJWTWithPKCS8Key() throws {
        let pem = try TestRSA.pkcs8PEM()
        let account = GoogleCloudConnector.ServiceAccount(client_email: "sa@p.iam.gserviceaccount.com", private_key: pem,
                                                          private_key_id: "kid1", project_id: "p", token_uri: nil)
        let jwt = try GoogleCloudConnector.signedJWT(account: account, audience: "https://oauth2.googleapis.com/token", now: now)
        let parts = jwt.split(separator: ".")
        #expect(parts.count == 3)
        let header = String(parts[0])
        #expect(Data(base64URL: header).flatMap { String(data: $0, encoding: .utf8) }?.contains("RS256") == true)
    }

    @Test func queriesBigQueryWithAccessToken() async throws {
        let http = StubHTTP()
        http.on("/token", #"{"access_token":"ya29.test","expires_in":3600}"#)
        http.on("/bigquery/v2/projects/my-project/datasets/billing/tables", """
        {"tables":[{"tableReference":{"projectId":"my-project","datasetId":"billing","tableId":"gcp_billing_export_v1_0123AB_4567CD_89EF01"}},
                   {"tableReference":{"projectId":"my-project","datasetId":"billing","tableId":"gcp_billing_export_resource_v1_0123AB_4567CD_89EF01"}},
                   {"tableReference":{"projectId":"my-project","datasetId":"billing","tableId":"unrelated"}}]}
        """)
        http.on("/bigquery/v2/projects/other-proj/datasets/billing_export/tables", """
        {"tables":[{"tableReference":{"projectId":"other-proj","datasetId":"billing_export","tableId":"gcp_billing_export_v1_0123AB_4567CD_89EF01"}}]}
        """)
        http.on("/bigquery/v2/projects/my-project/queries", """
        {"jobComplete":true,"rows":[{"f":[{"v":"2026-09-02"},{"v":"3.5"}]},{"f":[{"v":"2026-09-03"},{"v":"-0.5"}]}],
         "jobReference":{"jobId":"j1","location":"US"}}
        """)
        let json = String(data: try JSONSerialization.data(withJSONObject: [
            "client_email": "sa@my-project.iam.gserviceaccount.com", "private_key": try TestRSA.pkcs8PEM(),
            "private_key_id": "k", "project_id": "my-project",
        ]), encoding: .utf8)!
        let snapshot = try await GoogleCloudConnector(http: http).fetch(fetch([
            "serviceAccountJSON": json, "dataset": "billing, other-proj.billing_export",
        ], from: Day(year: 2025, month: 9, day: 1)))
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 2)] == 3.5)
        #expect(snapshot.coveredFrom == Day(year: 2026, month: 9, day: 1))
        let query = try #require(http.allRequests.first { $0.url?.path().hasSuffix("/queries") == true })
        #expect(query.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.test")
        // Both standard export tables (two billing accounts, two datasets) are queried together; others are ignored.
        let body = String(decoding: query.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("gcp_billing_export_v1_0123AB_4567CD_89EF01"))
        #expect(body.contains("other-proj.billing_export.gcp_billing_export_v1_0123AB_4567CD_89EF01"))
        #expect(body.contains("UNION ALL"))
        #expect(!body.contains("resource_v1"))
    }

    @Test func listsAPIKeysWithRequestsThisMonth() async throws {
        let http = StubHTTP()
        http.on("/token", #"{"access_token":"ya29.test","expires_in":3600}"#)
        http.on("/bigquery/v2/projects/p/datasets/billing_export/tables", #"{"totalItems":0}"#)
        http.on("/v2/projects/example-project-123456/locations/global/keys", """
        {"keys":[{"uid":"11111111-1111-4111-8111-111111111111","displayName":"Gemini API Key","createTime":"2026-07-19T10:00:00.123Z",
                  "restrictions":{"apiTargets":[{"service":"generativelanguage.googleapis.com"}]}},
                 {"uid":"22222222-2222-4222-8222-222222222222","displayName":"Build key"}]}
        """)
        http.on("/v3/projects/example-project-123456/timeSeries", """
        {"timeSeries":[{"resource":{"labels":{"credential_id":"apikey:11111111-1111-4111-8111-111111111111"}},
                        "points":[{"value":{"int64Value":"29"}}]},
                       {"resource":{"labels":{"credential_id":"serviceaccount:123"}},"points":[{"value":{"int64Value":"5"}}]}]}
        """)
        http.on("/v2/projects/secret-proj/locations/global/keys", status: 403, #"{"error":{"message":"Permission denied"}}"#)
        let json = String(data: try JSONSerialization.data(withJSONObject: [
            "client_email": "sa@p.iam.gserviceaccount.com", "private_key": try TestRSA.pkcs8PEM(), "project_id": "p",
        ]), encoding: .utf8)!
        let snapshot = try await GoogleCloudConnector(http: http).fetch(fetch([
            "serviceAccountJSON": json, "dataset": "billing_export", "keyProjects": "example-project-123456, secret-proj",
        ]))
        let keys = try #require(snapshot.keys)
        let gemini = try #require(keys.first { $0.name == "Gemini API Key" })
        #expect(gemini.requestsThisMonth == 29)
        #expect(gemini.details.contains(KeyDetail(kind: .scopes, value: "generativelanguage.googleapis.com")))
        #expect(gemini.consoleURL?.absoluteString == "https://console.cloud.google.com/apis/credentials/key/11111111-1111-4111-8111-111111111111?project=example-project-123456")
        #expect(gemini.createdAt != nil)
        #expect(keys.first { $0.name == "Build key" }?.requestsThisMonth == 0)
        #expect(gemini.currentMonthCost == nil) // no billing data yet → no ≈ cost
        #expect(snapshot.notes.contains { $0.id == "gcp.keys.secret-proj" })   // unreadable project is a note, not a failure
        #expect(snapshot.spendUnavailableReason != nil)                        // export still empty
    }

    @Test func approximateCostPerKeyFromRequestShare() async throws {
        let http = StubHTTP()
        http.on("/token", #"{"access_token":"ya29.test","expires_in":3600}"#)
        http.on("/bigquery/v2/projects/p/datasets/billing_export/tables", """
        {"tables":[{"tableReference":{"projectId":"p","datasetId":"billing_export","tableId":"gcp_billing_export_v1_0123AB_4567CD_89EF01"}}]}
        """)
        // Daily, monthly breakdown and current-month service cost queries all go to the same endpoint; the stub
        // answers by query text so each gets a matching shape.
        http.on("/bigquery/v2/projects/p/queries", #"{"jobComplete":true,"rows":[{"f":[{"v":"2026-09-02"},{"v":"10"}]}],"jobReference":{"jobId":"j1","location":"US"}}"#)
        http.on("/v2/projects/proj-a/locations/global/keys", #"{"keys":[{"uid":"k1","displayName":"A"},{"uid":"k2","displayName":"B"}]}"#)
        http.on("/v3/projects/proj-a/timeSeries", """
        {"timeSeries":[{"resource":{"labels":{"credential_id":"apikey:k1","service":"generativelanguage.googleapis.com"}},"points":[{"value":{"int64Value":"3"}}]},
                       {"resource":{"labels":{"credential_id":"apikey:k2","service":"generativelanguage.googleapis.com"}},"points":[{"value":{"int64Value":"1"}}]}]}
        """)
        let json = String(data: try JSONSerialization.data(withJSONObject: [
            "client_email": "sa@p.iam.gserviceaccount.com", "private_key": try TestRSA.pkcs8PEM(), "project_id": "p",
        ]), encoding: .utf8)!
        let connector = GoogleCloudConnector(http: BodyRoutingHTTP(base: http, serviceCostRows: [["proj-a", "generativelanguage.googleapis.com", "8"]]))
        let snapshot = try await connector.fetch(fetch(["serviceAccountJSON": json, "dataset": "billing_export", "keyProjects": "proj-a"]))
        let keys = try #require(snapshot.keys)
        #expect(keys.first { $0.externalID == "k1" }?.currentMonthCost == 6)
        #expect(keys.first { $0.externalID == "k2" }?.currentMonthCost == 2)
    }

    @Test func unreadableRequestCountsAreUnavailableNotZero() async throws {
        let http = StubHTTP()
        http.on("/token", #"{"access_token":"ya29.test","expires_in":3600}"#)
        http.on("/bigquery/v2/projects/p/datasets/billing_export/tables", #"{"totalItems":0}"#)
        http.on("/v2/projects/proj-a/locations/global/keys", #"{"keys":[{"uid":"k1","displayName":"Gemini"}]}"#)
        http.on("/v3/projects/proj-a/timeSeries", status: 403, #"{"error":{"message":"Monitoring API disabled"}}"#)
        let json = String(data: try JSONSerialization.data(withJSONObject: [
            "client_email": "sa@p.iam.gserviceaccount.com", "private_key": try TestRSA.pkcs8PEM(), "project_id": "p",
        ]), encoding: .utf8)!
        let snapshot = try await GoogleCloudConnector(http: http).fetch(fetch([
            "serviceAccountJSON": json, "dataset": "billing_export", "keyProjects": "proj-a",
        ]))
        #expect(snapshot.keys?.first?.requestsThisMonth == nil)
        #expect(snapshot.notes.contains { $0.id == "gcp.requests.proj-a" && $0.text.contains("Monitoring API disabled") })
    }

    @Test func emptyExportIsNoDataNotError() async throws {
        let http = StubHTTP()
        http.on("/token", #"{"access_token":"ya29.test","expires_in":3600}"#)
        http.on("/bigquery/v2/projects/p/datasets/billing_export/tables", #"{"totalItems":0}"#)
        let json = String(data: try JSONSerialization.data(withJSONObject: [
            "client_email": "sa@p.iam.gserviceaccount.com", "private_key": try TestRSA.pkcs8PEM(), "project_id": "p",
        ]), encoding: .utf8)!
        let snapshot = try await GoogleCloudConnector(http: http).fetch(fetch(["serviceAccountJSON": json, "dataset": "billing_export"]))
        #expect(snapshot.spendUnavailableReason != nil)
    }
}

enum TestRSA {
    /// Generates an RSA key and wraps its PKCS#1 export in a PKCS#8 PEM, like Google key files.
    static func pkcs8PEM() throws -> String {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw error!.takeRetainedValue()
        }
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let body = [0x02, 0x01, 0x00] + algorithm + der(0x04, [UInt8](pkcs1))
        let pkcs8 = Data(der(0x30, body))
        return "-----BEGIN PRIVATE KEY-----\n\(pkcs8.base64EncodedString(options: .lineLength64Characters))\n-----END PRIVATE KEY-----\n"
    }

    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let length = content.count
        let lengthBytes: [UInt8] = length < 0x80 ? [UInt8(length)]
            : length < 0x100 ? [0x81, UInt8(length)]
            : [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        return [tag] + lengthBytes + content
    }
}

extension Data {
    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }
}

/// Routes BigQuery `queries` POSTs by SQL text: the current-month service-cost query gets its own rows.
final class BodyRoutingHTTP: HTTPClient, @unchecked Sendable {
    let base: StubHTTP
    let serviceCostRows: [[String]]

    init(base: StubHTTP, serviceCostRows: [[String]]) {
        self.base = base
        self.serviceCostRows = serviceCostRows
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        if body.contains("service.id AS service") {
            let rows = serviceCostRows.map { row in ["f": row.map { ["v": $0] }] }
            let json = try JSONSerialization.data(withJSONObject: ["jobComplete": true, "rows": rows,
                                                                   "jobReference": ["jobId": "j2", "location": "US"]])
            return (json, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return try await base.send(request)
    }
}
