import Foundation
import Security

/// Google Cloud / Firebase spend from the Cloud Billing standard usage cost export in BigQuery (SRC-002).
/// Net cost = cost + credits, converted to USD with the export's own `currency_conversion_rate` (DEC-005).
struct GoogleCloudConnector: Connector {
    static let descriptor = ConnectorDescriptor(
        id: .googleCloud,
        displayName: "Google Cloud / Firebase",
        aliases: ["googlecloud", "gcp", "gcloud", "firebase", "googlecloudplatform", "googlebilling"],
        credentialFields: [
            CredentialField(id: "serviceAccountJSON", label: "Service account JSON key",
                            help: "IAM & Admin → Service Accounts → Keys → Add key → JSON. Needs BigQuery Job User on the project and BigQuery Data Viewer on the billing export dataset.",
                            isSecret: true, isMultiline: true),
            CredentialField(id: "dataset", label: "Export datasets",
                            help: "BigQuery datasets of the Cloud Billing export as project.dataset, comma-separated (one per billing account if they export to different projects). All export tables in them are found automatically.",
                            isSecret: false),
            CredentialField(id: "billingAccountId", label: "Billing account ID",
                            help: "Optional: read only this billing account, e.g. 012345-6789AB-CDEF01.",
                            isSecret: false, isOptional: true),
            CredentialField(id: "keyProjects", label: "Projects with API keys",
                            help: "Optional: project IDs, comma-separated, whose API keys (e.g. Gemini) are listed with requests per key. The service account needs API Keys Viewer and Monitoring Viewer there.",
                            isSecret: false, isOptional: true),
            CredentialField(id: "location", label: "Dataset location",
                            help: "BigQuery location of the dataset, e.g. US or EU. Default: US.",
                            isSecret: false, isOptional: true),
        ],
        capabilities: ConnectorCapabilities(keyDetails: true, keySpend: true, keySpendIsEstimate: true,
                                            breakdownByLineItem: true, breakdownByProject: true, breakdownByAccount: true,
                                            keyRequests: true),
        consoleURL: URL(string: "https://console.cloud.google.com/billing/export")!,
        credentialSummary: "Cloud Billing standard usage cost export to BigQuery must be enabled (Billing → Billing export). Then a service account JSON key with BigQuery Job User on the project and BigQuery Data Viewer on the export dataset, plus the export dataset(s) as project.dataset. Google only lets a billing account export into a project linked to that account, so several billing accounts may need several datasets; one service account key can read all of them."
    )

    let http: HTTPClient

    struct ServiceAccount: Decodable, Sendable {
        let client_email: String
        let private_key: String
        let private_key_id: String?
        let project_id: String?
        let token_uri: String?
    }

