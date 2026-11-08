#if DEBUG
import Foundation

/// Sample data for visual checks (`-DemoData YES`). Debug builds only, in-memory store, no credentials.
@MainActor
enum DemoData {
    /// Inserted directly so that nothing is written to the Keychain.
    private static func connected(_ store: SpendStore, _ name: String, account: String, connector: ConnectorID) -> TrackedService {
        let service = TrackedService(name: name, accountIdentifier: account, connector: connector)
        store.context.insert(service)
        return service
    }

    static func seed(_ store: SpendStore) {
        let now = Date()
        let today = Day(now)
        func days(_ month: Month, _ perDay: Decimal) -> [Day: Decimal] {
            var result: [Day: Decimal] = [:]
            for day in 1...month.dayCount {
                let date = Day(year: month.year, month: month.month, day: day)
                if date <= today { result[date] = perDay }
            }
            return result
        }
        let start = today.calendarMonth.adding(months: -11)
        do {
            let openAI = connected(store, "OpenAI", account: "owner@example.com", connector: .openAI)
            var openAICosts: [Day: Decimal] = [:]
            for (offset, month) in start.through(today.calendarMonth).enumerated() {
                openAICosts.merge(days(month, Decimal(offset + 2) / 4)) { $1 }
            }
            try store.apply(ConnectorSnapshot(
                dailyCosts: openAICosts, coveredFrom: start.firstDay,
                keys: [ProviderKey(externalID: "k1", name: "ci-bot", hint: "Main · sk-proj-…a1b2",
                                   createdAt: now.addingTimeInterval(-200 * 86_400), lastUsedAt: now.addingTimeInterval(-3600),
                                   expiresAt: now.addingTimeInterval(5 * 86_400), currentMonthCost: 12.4),
                       ProviderKey(externalID: "k2", name: "scripts", hint: "Main · sk-proj-…c3d4",
                                   createdAt: now.addingTimeInterval(-90 * 86_400), lastUsedAt: nil, expiresAt: nil,
                                   currentMonthCost: 0)],
                tokenUsage: [TokenUsageRow(keyExternalID: "k1", model: "gpt-6", inputTokens: 1_250_000, cachedInputTokens: 400_000, outputTokens: 180_000),
                             TokenUsageRow(keyExternalID: "k1", model: "gpt-6-mini", inputTokens: 3_400_000, cachedInputTokens: 0, outputTokens: 520_000)],
                breakdown: [BreakdownRow(month: today.calendarMonth, dimension: .lineItem, label: "gpt-6, input", amount: 4.1),
                            BreakdownRow(month: today.calendarMonth, dimension: .lineItem, label: "gpt-6, output", amount: 6.2),
                            BreakdownRow(month: today.calendarMonth, dimension: .lineItem, label: "web search tool calls", amount: 0.4),
                            BreakdownRow(month: today.calendarMonth, dimension: .project, label: "Example Pro", amount: 9.5),
                            BreakdownRow(month: today.calendarMonth, dimension: .project, label: "Default project", amount: 1.2)],
                breakdownFrom: start),
                to: openAI, at: now)
            try store.addCreditPurchase(openAI, day: today.calendarMonth.firstDay, amount: 50, volume: "")
            try store.addCreditPurchase(openAI, day: today.calendarMonth.adding(months: -3).firstDay.adding(months: 0), amount: 50, volume: "")
            try store.addSubscription(openAI, name: "ChatGPT Pro", period: .monthly, start: Day(year: 2025, month: 12, day: 3),
                                      end: nil, amount: 100)
            try store.setBalanceSnapshot(openAI, amount: 30, day: today.calendarMonth.previous.lastDay)

            let vercel = connected(store, "Vercel", account: "demo-team", connector: .vercel)
            var vercelCosts = days(today.calendarMonth.previous, 0.5)
            vercelCosts.merge(days(today.calendarMonth, 1.5)) { $1 }
            try store.apply(ConnectorSnapshot(dailyCosts: vercelCosts, coveredFrom: today.calendarMonth.previous.firstDay,
                                              keys: [], tokenUsage: nil), to: vercel, at: now.addingTimeInterval(-7200))
            store.recordRefreshFailure(vercel, message: "Provider returned HTTP 503: Service Unavailable")

            let chatGPT = try store.addManualService(name: "ChatGPT Plus")
            try store.addSubscription(chatGPT, name: "ChatGPT Plus", period: .monthly, start: Day(year: 2025, month: 3, day: 14), end: nil, amount: 20)
            let neon = try store.addManualService(name: "Neon")
            try store.addSubscription(neon, name: "Neon Launch", period: .monthly, start: Day(year: 2025, month: 11, day: 1), end: nil, amount: 19)
            let fly = try store.addManualService(name: "Fly.io", note: "Prepaid credits")
            try store.addCreditPurchase(fly, day: today.calendarMonth.adding(months: -2).firstDay, amount: 25, volume: "25 credits")
            try store.setIncludedInTotal(fly, false)
        } catch {
            assertionFailure("Demo seeding failed: \(error)")
        }
    }
}
#endif
