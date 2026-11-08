import AppKit
import Foundation
import Observation

/// Refreshes API-connected services (REQ-009, DEC-009). Each service is fetched independently;
/// a failure keeps that service's last known data and marks it with an error.
@MainActor
@Observable
final class RefreshEngine {
    private let store: SpendStore
    private let http: HTTPClient
    private let clock: @Sendable () -> Date
    private(set) var refreshing: Set<UUID> = []
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    var isRefreshing: Bool { !refreshing.isEmpty }

    init(store: SpendStore, http: HTTPClient = URLSessionHTTPClient(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.http = http
        self.clock = clock
    }

    /// Starts the 4-hour timer and wake observer, and refreshes stale services now (launch trigger).
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: RefreshPolicy.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll(onlyStale: false) }
        }
        timer?.tolerance = 60
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll(onlyStale: true) }
        }
        Task { await refreshAll(onlyStale: true) }
    }

    func refreshAll(onlyStale: Bool) async {
        let now = clock()
        let targets = store.services.filter { service in
            service.isConnected && !refreshing.contains(service.id)
                && (!onlyStale || RefreshPolicy.isStale(lastSuccess: service.lastSuccessfulRefresh, now: now))
        }
        await withTaskGroup(of: Void.self) { group in
            for service in targets {
                let id = service.id
                group.addTask { await self.refresh(serviceID: id) }
            }
        }
    }

    func refresh(serviceID: UUID) async {
        guard let service = store.service(id: serviceID), service.isConnected, !refreshing.contains(serviceID) else { return }
        refreshing.insert(serviceID)
        defer { refreshing.remove(serviceID) }

        let now = clock()
        store.recordRefreshAttempt(service, at: now)
        // Read before any await: the service may be deleted while a request is in flight.
        let connector = service.connector, definition = service.definition
        let from = RefreshPolicy.fetchStart(hasHistory: !service.needsFullBackfill, today: Day(now, calendar: .utc))
        do {
            var credentials = try store.credentials(for: service)
            if let renewed = try await Self.renewSession(service: connector, credentials: credentials, now: now, http: http) {
                // A service deleted meanwhile must not get its Keychain item back (DEC-013).
                guard let current = store.service(id: serviceID) else { return }
                // Saved before the fetch: the old refresh token may no longer be valid (DEC-040).
                try store.replaceSessionCredentials(current, renewed)
                credentials = renewed
            }
            let request = FetchRequest(credentials: credentials, from: from, now: now)
            let snapshot: ConnectorSnapshot
            do {
                snapshot = try await Self.fetch(service: connector, definition: definition, request: request, http: http)
            } catch ConnectorError.unauthorized {
                // The access token was revoked before its stated expiry: renew it on the next refresh.
                if let session = connector?.makeConnector(http: http) as? any SessionConnector,
                   let current = store.service(id: serviceID) {
                    try store.replaceSessionCredentials(current, session.markedExpired(credentials))
                }
                throw ConnectorError.unauthorized
            }
            guard let current = store.service(id: serviceID) else { return } // removed meanwhile
            try store.apply(snapshot, to: current, at: now)
        } catch {
            if let current = store.service(id: serviceID) {
                store.recordRefreshFailure(current, message: error.localizedDescription)
            }
        }
    }

    private nonisolated static func renewSession(service connector: ConnectorID?, credentials: [String: String], now: Date,
                                                 http: HTTPClient) async throws -> [String: String]? {
        guard let session = connector?.makeConnector(http: http) as? any SessionConnector else { return nil }
        return try await session.refreshedCredentials(credentials, now: now)
    }

    /// Fetches once without storing, used to test credentials before a service is saved.
    func test(connector: ConnectorID?, definition: ConnectorDefinition?, credentials: [String: String]) async throws {
        let now = clock()
        let request = FetchRequest(credentials: credentials, from: Day(now, calendar: .utc).calendarMonth.firstDay, now: now)
        _ = try await Self.fetch(service: connector, definition: definition, request: request, http: http)
    }

    private nonisolated static func fetch(service connector: ConnectorID?, definition: ConnectorDefinition?,
                                          request: FetchRequest, http: HTTPClient) async throws -> ConnectorSnapshot {
        if let connector {
            return try await connector.makeConnector(http: http).fetch(request)
        }
        if let definition {
            return try await DeclarativeConnector(definition: definition, http: http).fetch(request)
        }
        throw ConnectorError.invalidConfiguration("service has no connector")
    }
}
