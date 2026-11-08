import Foundation
import Testing
@testable import ITSpendTracker

/// Answers each request with a handler, so a test can script sequences (device-code polling) and inspect bodies.
private final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (URLRequest) -> (Int, String)
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping (URLRequest) -> (Int, String)) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock { requests.append(request); return handler(request) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    var allRequests: [URLRequest] { lock.withLock { requests } }
}

private let now = Date(timeIntervalSince1970: 1_790_726_400) // 2026-09-30 00:00 UTC

private func body(_ request: URLRequest) -> String { String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "" }

private let session = """
{"success":true,"data":{"accessToken":"acc-2","refreshToken":"ref-2","tokenType":"Bearer","expiresAt":"2026-09-30T01:00:00Z",
 "userInfo":{"clineUserId":"usr-1","email":"me@example.com"}}}
"""

@Suite struct ClineAuthTests {
    @Test func deviceSignInPollsUntilConfirmedThenRegisters() async throws {
        var polls = 0
        let http = ScriptedHTTP { request in
            switch request.url!.path() {
            case "/user_management/authorize/device":
                return (200, #"{"device_code":"dev","user_code":"ABCD-EFGH","verification_uri":"https://authkit.cline.bot/device","verification_uri_complete":"https://authkit.cline.bot/device?user_code=ABCD-EFGH","expires_in":300,"interval":5}"#)
            case "/user_management/authenticate":
                polls += 1
                switch polls {
                case 1: return (400, #"{"error":"authorization_pending"}"#)
                case 2: return (400, #"{"error":"slow_down"}"#)
                default: return (200, #"{"access_token":"wos-acc","refresh_token":"wos-ref","user":{}}"#)
                }
            case "/api/v1/auth/register": return (200, session)
            default: return (404, "")
            }
        }
        let auth = ClineAuth(http: http)
        let authorization = try await auth.startDeviceAuthorization()
        #expect(authorization.userCode == "ABCD-EFGH")
        #expect(authorization.verificationURL.absoluteString.hasSuffix("user_code=ABCD-EFGH"))

        let slept = Recorder()
        let credentials = try await auth.completeSignIn(authorization, now: { now }, sleep: { slept.add($0) })
        #expect(slept.values == [5, 5, 10])  // slow_down adds five seconds
        #expect(credentials == ["accessToken": "acc-2", "refreshToken": "ref-2", "expiresAt": "2026-09-30T01:00:00Z",
                                "userId": "usr-1", "email": "me@example.com"])
        let requests = http.allRequests
        #expect(body(requests[0]).contains("client_id=\(ClineAuth.workOSClientID)"))
        #expect(body(requests[1]).contains("device_code=dev"))
        let register = try #require(requests.last)
        #expect(register.httpMethod == "POST")
        let sent = try JSONSerialization.jsonObject(with: register.httpBody ?? Data()) as? [String: String]
        #expect(sent == ["accessToken": "wos-acc", "refreshToken": "wos-ref"])
    }

    @Test func deniedSignInStops() async throws {
        let http = ScriptedHTTP { _ in (400, #"{"error":"access_denied","error_description":"User denied"}"#) }
        let authorization = ClineAuth.DeviceAuthorization(deviceCode: "dev", userCode: "X", verificationURL: URL(string: "https://x")!,
                                                          expiresIn: 300, interval: 5)
        await #expect(throws: ClineAuth.AuthError.denied("User denied")) {
            _ = try await ClineAuth(http: http).completeSignIn(authorization, now: { now }, sleep: { _ in })
        }
    }

    @Test func validTokenIsKeptWithoutRequest() async throws {
        let http = ScriptedHTTP { _ in (500, "") }
        let stored = ["accessToken": "acc", "refreshToken": "ref", "expiresAt": "2026-09-30T00:30:00Z"]
        #expect(try await ClineAuth(http: http).refreshedCredentials(stored, now: now) == nil)
        #expect(http.allRequests.isEmpty)
    }

    @Test func expiringTokenIsRefreshedAndKeepsOtherFields() async throws {
        let http = ScriptedHTTP { request in request.url!.path() == "/api/v1/auth/refresh" ? (200, session) : (404, "") }
        let stored = ["accessToken": "acc", "refreshToken": "ref", "expiresAt": "2026-09-30T00:04:00Z", "userId": "usr-1"]
        let renewed = try #require(try await ClineAuth(http: http).refreshedCredentials(stored, now: now))
        #expect(renewed["accessToken"] == "acc-2")
        #expect(renewed["refreshToken"] == "ref-2")
        #expect(renewed["userId"] == "usr-1")
        let sent = try JSONSerialization.jsonObject(with: http.allRequests[0].httpBody ?? Data()) as? [String: String]
        #expect(sent == ["refreshToken": "ref", "grantType": "refresh_token"])
    }

    @Test func rejectedRefreshAsksToSignInAgain() async throws {
        let http = ScriptedHTTP { _ in (401, #"{"error":"invalid_grant"}"#) }
        await #expect(throws: ClineAuth.AuthError.signInRequired) {
            _ = try await ClineAuth(http: http).refreshedCredentials(["refreshToken": "old"], now: now)
        }
        await #expect(throws: ClineAuth.AuthError.signInRequired) {
            _ = try await ClineAuth(http: http).refreshedCredentials([:], now: now)
        }
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimeInterval] = []
    func add(_ value: TimeInterval) { lock.withLock { stored.append(value) } }
    var values: [TimeInterval] { lock.withLock { stored } }
}

@Suite struct ClineConnectorTests {
    /// Personal account: two usage pages (newest first), the second reaching before `from`; Pass and credit payments.
    private func personalHTTP(organizations: String = "[]", override: [String: (Int, String)] = [:]) -> ScriptedHTTP {
        ScriptedHTTP { request in
            let url = request.url!
            let query = url.query(percentEncoded: false) ?? ""
            if let response = override[url.path()] { return response }
            switch url.path() {
            case "/api/v1/users/me":
                return (200, #"{"success":true,"data":{"id":"usr-1","organizations":\#(organizations)}}"#)
            case "/api/v1/users/usr-1/usages" where query.contains("cursor=usg-2"):
                return (200, #"""
                {"success":true,"data":{"items":[
                 {"createdAt":"2026-08-31T23:00:00.5Z","creditsUsed":500000,"aiModelName":"claude-sonnet-5","promptTokens":10,"completionTokens":1},
                 {"createdAt":"2026-07-31T10:00:00Z","creditsUsed":9000000,"aiModelName":"claude-sonnet-5"}],"nextToken":"usg-3","total":0}}
                """#)
            case "/api/v1/users/usr-1/usages":
                return (200, #"""
                {"success":true,"data":{"items":[
                 {"createdAt":"2026-09-29T20:00:00.000000Z","creditsUsed":40000,"costUsd":4000000,"aiModelName":"claude-sonnet-5","promptTokens":33000,"completionTokens":2700,"cachedTokens":30800,"metadata":{"is_byok":true}},
                 {"createdAt":"2026-09-29T08:00:00Z","creditsUsed":"1000000","aiModelName":null,"operation":"web_search"},
                 {"createdAt":"2026-09-02T08:00:00Z","creditsUsed":2500000,"aiModelName":"gpt-5.4","promptTokens":100,"completionTokens":50}],
                 "nextToken":"usg-2","total":0}}
                """#)
            case "/api/v1/users/usr-1/payments":
                return (200, #"""
                {"success":true,"data":{"items":[
                 {"id":"p1","amount":1000,"type":"plan","status":"completed","createdAt":"2026-09-30T17:00:00Z","completedAt":"2026-09-30T17:00:00Z"},
                 {"id":"p2","amount":5250,"credits":50000000,"type":"credits","status":"completed","createdAt":"2026-09-25T11:00:00Z","completedAt":"2026-09-25T11:00:08Z"},
                 {"id":"p3","amount":5200,"credits":50000000,"type":"credits","status":"pending","createdAt":"2026-09-26T11:00:00Z"},
                 {"id":"p4","amount":1000,"type":"plan","status":"completed","createdAt":"2026-07-30T17:00:00Z"}],"nextToken":"","total":0}}
                """#)
            case "/api/v1/users/usr-1/balance":
                return (200, #"{"success":true,"data":{"userId":"usr-1","balance":37000000}}"#)
            case "/api/v1/organizations/org-1/members/mem-1/usages":
                return (200, #"{"success":true,"data":{"items":[{"createdAt":"2026-09-10T08:00:00Z","creditsUsed":3000000,"aiModelName":"gpt-5.4"}],"nextToken":""}}"#)
            case "/api/v1/organizations/org-2/members/mem-2/usages":
                return (403, #"{"error":"forbidden"}"#)
            default:
                return (404, "")
            }
        }
    }

    private let request = FetchRequest(credentials: ["accessToken": "acc", "refreshToken": "ref"],
                                       from: Day(year: 2026, month: 8, day: 1), now: now)

    @Test func mapsUsagePassPurchasesAndBalance() async throws {
        let http = personalHTTP()
        let snapshot = try await ClineConnector(http: http).fetch(request)

        #expect(snapshot.coveredFrom == Day(year: 2026, month: 8, day: 1))
        // Credits used are millionths of a dollar; the July item before `from` is ignored; Pass counts on its payment day.
        #expect(snapshot.dailyCosts == [Day(year: 2026, month: 9, day: 29): Decimal(string: "1.04")!,
                                        Day(year: 2026, month: 9, day: 2): 2.5,
                                        Day(year: 2026, month: 8, day: 31): 0.5,
                                        Day(year: 2026, month: 9, day: 30): Decimal(10)])
        let september = snapshot.breakdown?.filter { $0.month == Month(year: 2026, month: 9) } ?? []
        #expect(september.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .lineItem, label: "Cline Pass", amount: Decimal(10))))
        #expect(september.contains(BreakdownRow(month: Month(year: 2026, month: 9), dimension: .lineItem, label: "web_search", amount: 1)))
        #expect(!september.contains { $0.dimension == .account })  // no organizations: no account split

        let sonnet = try #require(snapshot.tokenUsage?.first { $0.model == "claude-sonnet-5" })
        #expect(sonnet.inputTokens == 33000 && sonnet.cachedInputTokens == 30800 && sonnet.outputTokens == 2700 && sonnet.requests == 1)

        // Only completed credit top-ups are imported; amounts in cents; Pass payments are not purchases.
        #expect(snapshot.creditPurchases == [ProviderCreditPurchase(externalID: "p2", day: Day(year: 2026, month: 9, day: 25),
                                                                    amount: Decimal(string: "52.50")!, volume: "$50.00 in credits")])
        #expect(snapshot.providerBalance == Decimal(37))

        // Paging uses `cursor` and stops once a page reaches days before `from`.
        let usagePages = http.allRequests.filter { $0.url!.path() == "/api/v1/users/usr-1/usages" }
        #expect(usagePages.count == 2)
        #expect(usagePages[1].url!.query()?.contains("cursor=usg-2") == true)
        // The account API wants the WorkOS token with its prefix.
        #expect(http.allRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer workos:acc" })
    }

    @Test func organizationUsageIsAddedAndFailuresBecomeNotes() async throws {
        let organizations = #"[{"organizationId":"org-1","memberId":"mem-1","name":"Acme","roles":["member"],"active":true},{"organizationId":"org-2","memberId":"mem-2","name":"Beta","roles":["member"],"active":false}]"#
        let snapshot = try await ClineConnector(http: personalHTTP(organizations: organizations)).fetch(request)
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 10)] == 3)
        let accounts = snapshot.breakdown?.filter { $0.dimension == .account && $0.month == Month(year: 2026, month: 9) } ?? []
        #expect(accounts.contains { $0.label == "Acme" && $0.amount == 3 })
        #expect(accounts.contains { $0.label == "Personal" })
        #expect(snapshot.notes.map(\.id) == ["cline.org.org-2"])
    }

    @Test func organizationOutageFailsTheRefreshInsteadOfDroppingItsSpend() async throws {
        let organizations = #"[{"organizationId":"org-1","memberId":"mem-1","name":"Acme"}]"#
        let http = personalHTTP(organizations: organizations,
                                override: ["/api/v1/organizations/org-1/members/mem-1/usages": (502, "bad gateway")])
        await #expect(throws: ConnectorError.self) { _ = try await ClineConnector(http: http).fetch(request) }
    }

    @Test func unreadableBalanceIsUnavailableNotStale() async throws {
        let http = personalHTTP(override: ["/api/v1/users/usr-1/balance": (500, "oops")])
        let snapshot = try await ClineConnector(http: http).fetch(request)
        #expect(snapshot.providerBalance == nil)
        #expect(snapshot.providerBalanceUnavailable)
        #expect(snapshot.notes.map(\.id) == ["cline.balance"])
        #expect(!snapshot.dailyCosts.isEmpty)
    }

    @Test func unreadableDateOrAmountFailsInsteadOfCountingZero() async throws {
        let badDate = personalHTTP(override: ["/api/v1/users/usr-1/usages": (200, #"{"data":{"items":[{"createdAt":"yesterday","creditsUsed":1}],"nextToken":""}}"#)])
        await #expect(throws: ConnectorError.self) { _ = try await ClineConnector(http: badDate).fetch(request) }
        let noAmount = personalHTTP(override: ["/api/v1/users/usr-1/payments": (200, #"{"data":{"items":[{"id":"p","type":"plan","status":"completed","createdAt":"2026-09-30T00:00:00Z"}],"nextToken":""}}"#)])
        await #expect(throws: ConnectorError.self) { _ = try await ClineConnector(http: noAmount).fetch(request) }
    }

    @Test func missingSessionAsksToSignIn() async throws {
        let http = ScriptedHTTP { _ in (500, "") }
        await #expect(throws: ClineAuth.AuthError.signInRequired) {
            _ = try await ClineConnector(http: http).fetch(FetchRequest(credentials: [:], from: Day(year: 2026, month: 9, day: 1), now: now))
        }
    }

    @Test func nameMatchesConnector() {
        #expect(ConnectorID.match(serviceName: "Cline") == .cline)
        #expect(ConnectorID.match(serviceName: "cline.bot") == .cline)
    }
}

@Suite(.serialized) @MainActor struct ClineRefreshTests {
    private func makeStore() throws -> SpendStore {
        SpendStore(container: try Persistence.makeContainer(inMemory: true),
                   keychain: KeychainStore(serviceName: "app.itspendtracker.ITSpendTracker.tests.\(UUID().uuidString)"))
    }

    @Test func renewedSessionIsSavedEvenWhenTheFetchFails() async throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "Cline", accountIdentifier: "", connector: .cline, definition: nil,
                                                    credentials: ["accessToken": "old", "refreshToken": "ref", "expiresAt": "2026-09-29T00:00:00Z"])
        let http = ScriptedHTTP { request in request.url!.path() == "/api/v1/auth/refresh" ? (200, session) : (500, "down") }
        let engine = RefreshEngine(store: store, http: http, clock: { now })
        await engine.refresh(serviceID: service.id)

        #expect(try store.credentials(for: service)["accessToken"] == "acc-2")
        #expect(try store.credentials(for: service)["refreshToken"] == "ref-2")
        #expect(service.lastRefreshError != nil)
        try store.remove(service)
    }

    @Test func serviceDeletedDuringRenewalDoesNotGetItsKeychainItemBack() async throws {
        let keychain = KeychainStore(serviceName: "app.itspendtracker.ITSpendTracker.tests.\(UUID().uuidString)")
        let store = SpendStore(container: try Persistence.makeContainer(inMemory: true), keychain: keychain)
        let service = try store.addConnectedService(name: "Cline", accountIdentifier: "", connector: .cline, definition: nil,
                                                    credentials: ["accessToken": "old", "refreshToken": "ref"])
        let id = service.id
        let box = UncheckedBox(store)
        let http = ScriptedHTTP { request in
            if request.url!.path() == "/api/v1/auth/refresh" {
                // The user deletes the service while the renewal is in flight.
                DispatchQueue.main.sync { MainActor.assumeIsolated { try? box.value.remove(box.value.service(id: id)!) } }
                return (200, session)
            }
            return (500, "")
        }
        await RefreshEngine(store: store, http: http, clock: { now }).refresh(serviceID: id)
        #expect(store.service(id: id) == nil)
        #expect(try keychain.load(for: id) == nil)
    }

    @Test func unavailableBalanceClearsTheStoredOne() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "Cline", accountIdentifier: "", connector: .cline, definition: nil,
                                                    credentials: ["refreshToken": "ref"])
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1), keys: nil, tokenUsage: nil,
                                          providerBalance: 50), to: service, at: now)
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1), keys: nil, tokenUsage: nil,
                                          providerBalanceUnavailable: true), to: service, at: now)
        #expect(service.balanceSnapshotAmount == nil)
        #expect(service.ledger.remainingBalance(today: Day(year: 2026, month: 9, day: 30)) == .noData)
        try store.remove(service)
    }

    @Test func importedPurchasesAreReplacedAndManualOnesKept() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "Cline", accountIdentifier: "", connector: .cline, definition: nil,
                                                    credentials: ["refreshToken": "ref"])
        try store.addCreditPurchase(service, day: Day(year: 2026, month: 1, day: 5), amount: 20, volume: "manual")
        let purchase = ProviderCreditPurchase(externalID: "p2", day: Day(year: 2026, month: 9, day: 25), amount: Decimal(string: "52.50")!, volume: "")
        for _ in 0..<2 {
            try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1), keys: nil, tokenUsage: nil,
                                              providerBalance: Decimal(string: "37.00"), creditPurchases: [purchase]),
                            to: service, at: now)
        }
        #expect(service.creditPurchases.count == 2)
        #expect(service.creditPurchases.filter { $0.externalID == "p2" }.count == 1)
        #expect(service.balanceSnapshotAmount == Decimal(string: "37.00"))
        #expect(service.ledger.remainingBalance(today: Day(year: 2026, month: 9, day: 30)) == .estimate(Decimal(string: "37.00")!))
        try store.remove(service)
    }
}

private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