    func fetch(_ request: FetchRequest) async throws -> ConnectorSnapshot {
        let account: ServiceAccount
        do {
            account = try JSONDecoder().decode(ServiceAccount.self, from: Data(try request.required("serviceAccountJSON").utf8))
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw ConnectorError.invalidConfiguration("service account JSON")
        }
        let datasets = try request.required("dataset").split(separator: ",")
            .map { try Self.datasetReference($0.trimmingCharacters(in: .whitespaces), defaultProject: account.project_id) }
        let location = request.optional("location") ?? "US"
        let token = try await accessToken(account: account, now: request.now)

        // Every standard export table in the datasets (one per billing account), optionally one account only.
        var tables: [TableReference] = []
        for dataset in datasets {
            tables += try await exportTables(in: dataset, token: token)
        }
        if let only = request.optional("billingAccountId") {
            let suffix = only.uppercased().replacingOccurrences(of: "-", with: "_")
            tables = tables.filter { $0.table.hasSuffix(suffix) }
        }
        // API keys with requests this month (DEC-035); per project, failures become notes.
        var keys: [ProviderKey]?
        var notes: [ProviderNote] = []
        var requestsByKey: [String: [String: Int]] = [:]
        var keyProjectIDs: [String: String] = [:]
        if let keyProjects = request.optional("keyProjects") {
            keys = []
            for project in keyProjects.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !project.isEmpty {
                do {
                    let validated = try Self.datasetReference("\(project).x", defaultProject: nil).project
                    let (projectKeys, projectRequests, requestsError) = try await apiKeys(project: validated, token: token, now: request.now)
                    keys! += projectKeys
                    requestsByKey.merge(projectRequests) { _, new in new }
                    for key in projectKeys { keyProjectIDs[key.externalID] = validated }
                    if let requestsError {
                        notes.append(ProviderNote(id: "gcp.requests.\(project)", kind: .warning,
                                                  text: String(localized: "Requests per key for \(project) not readable (\(requestsError.localizedDescription)).")))
                    }
                } catch let error as ConnectorError {
                    notes.append(ProviderNote(id: "gcp.keys.\(project)", kind: .warning,
                                              text: String(localized: "API keys of \(project) not readable (\(error.localizedDescription)).")))
                }
            }
        }
        guard !tables.isEmpty else {
            return ConnectorSnapshot(dailyCosts: [:], coveredFrom: request.from, keys: keys, tokenUsage: nil,
                                     spendUnavailableReason: String(localized: "Billing export is set up, but Google has not written any data to the dataset yet. This takes up to a day after enabling the export."),
                                     notes: notes)
        }
        let source = Self.unionSource(tables)
        let queryProject = account.project_id ?? tables[0].project
        let rows = try await runQuery(Self.dailyCostSQL(table: source, from: request.from), project: queryProject,
                                      location: location, token: token)

        var daily: [Day: Decimal] = [:]
        for row in rows {
            guard row.count == 2, let dayString = row[0], let day = Day(isoPrefix: dayString),
                  let amountString = row[1], let amount = Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX"))
            else { continue }
            daily[day, default: 0] += amount
        }
        // The export only contains data from shortly before it was enabled; earlier months are "no data".
        let coveredFrom = daily.keys.min().map { max($0.calendarMonth.firstDay, request.from) }
            ?? request.today.calendarMonth.firstDay
        // Breakdown by Google service, project and billing account; a failing query only drops the breakdown.
        var breakdown: [BreakdownRow]?
        if let monthly = try? await runQuery(Self.monthlyBreakdownSQL(table: source, from: coveredFrom), project: queryProject,
                                              location: location, token: token) {
            breakdown = monthly.compactMap { row -> [BreakdownRow]? in
                guard row.count == 5, let monthText = row[0], let month = Day(isoPrefix: monthText + "-01")?.calendarMonth,
                      let amountText = row[4], let amount = Decimal(string: amountText, locale: Locale(identifier: "en_US_POSIX"))
                else { return nil }
                return [BreakdownRow(month: month, dimension: .lineItem, label: row[1] ?? String(localized: "Other"), amount: amount),
                        BreakdownRow(month: month, dimension: .project, label: row[2] ?? String(localized: "No project"), amount: amount),
                        BreakdownRow(month: month, dimension: .account, label: row[3] ?? String(localized: "Other"), amount: amount)]
            }.flatMap { $0 }.merged()
        }
        // ≈ cost per key (DEC-036): this month's (project, service) cost split by each key's share of requests.
        if var allKeys = keys, !requestsByKey.isEmpty,
           let costRows = try? await runQuery(Self.currentMonthServiceCostSQL(table: source, monthStart: request.today.calendarMonth.firstDay),
                                              project: queryProject, location: location, token: token) {
            var costs: [KeyCostSplit.ServiceCost: Decimal] = [:]
            for row in costRows {
                guard row.count == 3, let project = row[0], let service = row[1],
                      let amount = row[2].flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }) else { continue }
                costs[KeyCostSplit.ServiceCost(project: project, service: service), default: 0] += amount
            }
            let perKey = KeyCostSplit.split(costs: costs, requests: requestsByKey, keyProjects: keyProjectIDs)
            for index in allKeys.indices where allKeys[index].requestsThisMonth != nil {
                allKeys[index].currentMonthCost = perKey[allKeys[index].externalID] ?? 0
            }
            keys = allKeys
        }
        return ConnectorSnapshot(dailyCosts: daily, coveredFrom: coveredFrom, keys: keys, tokenUsage: nil,
                                 breakdown: breakdown, breakdownFrom: breakdown == nil ? nil : coveredFrom.calendarMonth,
                                 notes: notes)
    }

    // MARK: API keys and requests (DEC-035)

    private struct KeyList: Decodable {
        struct Key: Decodable {
            struct Restrictions: Decodable {
                struct Target: Decodable { let service: String? }
                let apiTargets: [Target]?
            }
            let uid: String
            let displayName: String?
            let createTime: String?
            let restrictions: Restrictions?
        }
        let keys: [Key]?
        let nextPageToken: String?
    }

    /// Keys of a project with their requests (per key and per called service); a failure to read requests
    /// leaves them unavailable (nil), never zero.
    private func apiKeys(project: String, token: String, now: Date) async throws -> ([ProviderKey], [String: [String: Int]], Error?) {
        var listed: [KeyList.Key] = []
        var pageToken: String?
        repeat {
            var items: [(String, String)] = []
            if let pageToken { items.append(("pageToken", pageToken)) }
            var request = URLRequest(url: .api("https://apikeys.googleapis.com/v2/projects/\(project)/locations/global/keys", items))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let page = try await http.fetchJSON(KeyList.self, request)
            listed += page.keys ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        // Request counts are optional: without Monitoring access keys still show, with requests unavailable.
        var requests: [String: [String: Int]]?
        var requestsError: Error?
        do {
            requests = try await requestCounts(project: project, token: token, now: now)
        } catch {
            requestsError = error
        }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let keys = listed.map { key in
            let apis = (key.restrictions?.apiTargets ?? []).compactMap(\.service)
            var details = [KeyDetail(kind: .project, value: project)]
            details.append(KeyDetail(kind: .scopes, value: apis.isEmpty ? String(localized: "any API (unrestricted)") : apis.joined(separator: ", ")))
            return ProviderKey(externalID: key.uid, name: key.displayName ?? key.uid, hint: project,
                               createdAt: key.createTime.flatMap { parser.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) },
                               lastUsedAt: nil, expiresAt: nil, status: nil, currentMonthCost: nil, details: details,
                               requestsThisMonth: requests.map { $0[key.uid]?.values.reduce(0, +) ?? 0 },
                               consoleURL: URL(string: "https://console.cloud.google.com/apis/credentials/key/\(key.uid)?project=\(project)"))
        }
        return (keys, requests ?? [:], requestsError)
    }

    private struct TimeSeriesList: Decodable {
        struct Series: Decodable {
            struct Resource: Decodable { let labels: [String: String] }
            struct Point: Decodable {
                struct Value: Decodable { let int64Value: String?; let doubleValue: Double? }
                let value: Value
            }
            let resource: Resource
            let points: [Point]
        }
        let timeSeries: [Series]?
        let nextPageToken: String?
    }

    /// Month-to-date API requests per key UID (`credential_id = apikey:<uid>`) and called service.
    private func requestCounts(project: String, token: String, now: Date) async throws -> [String: [String: Int]] {
        let start = Day(now, calendar: .utc).calendarMonth.firstDay
        let seconds = max(60, Int(now.timeIntervalSince(start.startDate(calendar: .utc))))
        var counts: [String: [String: Int]] = [:]
        var pageToken: String?
        repeat {
            var items = [
                ("filter", #"metric.type="serviceruntime.googleapis.com/api/request_count" AND resource.type="consumed_api""#),
                ("interval.startTime", "\(start)T00:00:00Z"),
                ("interval.endTime", ISO8601DateFormatter().string(from: now)),
                ("aggregation.alignmentPeriod", "\(seconds)s"),
                ("aggregation.perSeriesAligner", "ALIGN_SUM"),
                ("aggregation.crossSeriesReducer", "REDUCE_SUM"),
                ("aggregation.groupByFields", "resource.labels.credential_id"),
                ("aggregation.groupByFields", "resource.labels.service"),
            ]
            if let pageToken { items.append(("pageToken", pageToken)) }
            var request = URLRequest(url: .api("https://monitoring.googleapis.com/v3/projects/\(project)/timeSeries", items))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let page = try await http.fetchJSON(TimeSeriesList.self, request)
            for series in page.timeSeries ?? [] {
                guard let credential = series.resource.labels["credential_id"], credential.hasPrefix("apikey:") else { continue }
                let total = series.points.reduce(0) { $0 + (Int($1.value.int64Value ?? "") ?? Int($1.value.doubleValue ?? 0)) }
                let service = series.resource.labels["service"] ?? ""
                counts[String(credential.dropFirst("apikey:".count)), default: [:]][service, default: 0] += total
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return counts
    }

    // MARK: Datasets and tables

    struct DatasetReference: Equatable {
        let project: String
        let dataset: String
    }

    /// Validates `project.dataset` (or `dataset` in the key's project) strictly so input cannot alter queries.
    static func datasetReference(_ text: String, defaultProject: String?) throws -> DatasetReference {
        let parts = text.split(separator: ".").map(String.init)
        let project: String
        let dataset: String
        switch parts.count {
        case 1:
            guard let defaultProject else { throw ConnectorError.invalidConfiguration("dataset needs project.dataset") }
            (project, dataset) = (defaultProject, parts[0])
        case 2:
            (project, dataset) = (parts[0], parts[1])
        default:
            throw ConnectorError.invalidConfiguration("dataset")
        }
        guard project.range(of: #"^[a-z0-9\-.:]{1,100}$"#, options: .regularExpression) != nil,
              dataset.range(of: #"^[A-Za-z0-9_]{1,1024}$"#, options: .regularExpression) != nil
        else { throw ConnectorError.invalidConfiguration("dataset \(text)") }
        return DatasetReference(project: project, dataset: dataset)
    }

    private struct TableList: Decodable {
        struct Table: Decodable {
            struct Reference: Decodable { let projectId: String; let datasetId: String; let tableId: String }
            let tableReference: Reference
        }
        let tables: [Table]?
        let nextPageToken: String?
    }

    /// Standard usage cost export tables (`gcp_billing_export_v1_<ACCOUNT>`) in a dataset.
    private func exportTables(in dataset: DatasetReference, token: String) async throws -> [TableReference] {
        var result: [TableReference] = []
        var pageToken: String?
        repeat {
            var items = [("maxResults", "1000")]
            if let pageToken { items.append(("pageToken", pageToken)) }
            var request = URLRequest(url: .api("https://bigquery.googleapis.com/bigquery/v2/projects/\(dataset.project)/datasets/\(dataset.dataset)/tables", items))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let page = try await http.fetchJSON(TableList.self, request)
            result += (page.tables ?? []).map(\.tableReference)
                .filter { $0.tableId.range(of: #"^gcp_billing_export_v1_[A-Z0-9_]{6,40}$"#, options: .regularExpression) != nil }
                .map { TableReference(project: $0.projectId, dataset: $0.datasetId, table: $0.tableId) }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return result
    }

    /// One FROM source over all export tables.
    static func unionSource(_ tables: [TableReference]) -> String {
        if tables.count == 1 { return tables[0].fullName }
        let selects = tables.map {
            "SELECT usage_start_time, cost, credits, currency_conversion_rate, service, project, billing_account_id FROM \($0.fullName)"
        }
        return "(" + selects.joined(separator: " UNION ALL ") + ")"
    }

    // MARK: SQL

    struct TableReference: Equatable {
        let project: String
        let dataset: String
        let table: String
        var fullName: String { "`\(project).\(dataset).\(table)`" }
    }

    /// Validates identifiers strictly so user input cannot alter the query.
    static func tableReference(dataset: String, billingAccount: String, defaultProject: String?) throws -> TableReference {
        let parts = dataset.split(separator: ".").map(String.init)
        let project: String
        let datasetID: String
        switch parts.count {
        case 1:
            guard let defaultProject else { throw ConnectorError.invalidConfiguration("dataset needs project.dataset") }
            (project, datasetID) = (defaultProject, parts[0])
        case 2:
            (project, datasetID) = (parts[0], parts[1])
        default:
            throw ConnectorError.invalidConfiguration("dataset")
        }
        let account = billingAccount.uppercased().replacingOccurrences(of: "-", with: "_")
        guard project.range(of: #"^[a-z][a-z0-9\-]{4,61}[a-z0-9]$"#, options: .regularExpression) != nil
                || project.range(of: #"^[a-z0-9\-.:]{1,100}$"#, options: .regularExpression) != nil,
              datasetID.range(of: #"^[A-Za-z0-9_]{1,1024}$"#, options: .regularExpression) != nil,
              account.range(of: #"^[A-Z0-9_]{6,40}$"#, options: .regularExpression) != nil
        else { throw ConnectorError.invalidConfiguration("dataset or billing account ID") }
        return TableReference(project: project, dataset: datasetID, table: "gcp_billing_export_v1_\(account)")
    }

    static func dailyCostSQL(table: String, from: Day) -> String {
        """
        SELECT FORMAT_DATE('%Y-%m-%d', DATE(usage_start_time, 'America/Los_Angeles')) AS day,
          CAST(SUM((cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0))
            / IFNULL(NULLIF(currency_conversion_rate, 0), 1)) AS STRING) AS usd
        FROM \(table)
        WHERE usage_start_time >= TIMESTAMP('\(from)')
        GROUP BY day
        ORDER BY day
        """
    }

    static func monthlyBreakdownSQL(table: String, from: Day) -> String {
        """
        SELECT FORMAT_DATE('%Y-%m', DATE(usage_start_time, 'America/Los_Angeles')) AS month,
          service.description AS service, project.name AS project, billing_account_id AS account,
          CAST(SUM((cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0))
            / IFNULL(NULLIF(currency_conversion_rate, 0), 1)) AS STRING) AS usd
        FROM \(table)
        WHERE usage_start_time >= TIMESTAMP('\(from)')
        GROUP BY month, service, project, account
        ORDER BY month
        """
    }

    /// This month's net cost per (project ID, service ID), the IDs Cloud Monitoring also uses.
    static func currentMonthServiceCostSQL(table: String, monthStart: Day) -> String {
        """
        SELECT project.id AS project, service.id AS service,
          CAST(SUM((cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0))
            / IFNULL(NULLIF(currency_conversion_rate, 0), 1)) AS STRING) AS usd
        FROM \(table)
        WHERE usage_start_time >= TIMESTAMP('\(monthStart)')
        GROUP BY project, service
        """
    }

    // MARK: BigQuery

    private struct QueryResponse: Decodable {
        struct Row: Decodable {
            struct Cell: Decodable { let v: String? }
            let f: [Cell]
        }
        struct JobReference: Decodable { let jobId: String; let location: String? }
        let jobComplete: Bool?
        let rows: [Row]?
        let pageToken: String?
        let jobReference: JobReference?
    }

    private func runQuery(_ sql: String, project: String, location: String, token: String) async throws -> [[String?]] {
        let base = "https://bigquery.googleapis.com/bigquery/v2/projects/\(project)/queries"
        var post = URLRequest(url: URL(string: base)!)
        post.httpMethod = "POST"
        post.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": sql, "useLegacySql": false, "timeoutMs": 30_000, "location": location,
        ])
        var response = try await http.fetchJSON(QueryResponse.self, post)
        var rows: [[String?]] = []
        var attempts = 0
        while true {
            if response.jobComplete == true {
                rows += (response.rows ?? []).map { $0.f.map(\.v) }
                if response.pageToken == nil { return rows }
            }
            attempts += 1
            guard attempts < 20, let job = response.jobReference else {
                throw ConnectorError.malformedResponse("BigQuery job did not complete")
            }
            var items = [("timeoutMs", "10000"), ("location", job.location ?? location)]
            if response.jobComplete == true, let pageToken = response.pageToken { items.append(("pageToken", pageToken)) }
            var get = URLRequest(url: .api("\(base)/\(job.jobId)", items))
            get.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            response = try await http.fetchJSON(QueryResponse.self, get)
        }
    }

    // MARK: OAuth2 JWT bearer flow

    private struct TokenResponse: Decodable { let access_token: String }

    private func accessToken(account: ServiceAccount, now: Date) async throws -> String {
        let tokenURL = account.token_uri ?? "https://oauth2.googleapis.com/token"
        let assertion = try Self.signedJWT(account: account, audience: tokenURL, now: now)
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)
        return try await http.fetchJSON(TokenResponse.self, request).access_token
    }

    static func signedJWT(account: ServiceAccount, audience: String, now: Date) throws -> String {
        var header: [String: String] = ["alg": "RS256", "typ": "JWT"]
        header["kid"] = account.private_key_id
        let issued = Int(now.timeIntervalSince1970)
        let claims: [String: Any] = [
            "iss": account.client_email,
            // BigQuery queries plus read-only access for API keys (cloud-platform.read-only) and Cloud Monitoring, which
            // accepts only its own scopes (monitoring.read) (DEC-035).
            "scope": "https://www.googleapis.com/auth/bigquery https://www.googleapis.com/auth/cloud-platform.read-only https://www.googleapis.com/auth/monitoring.read",
            "aud": audience,
            "iat": issued,
            "exp": issued + 3600,
        ]
        let signingInput = try base64URL(JSONSerialization.data(withJSONObject: header, options: .sortedKeys))
            + "." + base64URL(JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        let key = try RSAPrivateKey.load(pem: account.private_key)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                    Data(signingInput.utf8) as CFData, &error) as Data? else {
            throw ConnectorError.invalidConfiguration("cannot sign with the service account key")
        }
        return signingInput + "." + base64URL(signature)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Loads an RSA private key from a PEM "PRIVATE KEY" (PKCS#8) or "RSA PRIVATE KEY" (PKCS#1) block.
enum RSAPrivateKey {
    static func load(pem: String) throws -> SecKey {
        let isPKCS1 = pem.contains("BEGIN RSA PRIVATE KEY")
        let body = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body) else {
            throw ConnectorError.invalidConfiguration("private key is not valid PEM")
        }
        let pkcs1 = isPKCS1 ? der : try unwrapPKCS8(der)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw ConnectorError.invalidConfiguration("unsupported private key")
        }
        return key
    }

    /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }
    static func unwrapPKCS8(_ der: Data) throws -> Data {
        var reader = DERReader(bytes: [UInt8](der))
        let outer = try reader.read(tag: 0x30)
        var inner = DERReader(bytes: outer)
        _ = try inner.read(tag: 0x02)
        _ = try inner.read(tag: 0x30)
        return Data(try inner.read(tag: 0x04))
    }

    struct DERReader {
        var bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func read(tag: UInt8) throws -> [UInt8] {
            guard offset < bytes.count, bytes[offset] == tag else { throw ConnectorError.invalidConfiguration("private key structure") }
            offset += 1
            guard offset < bytes.count else { throw ConnectorError.invalidConfiguration("private key length") }
            var length = Int(bytes[offset])
            offset += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 4, offset + count <= bytes.count else { throw ConnectorError.invalidConfiguration("private key length") }
                length = bytes[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
                offset += count
            }
            guard offset + length <= bytes.count else { throw ConnectorError.invalidConfiguration("private key length") }
            defer { offset += length }
            return Array(bytes[offset..<offset + length])
        }
    }
}
