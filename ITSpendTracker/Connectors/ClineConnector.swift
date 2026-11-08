import Foundation

/// Cline account (DEC-040): credits used per day and model, Cline Pass payments, credit purchases and balance,
/// for the personal account and the user's own usage in Cline organizations. Signs in with a Cline session
/// (`ClineAuth`) instead of an API key. Money fields are integers: credits and balance in millionths of a dollar,
/// payments in cents.
struct ClineConnector: SessionConnector {
    static let descriptor = ConnectorDescriptor(
        id: .cline,
        displayName: "Cline",
        aliases: ["cline", "clinebot"],
        credentialFields: [],
        capabilities: ConnectorCapabilities(tokenUsage: true, breakdownByLineItem: true, breakdownByAccount: true,
                                            reportsBalance: true),
        consoleURL: URL(string: "https://app.cline.bot/dashboard")!,
        credentialSummary: "No API key: the user signs in to their Cline account with the \"Sign in with Cline\" button in this app (a code is confirmed in the browser). Spend is the Cline credits used plus Cline Pass payments; credit top-ups and the balance are shown for information. Usage paid with the user's own provider keys inside Cline is tracked by those providers' connectors.",
        sessionFields: ClineAuth.Field.all
    )

    let http: HTTPClient

    private static let creditUnit: Decimal = 1_000_000
    private static let pageSize = "200"

    func refreshedCredentials(_ credentials: [String: String], now: Date) async throws -> [String: String]? {
        try await ClineAuth(http: http).refreshedCredentials(credentials, now: now)
    }

    func markedExpired(_ credentials: [String: String]) -> [String: String] {
        credentials.filter { $0.key != ClineAuth.Field.expiresAt }
    }

    func fetch(_ request: FetchRequest) async throws -> ConnectorSnapshot {
        guard let token = request.optional(ClineAuth.Field.accessToken) else { throw ClineAuth.AuthError.signInRequired }
        let me = try await http.fetchJSON(Envelope<Me>.self, ClineAuth.apiRequest(path: "/api/v1/users/me", accessToken: token)).data
        let organizations = me.organizations ?? []

        var usage = try await usages(path: "/api/v1/users/\(me.id)/usages", token: token, from: request.from)
            .map { (account: String(localized: "Personal"), item: $0) }
        var notes: [ProviderNote] = []
        for organization in organizations {
            let name = organization.name ?? organization.organizationId
            do {
                usage += try await usages(path: "/api/v1/organizations/\(organization.organizationId)/members/\(organization.memberId)/usages",
                                          token: token, from: request.from).map { (account: name, item: $0) }
            } catch let error as ConnectorError where error.isAccessDenied {
                // Not allowed to read: a fact to show. Any other error fails the refresh, so stored figures
                // are kept instead of being replaced by the personal part only.
                notes.append(ProviderNote(id: "cline.org.\(organization.organizationId)", kind: .warning,
                                          text: String(localized: "\(name): usage not available (\(error.localizedDescription))")))
            }
            // The organization's own credit balance, shown for information (members may not be allowed to read it).
            let balance = try? await http.fetchJSON(Envelope<Balance>.self, ClineAuth.apiRequest(
                path: "/api/v1/organizations/\(organization.organizationId)/balance", accessToken: token)).data.balance.value
            if let balance {
                notes.append(ProviderNote(id: "cline.orgbalance.\(organization.organizationId)", kind: .info,
                                          text: String(localized: "\(name): organization credit balance \(Format.usd(balance / Self.creditUnit))")))
            }
        }
        let payments = try await payments(userID: me.id, token: token)
        var balance: Decimal?
        do {
            balance = try await http.fetchJSON(Envelope<Balance>.self, ClineAuth.apiRequest(
                path: "/api/v1/users/\(me.id)/balance", accessToken: token)).data.balance.value / Self.creditUnit
        } catch {
            notes.append(ProviderNote(id: "cline.balance", kind: .warning,
                                      text: String(localized: "Balance not available (\(error.localizedDescription))")))
        }

        let currentMonth = request.today.calendarMonth
        var daily: [Day: Decimal] = [:]
        var breakdown: [BreakdownRow] = []
        var tokens: [String: TokenUsageRow] = [:]
        for (account, item) in usage {
            let day = try Self.day(item.createdAt)
            guard day >= request.from else { continue }
            let cost = item.creditsUsed.value / Self.creditUnit
            let label = item.aiModelName?.nilIfEmpty ?? item.operation?.nilIfEmpty ?? String(localized: "Other")
            daily[day, default: 0] += cost
            breakdown.append(BreakdownRow(month: day.calendarMonth, dimension: .lineItem, label: label, amount: cost))
            if !organizations.isEmpty {
                breakdown.append(BreakdownRow(month: day.calendarMonth, dimension: .account, label: account, amount: cost))
            }
            if day.calendarMonth == currentMonth {
                var row = tokens[label] ?? TokenUsageRow(keyExternalID: nil, model: label, inputTokens: 0, cachedInputTokens: 0,
                                                         outputTokens: 0, requests: 0)
                row.inputTokens += item.promptTokens?.int ?? 0
                row.cachedInputTokens = (row.cachedInputTokens ?? 0) + (item.cachedTokens?.int ?? 0)
                row.outputTokens += item.completionTokens?.int ?? 0
                row.requests = (row.requests ?? 0) + 1
                tokens[label] = row
            }
        }
        // Cline Pass is a subscription paid in money: spend on the payment day (DEC-040).
        var purchases: [ProviderCreditPurchase] = []
        for payment in payments where payment.status == nil || payment.status == "completed" {
            let day = try Self.day(payment.completedAt ?? payment.createdAt)
            let amount = payment.amount.value / 100
            switch payment.type {
            case "plan":
                guard day >= request.from else { continue }
                daily[day, default: 0] += amount
                breakdown.append(BreakdownRow(month: day.calendarMonth, dimension: .lineItem, label: "Cline Pass", amount: amount))
                if !organizations.isEmpty {
                    breakdown.append(BreakdownRow(month: day.calendarMonth, dimension: .account,
                                                  label: String(localized: "Personal"), amount: amount))
                }
            case "credits":
                let credits = (payment.credits?.value ?? 0) / Self.creditUnit
                purchases.append(ProviderCreditPurchase(externalID: payment.id, day: day, amount: amount,
                                                        volume: credits > 0 ? String(localized: "\(Format.usd(credits)) in credits") : ""))
            default:
                continue
            }
        }
        return ConnectorSnapshot(dailyCosts: daily, coveredFrom: request.coverageStart(for: daily), keys: nil,
                                 tokenUsage: tokens.values.sorted { $0.model < $1.model },
                                 breakdown: breakdown.merged(), breakdownFrom: request.from.calendarMonth,
                                 notes: notes, providerBalance: balance, providerBalanceUnavailable: balance == nil,
                                 creditPurchases: purchases)
    }

