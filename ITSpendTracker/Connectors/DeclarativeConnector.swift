import Foundation

/// A connector definition proposed by the onboarding AI and approved by the user (DEC-022, REQ-012).
/// It is data only: HTTPS GET endpoints on one host plus JSON paths to the values.
struct ConnectorDefinition: Codable, Sendable, Equatable {
    struct Field: Codable, Sendable, Equatable {
        var id: String
        var label: String
        var help: String?
        var secret: Bool
    }

    struct Auth: Codable, Sendable, Equatable {
        enum Scheme: String, Codable, Sendable { case bearer, header }
        var scheme: Scheme
        /// Header name for `.header` (e.g. `x-api-key`); `Authorization` for `.bearer`.
        var headerName: String?
        /// Id of the secret credential field whose value is sent in the header.
        var credentialField: String
    }

    struct SpendEndpoint: Codable, Sendable, Equatable {
        enum Unit: String, Codable, Sendable { case usd, cents }
        var path: String
        var itemsPath: String
        var datePath: String
        var amountPath: String
        var amountUnit: Unit
    }

    struct TokenEndpoint: Codable, Sendable, Equatable {
        var path: String
        var itemsPath: String
        var modelPath: String?
        var keyPath: String?
        var inputPath: String
        var outputPath: String
        var cachedInputPath: String?
    }

    struct KeysEndpoint: Codable, Sendable, Equatable {
        var path: String
        var itemsPath: String
        var idPath: String
        var namePath: String?
        var createdPath: String?
        var lastUsedPath: String?
        var expiresPath: String?
    }

    var serviceName: String
    var baseURL: String
    var docsURL: String?
    var auth: Auth
    var credentialFields: [Field]
    var spend: SpendEndpoint?
    var tokens: TokenEndpoint?
    var keys: KeysEndpoint?

    static let placeholders = ["from", "to", "from_unix", "to_unix", "from_iso", "to_iso",
                               "month_start", "month_start_unix", "month_start_iso"]

    /// Returns human-readable problems; an empty list means the definition is safe to show for approval.
    func validationProblems() -> [String] {
        var problems: [String] = []
        guard let base = URL(string: baseURL), base.scheme == "https", let host = base.host(), !host.isEmpty,
              base.user == nil, base.password == nil, base.query == nil else {
            return ["baseURL must be an https URL without credentials or query"]
        }
        if spend == nil && tokens == nil && keys == nil {
            problems.append("no spend, tokens or keys endpoint")
        }
        let secretFields = credentialFields.filter(\.secret).map(\.id)
        if !secretFields.contains(auth.credentialField) {
            problems.append("auth.credentialField must name a secret credential field")
        }
        if Set(credentialFields.map(\.id)).count != credentialFields.count {
            problems.append("duplicate credential field ids")
        }
        if auth.scheme == .header {
            let name = auth.headerName ?? ""
            if name.range(of: #"^[A-Za-z0-9\-]{1,64}$"#, options: .regularExpression) == nil {
                problems.append("auth.headerName is invalid")
            }
        }
        let allowedFields = Set(credentialFields.filter { !$0.secret }.map { "field.\($0.id)" })
        for path in [spend?.path, tokens?.path, keys?.path].compactMap({ $0 }) {
            if !path.hasPrefix("/") || path.hasPrefix("//") || path.contains("@") || path.contains("\\") {
                problems.append("path \(path) must be relative to the base URL")
                continue
            }
            for name in Self.placeholderNames(in: path) where !Self.placeholders.contains(name) && !allowedFields.contains(name) {
                problems.append("path \(path) uses unknown or secret placeholder {\(name)}")
            }
        }
        return problems
    }

    var host: String { URL(string: baseURL)?.host() ?? "" }

    static func placeholderNames(in path: String) -> [String] {
        let regex = try! Regex(#"\{([A-Za-z0-9_.\-]+)\}"#)
        return path.matches(of: regex).compactMap { $0.output[1].substring.map(String.init) }
    }

    /// Resolves a path template to a URL on the definition's host, or `nil` if it would leave the host.
    func url(for template: String, values: [String: String]) -> URL? {
        var path = template
        for (name, value) in values {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
            path = path.replacingOccurrences(of: "{\(name)}", with: encoded)
        }
        guard !path.contains("{"), let base = URL(string: baseURL),
              let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path),
              url.scheme == "https", url.host() == base.host() else { return nil }
        return url
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#/")
        return set
    }()
}

/// Runs an approved `ConnectorDefinition`: HTTPS GET only, one host, secret only in the auth header.
struct DeclarativeConnector: Sendable {
    let definition: ConnectorDefinition
    let http: HTTPClient

