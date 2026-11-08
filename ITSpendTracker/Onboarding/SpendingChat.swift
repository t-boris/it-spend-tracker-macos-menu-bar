import Foundation
import Observation

/// Compact, secret-free description of the app's data for the spending chat (DEC-038).
/// Only amounts, names, dates and counts: no credential values, key secrets or key hints.
enum SpendingSnapshot {
    static let monthsIncluded = 12
    static let breakdownRowsPerDimension = 8

    @MainActor
    static func build(services: [TrackedService], today: Day) -> [String: Any] {
        let current = today.calendarMonth
        let months = current.adding(months: -(monthsIncluded - 1)).through(current)
        let now = Date()
        var serviceEntries: [[String: Any]] = []
        for service in services {
            let ledger = service.ledger
            var entry: [String: Any] = [
                "name": service.name,
                "connected_via_api": service.isConnected,
                "included_in_total": service.includedInTotal,
                "spend_is_estimate": service.spendIsEstimate,
                "spend_by_month": Dictionary(uniqueKeysWithValues: months.map { month -> (String, Any) in
                    ("\(month)", Self.amount(ledger.spend(in: month)))
                }),
            ]
            if let error = service.lastRefreshError { entry["last_refresh_error"] = error }
            if let reason = service.spendUnavailableReason { entry["spend_unavailable_reason"] = reason }
            let notes = service.providerNotes.map(\.text)
            if !notes.isEmpty { entry["notes"] = notes }

            let subscriptions = service.sortedSubscriptions.compactMap { record -> [String: Any]? in
                guard let plan = record.plan else { return nil }
                var item: [String: Any] = ["name": record.name, "period": plan.period.rawValue, "start": "\(plan.start)"]
                if let end = plan.end { item["end"] = "\(end)" }
                if let price = plan.price(on: today) { item["amount_usd"] = Self.number(price) }
                return item
            }
            if !subscriptions.isEmpty { entry["subscriptions"] = subscriptions }

            let purchases = service.creditPurchases.compactMap { purchase -> [String: Any]? in
                guard let day = Day(key: purchase.dayKey) else { return nil }
                return ["date": "\(day)", "amount_usd": Self.number(purchase.amount), "volume": purchase.volume]
            }
            if !purchases.isEmpty { entry["credit_purchases"] = purchases }

            let breakdown = Self.breakdown(service, month: current)
            if !breakdown.isEmpty { entry["breakdown_current_month"] = breakdown }

            let availability = KeyFieldAvailability(service: service)
            let keys = service.keys.map { key -> [String: Any] in
                var item: [String: Any] = ["name": key.name]
                for detail in key.details { item[detail.kind.rawValue] = detail.value }
                if let created = key.createdAt { item["created"] = Self.date(created) }
                if availability.lastUsed { item["last_used"] = key.lastUsedAt.map(Self.date) ?? "never" }
                if availability.expiry {
                    item["expires"] = key.expiresAt.map(Self.date) ?? "no expiry"
                    if WarningRules.isExpiringSoon(expiresAt: key.expiresAt, now: now) { item["expires_within_14_days"] = true }
                }
                if availability.spend, let cost = key.currentMonthCost {
                    item[availability.spendIsEstimate ? "cost_current_month_usd_estimate" : "cost_current_month_usd"] = Self.number(cost)
                }
                if let requests = key.requestsThisMonth { item["requests_current_month"] = requests }
                let tags = service.tags(forKey: key.externalID)
                if !tags.isEmpty { item["tags"] = tags }
                return item
            }
            if service.hasKeyData { entry["keys"] = keys }

            if let increase = WarningRules.spendIncrease(ledger: ledger, today: today) {
                entry["warning_spend_increase"] = ["month_to_date_usd": Self.number(increase.monthToDate),
                                                   "previous_month_same_days_usd": Self.number(increase.previousSamePeriod)]
            }
            serviceEntries.append(entry)
        }
        let included = services.filter(\.includedInTotal).map(\.ledger)
        let totals = Dictionary(uniqueKeysWithValues: months.map { month -> (String, Any) in
            ("\(month)", Self.amount(included.map { $0.spend(in: month) }.reduce(Amount.noData, +)))
        })
        return ["today": "\(today)", "currency": "USD", "services": serviceEntries, "total_of_included_services_by_month": totals]
    }

    @MainActor
    private static func breakdown(_ service: TrackedService, month: Month) -> [String: [[String: Any]]] {
        var result: [String: [[String: Any]]] = [:]
        for dimension in BreakdownDimension.allCases {
            let rows = service.breakdown.filter { $0.monthIndex == month.index && $0.dimensionRaw == dimension.rawValue }
                .sorted { $0.amount > $1.amount }.prefix(breakdownRowsPerDimension)
            if !rows.isEmpty {
                result[dimension.rawValue] = rows.map { ["label": $0.label, "usd": Self.number($0.amount)] }
            }
        }
        return result
    }

    static func json(_ snapshot: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Money as a decimal string rounded to cents ("107.25"): `Double` cannot represent such values exactly and
    /// would hand the model binary-float noise like 112.97999999999999.
    private static func number(_ value: Decimal) -> String {
        var rounded = Decimal()
        var source = value
        NSDecimalRound(&rounded, &source, 2, .bankers)
        return "\(rounded)"
    }
    /// A money string, or "no data" (never zero) when unknown.
    private static func amount(_ amount: Amount) -> Any { amount.decimal.map { number($0) as Any } ?? "no data" }
    private static func date(_ date: Date) -> String { "\(Day(date))" }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

/// One chat session (DEC-038): kept in memory only; each question re-sends the snapshot and the turns so far.
@MainActor
@Observable
final class SpendingChat {
    private(set) var messages: [ChatMessage] = []
    private(set) var isAnswering = false
    private(set) var error: String?

    nonisolated static let maxTurnsSent = 10

    nonisolated static func prompt(snapshot: String, history: [ChatMessage], question: String, language: String) -> String {
        let turns = history.suffix(maxTurnsSent).map { message in
            "\(message.role == .user ? "User" : "Assistant"): \(message.text)"
        }.joined(separator: "\n\n")
        return """
        You are the analyst inside a personal macOS app that tracks a single user's spending on IT and AI services.
        Answer in \(language). Be concise and concrete: cite the numbers, name services and keys, give amounts in USD.
        Values marked as estimates are approximations; say so when you rely on them. "no data" means unknown, not zero.
        Base every statement on the data below; if the data cannot answer, say what is missing. Do not invent figures.
        You cannot change anything in the app; when the user should act (cancel, disable a key), say where and what.

        DATA (JSON):
        \(snapshot)

        \(turns.isEmpty ? "" : "CONVERSATION SO FAR:\n\(turns)\n")
        User: \(question)
        Assistant:
        """
    }

    func ask(_ question: String, snapshot: String, backend: AssistantBackend, language: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        isAnswering = true
        error = nil
        let prompt = Self.prompt(snapshot: snapshot, history: messages, question: trimmed, language: language)
        messages.append(ChatMessage(role: .user, text: trimmed))
        defer { isAnswering = false }
        do {
            let answer = try await AssistantCLI(backend: backend).ask(prompt)
            messages.append(ChatMessage(role: .assistant, text: answer))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clear() {
        messages = []
        error = nil
    }
}
