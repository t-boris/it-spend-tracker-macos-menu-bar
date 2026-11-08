import Foundation
import Observation
import SwiftData

/// Reads and writes services and their data. All mutations go through here.
@MainActor
@Observable
final class SpendStore {
    let context: ModelContext
    let keychain: KeychainStore
    /// Bumped on every change so views recompute derived values.
    private(set) var revision = 0

    init(container: ModelContainer, keychain: KeychainStore = KeychainStore()) {
        context = ModelContext(container)
        context.autosaveEnabled = false
        self.keychain = keychain
        // Tags saved by the first release are moved to the generalized records before anything reads them (DEC-036).
        try? migrateLegacyKeyTags()
    }

    var services: [TrackedService] {
        _ = revision
        let descriptor = FetchDescriptor<TrackedService>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func service(id: UUID) -> TrackedService? {
        services.first { $0.id == id }
    }

    // MARK: Creating services

    /// Adds an API-connected service. Credentials go to the Keychain only (REQ-006).
    @discardableResult
    func addConnectedService(name: String, accountIdentifier: String, connector: ConnectorID?,
                             definition: ConnectorDefinition?,
                             credentials: [String: String]) throws -> TrackedService {
        let service = TrackedService(name: name, accountIdentifier: accountIdentifier, connector: connector,
                                     definition: definition)
        try keychain.save(credentials, for: service.id)
        context.insert(service)
        try save()
        return service
    }

    @discardableResult
    func addManualService(name: String, note: String = "", consoleLink: String? = nil) throws -> TrackedService {
        let service = TrackedService(name: name, note: note)
        service.consoleLink = try Self.validatedConsoleLink(consoleLink)
        context.insert(service)
        try save()
        return service
    }

    enum ConsoleLinkError: LocalizedError {
        case notHTTPS

        var errorDescription: String? {
            String(localized: "The console link must be an https address, e.g. https://fly.io/dashboard.")
        }
    }

    /// `nil` for an empty value; an error for anything that is not an https URL (DEC-041).
    static func validatedConsoleLink(_ text: String?) throws -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard let url = TrackedService.httpsURL(trimmed) else { throw ConsoleLinkError.notHTTPS }
        return url.absoluteString
    }

    // MARK: Subscriptions (DEC-014, DEC-026)

    @discardableResult
    func addSubscription(_ service: TrackedService, name: String, period: SubscriptionPlan.Period, start: Day, end: Day?,
                         amount: Decimal) throws -> SubscriptionRecord {
        let record = SubscriptionRecord(name: name, period: period, start: start, end: end)
        record.prices = [SubscriptionPriceRecord(effectiveFrom: start, amount: amount)]
        service.subscriptionRecords.append(record)
        try save()
        return record
    }

    func updateSubscription(_ record: SubscriptionRecord, name: String, period: SubscriptionPlan.Period, start: Day, end: Day?) throws {
        record.name = name
        record.periodRaw = period.rawValue
        // The first price follows the start date so charges before it keep a price.
        if let first = record.sortedPrices.first, first.effectiveFromKey == record.startKey || first.effectiveFromKey > start.key {
            first.effectiveFromKey = start.key
        }
        record.startKey = start.key
        record.endKey = end?.key
        try save()
    }

    /// A price change applies from `effectiveFrom`; earlier charges keep the old amount.
    func changePrice(_ record: SubscriptionRecord, amount: Decimal, effectiveFrom: Day) throws {
        if let existing = record.prices.first(where: { $0.effectiveFromKey == effectiveFrom.key }) {
            existing.amount = amount
        } else {
            record.prices.append(SubscriptionPriceRecord(effectiveFrom: effectiveFrom, amount: amount))
        }
        try save()
    }

    func deletePrice(_ price: SubscriptionPriceRecord, from record: SubscriptionRecord) throws {
        guard record.prices.count > 1 else { return }
        record.prices.removeAll { $0 === price }
        context.delete(price)
        try save()
    }

    func deleteSubscription(_ record: SubscriptionRecord, from service: TrackedService) throws {
        service.subscriptionRecords.removeAll { $0 === record }
        context.delete(record)
        try save()
    }

    // MARK: Credits (DEC-008, DEC-021)

    func addCreditPurchase(_ service: TrackedService, day: Day, amount: Decimal, volume: String) throws {
        service.creditPurchases.append(CreditPurchaseRecord(day: day, amount: amount, volume: volume))
        try save()
    }

    func updateCreditPurchase(_ purchase: CreditPurchaseRecord, day: Day, amount: Decimal, volume: String) throws {
        purchase.dayKey = day.key
        purchase.amount = amount
        purchase.volume = volume
        try save()
    }