    // MARK: Responses

    private struct Envelope<T: Decodable>: Decodable { let data: T }

    private struct Me: Decodable {
        struct Organization: Decodable { let organizationId: String; let memberId: String; let name: String? }
        let id: String
        let organizations: [Organization]?
    }

    private struct Balance: Decodable { let balance: FlexibleDecimal }

    private struct Page<Item: Decodable>: Decodable {
        let items: [Item]?
        let nextToken: String?
    }

    private struct Usage: Decodable {
        let createdAt: String
        let creditsUsed: FlexibleDecimal
        let aiModelName: String?
        let operation: String?
        let promptTokens: FlexibleNumber?
        let completionTokens: FlexibleNumber?
        let cachedTokens: FlexibleNumber?
    }

    private struct Payment: Decodable {
        let id: String
        let type: String?
        let status: String?
        let amount: FlexibleDecimal
        let credits: FlexibleDecimal?
        let createdAt: String
        let completedAt: String?
    }

    /// Dates decide the month of spend, so an unreadable one fails the refresh instead of being skipped.
    private static func day(_ timestamp: String) throws -> Day {
        guard let day = Day(isoPrefix: timestamp) else { throw ConnectorError.malformedResponse("date \(timestamp)") }
        return day
    }

    // MARK: Paging

    /// Usage is returned newest first, so paging stops once a page reaches days before `from`.
    private func usages(path: String, token: String, from: Day) async throws -> [Usage] {
        try await pages(path: path, token: token, as: Usage.self) { page in
            guard let last = page.last else { return true }
            return try Self.day(last.createdAt) < from
        }
    }

    private func payments(userID: String, token: String) async throws -> [Payment] {
        try await pages(path: "/api/v1/users/\(userID)/payments", token: token, as: Payment.self) { _ in false }
    }

    private func pages<Item: Decodable>(path: String, token: String, as type: Item.Type,
                                        isLast: ([Item]) throws -> Bool) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        var pageCount = 0
        repeat {
            pageCount += 1
            // 12 months of heavy use is a few thousand items; a cursor cycle must not loop forever.
            guard pageCount <= 500 else { throw ConnectorError.malformedResponse("too many pages at \(path)") }
            var query = [("limit", Self.pageSize)]
            if let cursor { query.append(("cursor", cursor)) }
            let page = try await http.fetchJSON(Envelope<Page<Item>>.self,
                                                ClineAuth.apiRequest(path: path, items: query, accessToken: token)).data
            let pageItems = page.items ?? []
            items += pageItems
            let next = page.nextToken?.nilIfEmpty
            cursor = try pageItems.isEmpty || isLast(pageItems) || next == cursor ? nil : next
        } while cursor != nil
        return items
    }
}

private extension FlexibleNumber {
    var int: Int { Int(value) }
}

private extension ConnectorError {
    var isAccessDenied: Bool {
        switch self {
        case .forbidden: true
        case .http(let status, _): status == 404
        default: false
        }
    }
}
