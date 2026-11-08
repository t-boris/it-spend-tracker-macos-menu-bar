import Foundation

/// Vercel REST API (SRC-002): FOCUS billing charges (JSONL) and access tokens.
struct VercelConnector: Connector {
    static let descriptor = ConnectorDescriptor(
        id: .vercel,
        displayName: "Vercel",
        aliases: ["vercel"],
        credentialFields: [
            CredentialField(id: "token", label: "Access token",
                            help: "Create at vercel.com/account/tokens with Full Account or team scope (not a single project).",
                            isSecret: true),
            CredentialField(id: "teamId", label: "Team ID",
                            help: "Needed only for a Full Account token billing a team: Team Settings → General → Team ID.",
                            isSecret: false, isOptional: true),
        ],
        capabilities: ConnectorCapabilities(keyDetails: true, keyLastUsed: true, keyExpiry: true,
                                            breakdownByLineItem: true, breakdownByProject: true),
        consoleURL: URL(string: "https://vercel.com/account/tokens")!,
        credentialSummary: "A Vercel access token created at https://vercel.com/account/tokens with Full Account or team scope, plus the team ID when a Full Account token is used for a team. The account role must be allowed to read billing."
    )

    let http: HTTPClient
    /// The charges endpoint accepts at most one year per request.
    static let maxChunkMonths = 6

    func fetch(_ request: FetchRequest) async throws -> ConnectorSnapshot {
        let token = try request.required("token")
        let teamID = request.optional("teamId")
        var daily: [Day: Decimal] = [:]
        var breakdown: [BreakdownRow] = []
        var chunkStart = request.from
        let end = request.today.nextDay
        // Vercel answers 404 "costs_not_found" for ranges without billing data (e.g. before the team's data
        // starts); such ranges are "no data", not errors (SRC-002).
        var firstAnsweredChunk: Day?
        while chunkStart < end {
            let chunkEnd = min(chunkStart.adding(months: Self.maxChunkMonths), end)
            do {
                try await fetchCharges(token: token, teamID: teamID, from: chunkStart, to: chunkEnd,
                                       daily: &daily, breakdown: &breakdown)
                firstAnsweredChunk = firstAnsweredChunk ?? chunkStart
            } catch ConnectorError.http(status: 404, let message) where Self.meansNoBillingData(message) {
                // No data for this range.
            }
            chunkStart = chunkEnd
        }
        // The token list is optional: if it cannot be read, keys show as unavailable and spend still loads.
        let keys = try? await fetchTokens(token: token)
        guard let firstAnsweredChunk else {
            return ConnectorSnapshot(dailyCosts: [:], coveredFrom: request.from, keys: keys, tokenUsage: nil,
                                     spendUnavailableReason: String(localized: "Vercel's billing API has no charges for this team in the requested period (\u{201C}Costs not found\u{201D}). Spend is shown as no data."))
        }
        // Months before the first day with data are "no data", like the Google Cloud export.
        let coveredFrom = daily.keys.min().map { max($0.calendarMonth.firstDay, request.from) } ?? firstAnsweredChunk
        return ConnectorSnapshot(dailyCosts: daily, coveredFrom: coveredFrom, keys: keys, tokenUsage: nil,
                                 breakdown: breakdown.merged(), breakdownFrom: coveredFrom.calendarMonth)
    }

    private struct Charge: Decodable {
        /// Amortized cost including the plan fee spread over the days; this is what the dashboard shows.
        let EffectiveCost: FlexibleDecimal?
        /// Invoiced amount; reported as 0 on every line until the cycle is invoiced (SRC-002).
        let BilledCost: FlexibleDecimal?
        let ChargePeriodStart: String?
        let ServiceName: String?
        let Tags: FOCUSTags?
    }