    func deleteCreditPurchase(_ purchase: CreditPurchaseRecord, from service: TrackedService) throws {
        service.creditPurchases.removeAll { $0 === purchase }
        context.delete(purchase)
        try save()
    }

    func setBalanceSnapshot(_ service: TrackedService, amount: Decimal?, day: Day?) throws {
        service.balanceSnapshotAmount = amount
        service.balanceSnapshotDayKey = amount == nil ? nil : day?.key
        try save()
    }

    // MARK: Settings per service

    func setIncludedInTotal(_ service: TrackedService, _ included: Bool) throws {
        service.includedInTotal = included
        try save()
    }

    /// Replaces the tags of one target (REQ-017). Tags are trimmed, de-duplicated case-insensitively and kept in entry
    /// order; an empty list removes the assignment. `displayName` is kept for showing the target once it is missing (DEC-037).
    func setTags(_ tags: [String], for target: TagTarget, displayName: String, of service: TrackedService) throws {
        let cleaned = tags.cleanedTags()
        if let record = service.tagAssignments.first(where: { $0.target == target }) {
            if cleaned.isEmpty {
                service.tagAssignments.removeAll { $0 === record }
                context.delete(record)
            } else {
                record.tags = cleaned
                record.displayName = displayName
            }
        } else if !cleaned.isEmpty {
            service.tagAssignments.append(TagAssignmentRecord(target: target, displayName: displayName, tags: cleaned))
        }
        try save()
    }

    /// Replaces the tags of one key (DEC-024).
    func setTags(_ tags: [String], forKey externalID: String, of service: TrackedService) throws {
        let name = service.keys.first { $0.externalID == externalID }?.name ?? externalID
        try setTags(tags, for: .key(externalID), displayName: name, of: service)
    }