    func fetch(_ request: FetchRequest) async throws -> ConnectorSnapshot {
        let problems = definition.validationProblems()
        guard problems.isEmpty else { throw ConnectorError.invalidConfiguration(problems.joined(separator: "; ")) }
        let secret = try request.required(definition.auth.credentialField)
        let values = templateValues(request)

        var daily: [Day: Decimal] = [:]
        var coveredFrom = request.from
        if let spend = definition.spend {
            let items = try await items(at: spend.path, itemsPath: spend.itemsPath, values: values, secret: secret)
            for item in items {
                guard let date = JSONPath.date(item, spend.datePath),
                      let amount = JSONPath.decimal(item, spend.amountPath) else { continue }
                daily[Day(date, calendar: .utc), default: 0] += spend.amountUnit == .cents ? amount / 100 : amount
            }
        } else {
            coveredFrom = request.today.nextDay
        }

        var keys: [ProviderKey]?
        if let spec = definition.keys {
            let items = try await items(at: spec.path, itemsPath: spec.itemsPath, values: values, secret: secret)
            keys = items.compactMap { item in
                guard let id = JSONPath.string(item, spec.idPath) else { return nil }
                return ProviderKey(externalID: id,
                                   name: spec.namePath.flatMap { JSONPath.string(item, $0) } ?? id,
                                   hint: nil,
                                   createdAt: spec.createdPath.flatMap { JSONPath.date(item, $0) },
                                   lastUsedAt: spec.lastUsedPath.flatMap { JSONPath.date(item, $0) },
                                   expiresAt: spec.expiresPath.flatMap { JSONPath.date(item, $0) },
                                   status: nil, currentMonthCost: nil)
            }
        }

        var tokens: [TokenUsageRow]?
        if let spec = definition.tokens {
            let items = try await items(at: spec.path, itemsPath: spec.itemsPath, values: values, secret: secret)
            var rows: [String: TokenUsageRow] = [:]
            for item in items {
                let model = spec.modelPath.flatMap { JSONPath.string(item, $0) } ?? "—"
                let key = spec.keyPath.flatMap { JSONPath.string(item, $0) }
                let id = "\(key ?? "")|\(model)"
                var row = rows[id] ?? TokenUsageRow(keyExternalID: key, model: model, inputTokens: 0,
                                                    cachedInputTokens: spec.cachedInputPath == nil ? nil : 0,
                                                    outputTokens: 0)
                row.inputTokens += JSONPath.int(item, spec.inputPath) ?? 0
                row.outputTokens += JSONPath.int(item, spec.outputPath) ?? 0
                if let cachedPath = spec.cachedInputPath {
                    row.cachedInputTokens = (row.cachedInputTokens ?? 0) + (JSONPath.int(item, cachedPath) ?? 0)
                }
                rows[id] = row
            }
            tokens = rows.values.sorted { ($0.keyExternalID ?? "", $0.model) < ($1.keyExternalID ?? "", $1.model) }
        }

        return ConnectorSnapshot(dailyCosts: daily, coveredFrom: coveredFrom, keys: keys, tokenUsage: tokens)
    }

    private func templateValues(_ request: FetchRequest) -> [String: String] {
        let from = request.from.startDate(calendar: .utc)
        let monthStart = request.today.calendarMonth.firstDay.startDate(calendar: .utc)
        let iso = ISO8601DateFormatter()
        var values: [String: String] = [
            "from": request.from.description,
            "to": request.today.description,
            "from_unix": String(Int(from.timeIntervalSince1970)),
            "to_unix": String(Int(request.now.timeIntervalSince1970)),
            "from_iso": iso.string(from: from),
            "to_iso": iso.string(from: request.now),
            "month_start": request.today.calendarMonth.firstDay.description,
            "month_start_unix": String(Int(monthStart.timeIntervalSince1970)),
            "month_start_iso": iso.string(from: monthStart),
        ]
        for field in definition.credentialFields where !field.secret {
            values["field.\(field.id)"] = request.optional(field.id) ?? ""
        }
        return values
    }

    private func items(at template: String, itemsPath: String, values: [String: String], secret: String) async throws -> [Any] {
        guard let url = definition.url(for: template, values: values) else {
            throw ConnectorError.invalidConfiguration("endpoint \(template)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch definition.auth.scheme {
        case .bearer: request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case .header: request.setValue(secret, forHTTPHeaderField: definition.auth.headerName ?? "")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await http.fetchData(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ConnectorError.malformedResponse("not JSON")
        }
        let node = JSONPath.value(json, itemsPath)
        if let array = node as? [Any] { return array }
        if let node { return [node] }
        throw ConnectorError.malformedResponse("nothing at \(itemsPath)")
    }
}

/// Dot-separated paths into decoded JSON (`data.items.0.cost`); an empty path is the root.
enum JSONPath {
    static func value(_ root: Any, _ path: String) -> Any? {
        var current: Any? = root
        for component in path.split(separator: ".") where !component.isEmpty {
            if let dictionary = current as? [String: Any] {
                current = dictionary[String(component)]
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current is NSNull ? nil : current
    }

    static func string(_ root: Any, _ path: String) -> String? {
        switch value(root, path) {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func decimal(_ root: Any, _ path: String) -> Decimal? {
        switch value(root, path) {
        case let number as NSNumber: Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        case let string as String: Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
        default: nil
        }
    }

    static func int(_ root: Any, _ path: String) -> Int? {
        decimal(root, path).map { NSDecimalNumber(decimal: $0).intValue }
    }

    /// ISO 8601 strings (date or date-time) or Unix timestamps in seconds or milliseconds.
    static func date(_ root: Any, _ path: String) -> Date? {
        switch value(root, path) {
        case let number as NSNumber:
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
        case let string as String:
            if let seconds = Double(string) {
                return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
            }
            let full = ISO8601DateFormatter()
            full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = full.date(from: string) ?? ISO8601DateFormatter().date(from: string) { return date }
            return Day(isoPrefix: string)?.startDate(calendar: .utc)
        default:
            return nil
        }
    }
}
