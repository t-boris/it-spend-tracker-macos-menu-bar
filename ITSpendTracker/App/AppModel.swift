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

    var tagTotals: [TagTotal] {
        let keys = store.services.filter(\.isConnected).flatMap { service in
            let availability = KeyFieldAvailability(service: service)
            return service.keys.map { key in
                TagTotal.TaggedKey(serviceID: service.id, keyExternalID: key.externalID,
                                   serviceName: service.name, keyName: key.name,
                                   cost: availability.spend ? key.currentMonthCost : nil,
                                   costIsEstimate: availability.spendIsEstimate,
                                   tags: service.tags(forKey: key.externalID))
            }
        }
        return TagTotal.compute(keys)
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