    /// FOCUS `Tags`: a JSON object, or a string containing one; only `ProjectName` is used.
    struct FOCUSTags: Decodable {
        let projectName: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            var object = (try? container.decode([String: String?].self)) ?? [:]
            if object.isEmpty, let text = try? container.decode(String.self), let data = text.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String: String?].self, from: data) {
                object = parsed
            }
            projectName = object["ProjectName"] ?? object["projectName"] ?? nil
        }
    }

    private func fetchCharges(token: String, teamID: String?, from: Day, to: Day,
                              daily: inout [Day: Decimal], breakdown: inout [BreakdownRow]) async throws {
        var items = [("from", "\(from)T00:00:00Z"), ("to", "\(to)T00:00:00Z")]
        if let teamID { items.append(("teamId", teamID)) }
        let data = try await http.fetchData(request(token: token, url: .api("https://api.vercel.com/v1/billing/charges", items)))
        for line in Self.lines(data) {
            let charge: Charge
            do {
                charge = try JSONDecoder().decode(Charge.self, from: Data(line.utf8))
            } catch {
                throw ConnectorError.malformedResponse("charge line: \(error)")
            }
            guard let start = charge.ChargePeriodStart, let day = Day(isoPrefix: start) else { continue }
            let amount = charge.EffectiveCost?.value ?? charge.BilledCost?.value ?? 0
            daily[day, default: 0] += amount
            breakdown.append(BreakdownRow(month: day.calendarMonth, dimension: .lineItem,
                                          label: charge.ServiceName ?? String(localized: "Other"), amount: amount))
            breakdown.append(BreakdownRow(month: day.calendarMonth, dimension: .project,
                                          label: charge.Tags?.projectName ?? String(localized: "No project"), amount: amount))
        }
    }

    /// Vercel answers 404 "costs_not_found" / "Plan not found" when it has no billing data for the team.
    /// The dashboard can still show usage in that case, so the answer is "no data", not zero (SRC-002).
    static func meansNoBillingData(_ message: String) -> Bool {
        message.contains("costs_not_found") || message.localizedCaseInsensitiveContains("Plan not found")
    }

    private static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private struct TokensResponse: Decodable {
        struct Token: Decodable {
            let id: String
            let name: String?
            let prefix: String?
            let suffix: String?
            let createdAt: FlexibleNumber?
            let activeAt: FlexibleNumber?
            let expiresAt: FlexibleNumber?
            let revokedAt: FlexibleNumber?
            let type: String?
            let origin: String?
            let scopes: [Scope]?

            struct Scope: Decodable { let type: String?; let teamId: String? }

            var details: [KeyDetail] {
                let scopeText = scopes?.map { scope in
                    [scope.type, scope.teamId].compactMap { $0 }.joined(separator: " ")
                }.filter { !$0.isEmpty }.joined(separator: ", ")
                let pairs: [(KeyDetail.Kind, String?)] = [(.keyType, type), (.origin, origin), (.scopes, scopeText)]
                return pairs.compactMap { kind, value in value?.nilIfEmpty.map { KeyDetail(kind: kind, value: $0) } }
            }
        }
        /// `next` is a timestamp cursor; Vercel sends it as a number or a string.
        struct Pagination: Decodable { let next: FlexibleNumber? }
        let tokens: [Token]
        let pagination: Pagination?
    }

    private func fetchTokens(token: String) async throws -> [ProviderKey] {
        var result: [ProviderKey] = []
        var until: String?
        repeat {
            var items = [("limit", "100")]
            if let until { items.append(("until", until)) }
            let page = try await http.fetchJSON(TokensResponse.self,
                                                request(token: token, url: .api("https://api.vercel.com/v6/user/tokens", items)))
            result += page.tokens.filter { $0.revokedAt == nil }.map { item in
                let hint = [item.prefix, item.suffix].compactMap { $0 }.joined(separator: "…")
                return ProviderKey(externalID: item.id, name: item.name ?? item.id,
                                   hint: hint.isEmpty ? nil : hint,
                                   createdAt: item.createdAt.map { Self.date($0.value) },
                                   lastUsedAt: item.activeAt.map { Self.date($0.value) },
                                   expiresAt: item.expiresAt.map { Self.date($0.value) },
                                   status: nil, currentMonthCost: nil, details: item.details)
            }
            let next = page.pagination?.next?.text
            until = page.tokens.isEmpty || next == until ? nil : next
        } while until != nil
        return result
    }

    private func request(token: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func date(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }
}
