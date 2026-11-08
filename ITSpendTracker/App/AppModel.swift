import Foundation
import Observation
import SwiftData

/// Composition root shared by all views.
@MainActor
@Observable
final class AppModel {
    let store: SpendStore
    let refresh: RefreshEngine
    /// Spending chat session (DEC-038); in memory only.
    let chat = SpendingChat()
    private(set) var startupError: String?

    var assistantBackend: AssistantBackend {
        didSet { UserDefaults.standard.set(assistantBackend.rawValue, forKey: Self.backendKey) }
    }

    private static let backendKey = "assistantBackend"

    init() {
        // Unit tests are hosted by the app; they must not touch the user's store or start refreshes.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTestHost { LegacyMigration.fromBundle()?.migratePreferences() }  // before any preference is read
        #if DEBUG
        let isDemo = UserDefaults.standard.bool(forKey: "DemoData")
        #else
        let isDemo = false
        #endif
        let container: ModelContainer
        var startupError: String?
        do {
            container = try Persistence.makeContainer(inMemory: isTestHost || isDemo)
        } catch {
            startupError = error.localizedDescription
            container = try! Persistence.makeContainer(inMemory: true)
        }
        self.startupError = startupError
        store = SpendStore(container: container)
        refresh = RefreshEngine(store: store)
        if !isTestHost && !isDemo { LegacyMigration.runIfNeeded(store: store) }
        assistantBackend = UserDefaults.standard.string(forKey: Self.backendKey)
            .flatMap(AssistantBackend.init(rawValue:)) ?? .claude
        #if DEBUG
        if isDemo { DemoData.seed(store) }
        #endif
        if !isTestHost && !isDemo {
            if let path = UserDefaults.standard.string(forKey: "ImportConnectionFile") {
                do {
                    _ = try ConnectionImport.run(path: path, store: store)
                } catch {
                    self.startupError = error.localizedDescription
                }
            }
            refresh.start()
        }
    }

    var today: Day { Day(Date()) }

    func summary(for service: TrackedService, now: Date = Date()) -> ServiceSummary {
        ServiceSummary(service: service, now: now)
    }

    var summaries: [ServiceSummary] {
        let now = Date()
        return store.services.map { ServiceSummary(service: $0, now: now) }
    }

    /// Total of the services the user included (REQ-002).
    func total(in month: Month) -> Amount {
        store.services.filter(\.includedInTotal)
            .map { $0.ledger.spend(in: month) }
            .reduce(Amount.noData, +)
    }

    /// The last 12 months of every tag, each month calculated from that month's data (REQ-023, REQ-024, DEC-042).
    /// Kept until the store saves again or the month changes: a page reads it on every redraw.
    var tagHistory: [TagHistory] {
        let month = today.calendarMonth
        let revision = store.revision // reading it also makes the views redraw after a save
        if let cached = historyCache, cached.revision == revision, cached.month == month { return cached.value }
        let services = store.services
        // A service's ledger reads all its daily costs, so it is built once and not for every month.
        let ledgers = Dictionary(services.filter { !$0.tagAssignments.isEmpty }.map { ($0.id, $0.ledger) },
                                 uniquingKeysWith: { first, _ in first })
        let value = TagHistory.compute(months: TagHistory.months(endingAt: month)) { month in
            services.map { $0.tagInput(in: month, ledger: ledgers[$0.id]) }
        }
        historyCache = RevisionCache(revision: revision, month: month, value: value)
        return value
    }

    @ObservationIgnored private var historyCache: RevisionCache<[TagHistory]>?
    @ObservationIgnored private var totalsCache: RevisionCache<[TagTotal]>?

    /// The part of the next opened service page to scroll to, set by the Tags view (REQ-019).
    var pendingServiceSection: ServiceSection?

    /// Current-month spend per tag across all services, for every kind of tagged target (REQ-019, REQ-020).
    var tagTotals: [TagTotal] {
        let month = today.calendarMonth
        let revision = store.revision
        if let cached = totalsCache, cached.revision == revision, cached.month == month { return cached.value }
        let value = TagTotal.compute(store.services.map { $0.tagInput(in: month) })
        totalsCache = RevisionCache(revision: revision, month: month, value: value)
        return value
    }

    /// Whether the total of `month` contains an approximate amount (DEC-033).
    func totalIsApproximate(in month: Month) -> Bool {
        store.services.contains { $0.includedInTotal && $0.isApproximate(in: month) }
    }

    var hasWarnings: Bool { summaries.contains(where: \.hasWarning) }
}

/// Derived, display-ready facts about one service.
struct ServiceSummary: Identifiable {
    let id: UUID
    let name: String
    let currentMonthSpend: Amount
    let isApproximate: Bool
    let expiringKeys: [String]
    let increase: WarningRules.Increase?
    let refreshError: String?
    let lastSuccessfulRefresh: Date?
    let isConnected: Bool
    let includedInTotal: Bool

    init(service: TrackedService, now: Date) {
        let today = Day(now)
        let ledger = service.ledger
        id = service.id
        name = service.name
        currentMonthSpend = ledger.spend(in: today.calendarMonth)
        isApproximate = service.isApproximate(in: today.calendarMonth)
        expiringKeys = service.keys.filter { WarningRules.isExpiringSoon(expiresAt: $0.expiresAt, now: now) }.map(\.name)
        increase = WarningRules.spendIncrease(ledger: ledger, today: today)
        refreshError = service.lastRefreshError
        lastSuccessfulRefresh = service.lastSuccessfulRefresh
        isConnected = service.isConnected
        includedInTotal = service.includedInTotal
    }

    var hasWarning: Bool { !expiringKeys.isEmpty || increase != nil }
}

/// A part of the service page that other pages can open directly.
enum ServiceSection: Hashable {
    case breakdown
    case usage
}

/// A value worked out from the store's data, valid while the store has not saved again and the month is the same.
struct RevisionCache<Value> {
    var revision: Int
    var month: Month
    var value: Value
}
