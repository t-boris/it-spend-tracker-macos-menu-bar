import Foundation

/// Cline account sign-in (DEC-040): WorkOS device authorization, then the session is registered with Cline.
/// Cline has no API keys for account data; the session (1-hour access token + refresh token) is the credential
/// and lives in the Keychain like any other credential. Flow and endpoints follow the Cline CLI (no public docs).
struct ClineAuth: Sendable {
    let http: HTTPClient

    static let apiBase = "https://api.cline.bot"
    static let workOSBase = "https://api.workos.com"
    /// Cline's production WorkOS client (the one the Cline CLI and extension sign in with).
    static let workOSClientID = "client_01K3A541FN8TA3EPPHTD2325AR"
    /// Tokens are refreshed when they expire within this interval.
    static let refreshMargin: TimeInterval = 300

    /// Keychain fields of a Cline session.
    enum Field {
        static let accessToken = "accessToken"
        static let refreshToken = "refreshToken"
        static let expiresAt = "expiresAt"
        static let userID = "userId"
        static let email = "email"
        static let all = [accessToken, refreshToken, expiresAt, userID, email]
    }

    enum AuthError: LocalizedError, Equatable {
        case denied(String)
        case expired
        case signInRequired
        case differentAccount(String)

        var errorDescription: String? {
            switch self {
            case .denied(let message): String(localized: "Cline sign-in failed: \(message)")
            case .expired: String(localized: "The Cline sign-in code expired. Start the sign-in again.")
            case .signInRequired: String(localized: "The Cline session has ended. Sign in to Cline again.")
            case .differentAccount(let account):
                String(localized: "This is a different Cline account. Sign in as \(account), or add the other account as a separate service.")
            }
        }
    }

    struct DeviceAuthorization: Sendable, Equatable {
        var deviceCode: String
        var userCode: String
        var verificationURL: URL
        var expiresIn: TimeInterval
        var interval: TimeInterval
    }

    // MARK: Device authorization

    private struct DeviceResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let verification_uri_complete: String?
        let expires_in: FlexibleNumber?
        let interval: FlexibleNumber?
    }

    func startDeviceAuthorization() async throws -> DeviceAuthorization {
        let request = Self.formRequest(Self.workOSBase + "/user_management/authorize/device",
                                       ["client_id": Self.workOSClientID])
        let response = try await http.fetchJSON(DeviceResponse.self, request)
        guard let url = URL(string: response.verification_uri_complete ?? response.verification_uri) else {
            throw ConnectorError.malformedResponse("verification URL")
        }
        return DeviceAuthorization(deviceCode: response.device_code, userCode: response.user_code, verificationURL: url,
                                   expiresIn: response.expires_in?.value ?? 300, interval: max(1, response.interval?.value ?? 5))
    }

    private struct WorkOSTokens: Decodable {
        let access_token: String?
        let refresh_token: String?
        let error: String?
        let error_description: String?
    }

    /// Waits until the user confirms the code in the browser, then returns the Cline session credentials.
    /// `sleep` is injectable so tests do not wait.
    func completeSignIn(_ authorization: DeviceAuthorization, now: @Sendable () -> Date = { Date() },
                        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) })
        async throws -> [String: String] {
        let deadline = now().addingTimeInterval(authorization.expiresIn)
        var interval = authorization.interval
        while now() < deadline {
            try await sleep(interval)
            let request = Self.formRequest(Self.workOSBase + "/user_management/authenticate", [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": authorization.deviceCode,
                "client_id": Self.workOSClientID,
            ])
            let (data, _) = try await http.send(request)
            guard let tokens = try? JSONDecoder().decode(WorkOSTokens.self, from: data) else {
                throw ConnectorError.malformedResponse("WorkOS token response")
            }
            if let access = tokens.access_token, let refresh = tokens.refresh_token {
                return try await register(accessToken: access, refreshToken: refresh, now: now())
            }
            switch tokens.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5  // RFC 8628 §3.5
            case "expired_token": throw AuthError.expired
            default: throw AuthError.denied(tokens.error_description ?? tokens.error ?? "unknown error")
            }
        }
        throw AuthError.expired
    }

    // MARK: Cline session

    private struct SessionResponse: Decodable {
        struct Session: Decodable {
            struct UserInfo: Decodable { let clineUserId: String?; let email: String? }
            let accessToken: String
            let refreshToken: String?
            let expiresAt: String?
            let userInfo: UserInfo?
        }
        let data: Session?
    }

    private func register(accessToken: String, refreshToken: String, now: Date) async throws -> [String: String] {
        let request = Self.jsonRequest(Self.apiBase + "/api/v1/auth/register",
                                       ["accessToken": accessToken, "refreshToken": refreshToken])
        return try await session(from: request, previous: [:], now: now)
    }

    /// Returns new credentials when the access token is missing or expires soon, `nil` when it is still valid.
    /// A rejected refresh token means the user has to sign in again.
    func refreshedCredentials(_ credentials: [String: String], now: Date) async throws -> [String: String]? {
        guard let refreshToken = credentials[Field.refreshToken]?.nilIfEmpty else { throw AuthError.signInRequired }
        if credentials[Field.accessToken]?.nilIfEmpty != nil,
           let expiry = credentials[Field.expiresAt].flatMap(Self.parseDate),
           expiry.timeIntervalSince(now) > Self.refreshMargin {
            return nil
        }
        let request = Self.jsonRequest(Self.apiBase + "/api/v1/auth/refresh",
                                       ["refreshToken": refreshToken, "grantType": "refresh_token"])
        do {
            return try await session(from: request, previous: credentials, now: now)
        } catch ConnectorError.unauthorized, ConnectorError.forbidden {
            throw AuthError.signInRequired
        } catch ConnectorError.http(let status, _) where status == 400 {
            throw AuthError.signInRequired
        }
    }

    private func session(from request: URLRequest, previous: [String: String], now: Date) async throws -> [String: String] {
        guard let session = try await http.fetchJSON(SessionResponse.self, request).data else {
            throw ConnectorError.malformedResponse("Cline session response")
        }
        var credentials = previous
        credentials[Field.accessToken] = session.accessToken
        if let refresh = session.refreshToken?.nilIfEmpty { credentials[Field.refreshToken] = refresh }
        // Without an expiry the token is treated as valid for one hour (Cline's current lifetime).
        let expiry = session.expiresAt.flatMap(Self.parseDate) ?? now.addingTimeInterval(3600)
        credentials[Field.expiresAt] = ISO8601DateFormatter().string(from: expiry)
        if let id = session.userInfo?.clineUserId?.nilIfEmpty { credentials[Field.userID] = id }
        if let email = session.userInfo?.email?.nilIfEmpty { credentials[Field.email] = email }
        guard credentials[Field.refreshToken]?.nilIfEmpty != nil else {
            throw ConnectorError.malformedResponse("Cline session without a refresh token")
        }
        return credentials
    }

    // MARK: Requests

    /// Account API requests: Cline expects the WorkOS access token with a `workos:` prefix.
    static func apiRequest(path: String, items: [(String, String)] = [], accessToken: String) -> URLRequest {
        var request = URLRequest(url: .api(apiBase + path, items))
        let token = accessToken.lowercased().hasPrefix("workos:") ? accessToken : "workos:" + accessToken
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func formRequest(_ address: String, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return request
    }

    private static func jsonRequest(_ address: String, _ body: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
