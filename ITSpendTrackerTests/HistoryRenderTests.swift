import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import ITSpendTracker

/// Opt-in visual check of the day-level history (REQ-019): renders the page with varied sample data to PNG files.
/// Run with `TEST_RUNNER_ITS_RENDER_DIR=<dir> xcodebuild test …`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ITS_RENDER_DIR"] != nil))
@MainActor struct HistoryRenderTests {
    /// REQ-004: the monthly table lists every service per month; "no data" before an account's first cost,
    /// $0.00 for a real zero month.
    @Test func renderMonthlyHistory() throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["ITS_RENDER_DIR"]!)
        let model = AppModel()
        let store = model.store
        let current = model.today.calendarMonth
        let months = current.adding(months: -11).through(current)
        func connected(_ name: String, _ connector: ConnectorID, costs: [Month: Decimal], from: Month) throws {
            let service = TrackedService(name: name, connector: connector)
            store.context.insert(service)
            let daily = Dictionary(uniqueKeysWithValues: costs.map { ($0.key.firstDay.adding(days: 9), $0.value) })
            try store.apply(ConnectorSnapshot(dailyCosts: daily, coveredFrom: from.firstDay, keys: [], tokenUsage: nil),
                            to: service, at: Date())
        }
        // Covered for all 12 months, costs only in some of them: the quiet months are real zeros.
        try connected("Vercel", .vercel, costs: [months[1]: 20, months[2]: 20, months[7]: 20, months[11]: 20], from: months[0])
        // An account that appeared three months ago: earlier months have no data.
        try connected("Anthropic", .anthropic, costs: [months[9]: 40, months[10]: 55, months[11]: 70], from: months[9])
        let manual = try store.addManualService(name: "ChatGPT Plus")
        try store.addSubscription(manual, name: "ChatGPT Plus", period: .monthly, start: months[0].firstDay, end: nil, amount: 20)

        // The table is rendered on its own: ImageRenderer does not draw ScrollView content, which wraps it on the page.
        let view = MonthlyTable(services: store.services.filter(\.includedInTotal), months: months)
            .environment(model)
            .padding(20)
            .frame(width: 900)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: "history-monthly-table.png"))
    }

    @Test func renderDailyHistory() throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["ITS_RENDER_DIR"]!)
        let model = AppModel()
        let store = model.store
        let today = model.today
        func service(_ name: String, _ connector: ConnectorID) -> TrackedService {
            let service = TrackedService(name: name, connector: connector)
            store.context.insert(service)
            return service
        }
        let start = today.adding(days: -120)
        var openAI: [Day: Decimal] = [:]
        var anthropic: [Day: Decimal] = [:]
        for (offset, day) in start.through(today).enumerated() {
            let weekday = Calendar.utc.component(.weekday, from: day.startDate(calendar: .utc))
            let weekend = weekday == 1 || weekday == 7
            openAI[day] = Decimal(Double(offset) * 0.04 + (weekend ? 0.8 : 2.5) + Double(offset % 5) * 0.3)
            anthropic[day] = Decimal(offset > 90 ? (weekend ? 2.0 : 6.5) : (weekend ? 1.0 : 3.0))
        }
        try store.apply(ConnectorSnapshot(dailyCosts: openAI, coveredFrom: start, keys: [], tokenUsage: nil),
                        to: service("OpenAI", .openAI), at: Date())
        try store.apply(ConnectorSnapshot(dailyCosts: anthropic, coveredFrom: start, keys: [], tokenUsage: nil),
                        to: service("Anthropic", .anthropic), at: Date())
        let neonMonths = today.calendarMonth.adding(months: -3).through(today.calendarMonth)
        let neonCosts = Dictionary(uniqueKeysWithValues: neonMonths.map { ($0.firstDay, Decimal(today.calendarMonth == $0 ? 0.6 : 18)) })
        try store.apply(ConnectorSnapshot(dailyCosts: neonCosts, coveredFrom: neonMonths[0].firstDay, keys: [], tokenUsage: nil),
                        to: service("Neon", .neon), at: Date())
        let manual = try store.addManualService(name: "ChatGPT Plus")
        try store.addSubscription(manual, name: "ChatGPT Plus", period: .monthly, start: Day(year: 2025, month: 3, day: 14),
                                  end: nil, amount: 20)

        for days in [30, 90] {
            let view = DailyHistory(days: days)
                .environment(model)
                .environment(\.isLargeLayout, true)
                .padding(20)
                .frame(width: 1100)
                .background(Color.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appending(path: "history-\(days).png"))
        }
    }
}

/// Opt-in check of the trend figures on a copy of a real store (never the live one):
/// `TEST_RUNNER_ITS_STORE_COPY=<copied spend.store> xcodebuild test …`. Prints, asserts nothing about amounts.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ITS_STORE_COPY"] != nil))
@MainActor struct RealStoreTrendReport {
    @Test func printTrends() throws {
        let url = URL(filePath: ProcessInfo.processInfo.environment["ITS_STORE_COPY"]!)
        let container = try ModelContainer(for: Persistence.schema, configurations: ModelConfiguration(schema: Persistence.schema, url: url))
        let services = try container.mainContext.fetch(FetchDescriptor<TrackedService>()).filter(\.includedInTotal)
        let today = Day(Date())
        func text(_ amount: Amount) -> String { amount.decimal.map { Format.usd($0) } ?? "no data" }
        for service in services {
            let ledger = service.ledger
            let comparison = SpendTrends.comparison([ledger], days: 30, today: today)
            print("TREND \(service.name): coverage \(ledger.providerCoverageStart?.description ?? "-") daily \(ledger.usageIsDaily)",
                  "| rate \(ledger.runRate(today: today).map(Format.usd) ?? "-")",
                  "| Sep \(text(ledger.spend(in: today.calendarMonth.previous)))",
                  "| MTD \(text(SpendTrends.monthToDate([ledger], today: today)))",
                  "| forecast \(text(ledger.forecast(today: today)))",
                  "| 30d \(text(comparison.current)) vs \(text(comparison.previous))")
        }
        let ledgers = services.map(\.ledger)
        let total = SpendTrends.comparison(ledgers, days: 30, today: today)
        print("TREND TOTAL: forecast \(text(SpendTrends.forecast(ledgers, today: today)))",
              "| MTD \(text(SpendTrends.monthToDate(ledgers, today: today)))",
              "| 30d \(text(total.current)) vs \(text(total.previous)) change \(total.change.map { "\($0.double)" } ?? "-")")
    }
}