    /// All tags in use across every target type, for suggestions; spellings that differ only in case appear once.
    var allTags: [String] {
        var seen = Set<String>()
        return services.flatMap { $0.tagAssignments.flatMap(\.tags) }
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Converts the first release's per-key tag records into assignments of kind key and removes them (DEC-036).
    /// Nothing is lost: tags already assigned to the same key are merged. Safe to run repeatedly.
    func migrateLegacyKeyTags() throws {
        var changed = false
        for service in services {
            for legacy in Array(service.keyTags) {
                let target = TagTarget.key(legacy.keyExternalID)
                let name = service.keys.first { $0.externalID == legacy.keyExternalID }?.name ?? legacy.keyExternalID
                if let existing = service.tagAssignments.first(where: { $0.target == target }) {
                    existing.tags = (existing.tags + legacy.tags).cleanedTags()
                } else if !legacy.tags.cleanedTags().isEmpty {
                    service.tagAssignments.append(TagAssignmentRecord(target: target, displayName: name,
                                                                      tags: legacy.tags.cleanedTags()))
                }
                service.keyTags.removeAll { $0 === legacy }
                context.delete(legacy)
                changed = true
            }
        }
        if changed { try save() }
    }

    func setNoteHidden(_ id: String, hidden: Bool, in service: TrackedService) throws {
        var ids = service.hiddenNoteIDs
        if hidden { ids.insert(id) } else { ids.remove(id) }
        service.hiddenNoteIDsJSON = ids.isEmpty ? nil : try JSONEncoder().encode(ids)
        try save()
    }

    func rename(_ service: TrackedService, to name: String) throws {
        service.name = name
        try save()
    }

    func credentials(for service: TrackedService) throws -> [String: String] {
        try keychain.load(for: service.id) ?? [:]
    }

    /// New credentials may see more (e.g. more organizations), so the next refresh reloads the full history.
    func updateCredentials(_ service: TrackedService, _ credentials: [String: String]) throws {
        try keychain.save(credentials, for: service.id)
        service.breakdownBackfilled = false
        service.keyCostsStartMonthIndex = nil
        service.coverageStartKey = nil
        try save()
    }

    /// Saves a renewed sign-in session (DEC-040). Unlike `updateCredentials`, the stored history stays as it is.
    func replaceSessionCredentials(_ service: TrackedService, _ credentials: [String: String]) throws {
        try keychain.save(credentials, for: service.id)
    }

    // MARK: Removal (DEC-013)

    /// Deletes the Keychain item and, through cascade rules, all stored data of the service.
    func remove(_ service: TrackedService) throws {
        try keychain.delete(for: service.id)
        context.delete(service)
        try save()
    }

    // MARK: Refresh results

    func recordRefreshAttempt(_ service: TrackedService, at date: Date) {
        service.lastRefreshAttempt = date
        try? save()
    }

    /// Keeps the last known data and marks the error (REQ-009).
    func recordRefreshFailure(_ service: TrackedService, message: String) {
        service.lastRefreshError = message
        try? save()
    }

    func apply(_ snapshot: ConnectorSnapshot, to service: TrackedService, at date: Date) throws {
        service.spendUnavailableReason = snapshot.spendUnavailableReason
        service.providerNotesJSON = snapshot.notes.isEmpty ? nil : try? JSONEncoder().encode(snapshot.notes)
        if let rows = snapshot.usageMetrics, let fromMonth = snapshot.usageMetricsFrom {
            for record in service.usageMetrics where record.monthIndex >= fromMonth.index {
                context.delete(record)
            }
            service.usageMetrics.removeAll { $0.monthIndex >= fromMonth.index }
            service.usageMetrics += rows.filter { $0.month >= fromMonth && $0.value != 0 }.map(UsageMetricRecord.init)
            service.usageMetricsStartMonthIndex = min(service.usageMetricsStartMonthIndex ?? fromMonth.index, fromMonth.index)
        }
        if snapshot.spendUnavailableReason != nil {
            // Spend cannot be verified: stored provider spend (e.g. an earlier assumed zero) is dropped so it
            // shows as "no data"; subscriptions and credit purchases are kept.
            service.dailyCosts.forEach(context.delete)
            service.dailyCosts = []
            service.breakdown.forEach(context.delete)
            service.breakdown = []
            service.coverageStartKey = nil
            service.breakdownStartMonthIndex = nil
            if let keys = snapshot.keys {
                service.keys.forEach(context.delete)
                service.keys = keys.map { KeyRecord($0, fetchedIn: Day(date).calendarMonth) }
                service.hasKeyData = true
            }
            service.lastSuccessfulRefresh = date
            service.lastRefreshError = nil
            try save()
            return
        }
        let fromKey = snapshot.coveredFrom.key
        for cost in service.dailyCosts where cost.dayKey >= fromKey {
            context.delete(cost)
        }
        service.dailyCosts.removeAll { $0.dayKey >= fromKey }
        for (day, amount) in snapshot.dailyCosts where day.key >= fromKey && amount != 0 {
            service.dailyCosts.append(DailyCost(dayKey: day.key, amount: amount))
        }
        service.coverageStartKey = min(service.coverageStartKey ?? fromKey, fromKey)

        if let keys = snapshot.keys {
            service.keys.forEach(context.delete)
            service.keys = keys.map { KeyRecord($0, fetchedIn: Day(date).calendarMonth) }
            service.hasKeyData = true
        }
        if let rows = snapshot.breakdown, let fromMonth = snapshot.breakdownFrom {
            for record in service.breakdown where record.monthIndex >= fromMonth.index {
                context.delete(record)
            }
            service.breakdown.removeAll { $0.monthIndex >= fromMonth.index }
            service.breakdown += rows.merged().filter { $0.month >= fromMonth && $0.amount != 0 }.map(BreakdownRecord.init)
            service.breakdownStartMonthIndex = min(service.breakdownStartMonthIndex ?? fromMonth.index, fromMonth.index)
        }
        if let costs = snapshot.keyMonthlyCosts, let fromMonth = snapshot.keyCostsFrom {
            for record in service.keyCosts where record.monthIndex >= fromMonth.index {
                context.delete(record)
            }
            service.keyCosts.removeAll { $0.monthIndex >= fromMonth.index }
            service.keyCosts += costs.filter { $0.month >= fromMonth && $0.amount != 0 }.map(KeyCostRecord.init)
            service.keyCostsStartMonthIndex = min(service.keyCostsStartMonthIndex ?? fromMonth.index, fromMonth.index)
        }
        // A fetch starting at the earliest stored day was a full backfill, breakdown included.
        if fromKey == service.coverageStartKey {
            service.breakdownBackfilled = true
        }
        if let purchases = snapshot.creditPurchases {
            let imported = service.creditPurchases.filter { $0.externalID != nil }
            imported.forEach(context.delete)
            service.creditPurchases.removeAll { $0.externalID != nil }
            service.creditPurchases += purchases.map {
                CreditPurchaseRecord(day: $0.day, amount: $0.amount, volume: $0.volume, externalID: $0.externalID)
            }
        }
        if let balance = snapshot.providerBalance {
            service.balanceSnapshotAmount = balance
            service.balanceSnapshotDayKey = Day(date, calendar: .utc).key
        } else if snapshot.providerBalanceUnavailable {
            service.balanceSnapshotAmount = nil
            service.balanceSnapshotDayKey = nil
        }
        if let rows = snapshot.tokenUsage {
            service.tokenUsage.forEach(context.delete)
            service.tokenUsage = rows.map(TokenUsageRecord.init)
            service.hasTokenData = true
            service.tokenUsageMonthIndex = Month(date, calendar: .utc).index
        }
        service.lastSuccessfulRefresh = date
        service.lastRefreshError = nil
        try save()
    }

    func save() throws {
        try context.save()
        revision += 1
    }
}
