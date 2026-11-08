import Foundation

/// GitHub enhanced billing platform usage report (DEC-028, SRC-002).
/// Fixed plans (GitHub Pro, Copilot plans, seats) are not in the report and are added as subscriptions (DEC-026).
struct GitHubConnector: Connector {
    static let descriptor = ConnectorDescriptor(
        id: .gitHub,
        displayName: "GitHub",
        aliases: ["github", "githubcopilot", "copilot", "githubactions"],
        credentialFields: [
            CredentialField(id: "token", label: "Personal access token",
                            help: "Use a classic token from github.com/settings/tokens with the scopes user, repo and read:org. Fine-grained tokens cover only one owner and cannot read your organizations' billing.",
                            isSecret: true),
            CredentialField(id: "username", label: "GitHub username",
                            help: "The account whose billing usage is read.",
                            isSecret: false),
            CredentialField(id: "organization", label: "Organization",
                            help: "Optional: all your organizations are found automatically; enter one here only if it is missing. Reading an organization's billing requires organization admin and a token with “Administration” read.",
                            isSecret: false, isOptional: true),
        ],
        capabilities: ConnectorCapabilities(dailySpend: false, breakdownByLineItem: true, breakdownByProject: true, breakdownByAccount: true),
        consoleURL: URL(string: "https://github.com/settings/personal-access-tokens")!,
        credentialSummary: "A classic GitHub personal access token created at https://github.com/settings/tokens (Generate new token (classic)) with the scopes user (personal billing), repo (organization billing; admin:org also works) and read:org (list organizations); plus the GitHub username (login, not e-mail). Fine-grained tokens are tied to a single owner and get HTTP 404 for other organizations. Organization billing requires the user to be an organization admin. The account must be on GitHub's enhanced billing platform. Fixed plans such as GitHub Pro or Copilot are not in the usage report and are entered as subscriptions."
    )

    let http: HTTPClient

    func fetch(_ request: FetchRequest) async throws -> ConnectorSnapshot {
        let token = try request.required("token")
        let username = try Self.validatedName(request.required("username"))
        // Every organization the token can see, plus an optional one entered by hand (DEC-032).
        var organizations = (try? await listOrganizations(token: token)) ?? []
        if let extra = request.optional("organization") {
            let name = try Self.validatedName(extra)
            if !organizations.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { organizations.append(name) }
        }

        var daily: [Day: Decimal] = [:]
        var breakdown: [BreakdownRow] = []
        var notes: [ProviderNote] = []
        // Accounts that cannot be read are reported, not fatal; the refresh fails only if none can be read.
        var readable = 0
        var firstError: ConnectorError?
        do {
            try await collect(token: token, account: username, path: "/users/\(username)/settings/billing/usage",
                              request: request, daily: &daily, breakdown: &breakdown)
            readable += 1
        } catch let error as ConnectorError {
            firstError = error
            notes.append(Self.note(for: error, account: username, isOrganization: false))
        }
        for organization in organizations {
            do {
                try await collect(token: token, account: organization,
                                  path: "/organizations/\(try Self.validatedName(organization))/settings/billing/usage",
                                  request: request, daily: &daily, breakdown: &breakdown)
                readable += 1
            } catch let error as ConnectorError {
                firstError = firstError ?? error
                notes.append(Self.note(for: error, account: organization, isOrganization: true))
            }
        }
        if readable == 0, let firstError { throw firstError }
        return ConnectorSnapshot(dailyCosts: daily, coveredFrom: request.from, keys: nil, tokenUsage: nil,
                                 breakdown: breakdown.merged(), breakdownFrom: request.from.calendarMonth, notes: notes)
    }

    private func collect(token: String, account: String, path: String, request: FetchRequest,
                         daily: inout [Day: Decimal], breakdown: inout [BreakdownRow]) async throws {
        for year in request.from.year...request.today.year {
            let report = try await http.fetchJSON(UsageReport.self, Self.request(token: token, path: path, year: year))
            for item in report.usageItems {
                guard let dateText = item.date, let day = Day(isoPrefix: dateText), day >= request.from else { continue }
                let amount = item.netAmount?.value ?? 0
                daily[day, default: 0] += amount
                let month = day.calendarMonth
                let lineItem = [item.product, item.sku].compactMap { $0 }.joined(separator: " · ")
                breakdown.append(BreakdownRow(month: month, dimension: .lineItem,
                                              label: lineItem.isEmpty ? String(localized: "Other") : lineItem, amount: amount))
                breakdown.append(BreakdownRow(month: month, dimension: .account, label: account, amount: amount))
                let repository = item.repositoryName.map { $0.contains("/") ? $0 : "\(account)/\($0)" }
                    ?? String(localized: "\(account) (no repository)")
                breakdown.append(BreakdownRow(month: month, dimension: .project, label: repository, amount: amount))
            }
        }
    }

    private struct Organization: Decodable { let login: String }

    private func listOrganizations(token: String) async throws -> [String] {
        var logins: [String] = []
        var page = 1
        while page <= 10 {
            var request = URLRequest(url: .api("https://api.github.com/user/orgs", [("per_page", "100"), ("page", String(page))]))
            Self.authorize(&request, token: token)
            let batch = try await http.fetchJSON([Organization].self, request)
            logins += batch.map(\.login)
            if batch.count < 100 { break }
            page += 1
        }
        return logins
    }

    private static func shortReason(_ error: ConnectorError) -> String {
        switch error {
        case .http(let status, _): "HTTP \(status)"
        case .unauthorized: String(localized: "access denied")
        case .forbidden(let message): message
        default: error.localizedDescription
        }
    }

    /// GitHub says "No access to billing usage data" (403) for organizations without billing data even for
    /// admins with the right scopes, so that case is informational; everything else is a fixable warning.
    static func note(for error: ConnectorError, account: String, isOrganization: Bool) -> ProviderNote {
        let id = "github.\(isOrganization ? "org" : "user").\(account.lowercased())"
        if case .forbidden(let message) = error, message.localizedCaseInsensitiveContains("No access to billing usage data") {
            return ProviderNote(id: id, kind: .info,
                                text: String(localized: "GitHub reports no billing data for \(account) (\u{201C}\(message)\u{201D})."))
        }
        let text = isOrganization
            ? String(localized: "Organization \(account): billing not readable (\(shortReason(error))). Use a classic token with the “repo” scope (fine-grained tokens cannot read other owners); you must be an organization admin.")
            : String(localized: "Account \(account): billing not readable (\(shortReason(error))). A classic token needs the “user” scope.")
        return ProviderNote(id: id, kind: .warning, text: text)
    }

    struct UsageReport: Decodable {
        struct Item: Decodable {
            let date: String?
            let product: String?
            let sku: String?
            let netAmount: FlexibleDecimal?
            let repositoryName: String?
            let organizationName: String?
        }
        let usageItems: [Item]
    }

    /// GitHub logins and organization names: letters, digits and single hyphens.
    static func validatedName(_ name: String) throws -> String {
        guard name.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$"#, options: .regularExpression) != nil else {
            throw ConnectorError.invalidConfiguration("GitHub username or organization")
        }
        return name
    }

    private static func request(token: String, path: String, year: Int) -> URLRequest {
        var request = URLRequest(url: .api("https://api.github.com" + path, [("year", String(year))]))
        authorize(&request, token: token)
        return request
    }

    private static func authorize(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
    }
}
