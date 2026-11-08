import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-020 / DEC-046: the text of an invoice is sent to the assistant only after the user has asked for it.
@Suite @MainActor struct InvoiceReadingConsentTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AssistantBackend] = []
        func add(_ backend: AssistantBackend) { lock.withLock { items.append(backend) } }
        var backends: [AssistantBackend] { lock.withLock { items } }
    }

    private let file = URL(filePath: "/tmp/invoice.pdf")
    private let draftJSON = #"{"vendor":"Fly.io","invoiceNumber":"INV-0012","serviceMonth":"2026-09","total":5.50,"currency":"USD"}"#

    @Test func openingTheSheetReadsNothing() async throws {
        let calls = Calls()
        let draft = try InvoiceDraft.parse(draftJSON)
        let reading = InvoiceReading(file: file) { _, backend in calls.add(backend); return draft }
        #expect(reading.isAwaitingConsent)
        await Task.yield()
        #expect(calls.backends.isEmpty, "creating the reader must not read or send anything")
        #expect(reading.isAwaitingConsent)
    }

    @Test func readingStartsOnlyWhenAskedAndUsesTheChosenAssistant() async throws {
        let calls = Calls()
        let draft = try InvoiceDraft.parse(draftJSON)
        let reading = InvoiceReading(file: file) { _, backend in calls.add(backend); return draft }
        let result = await reading.start(backend: .codex)
        #expect(calls.backends == [.codex])
        #expect(result?.invoiceNumber == "INV-0012")
        if case .ready(let ready) = reading.phase { #expect(ready.invoiceNumber == "INV-0012") } else { Issue.record("not ready") }
    }

    @Test func aFailedReadCanBeRetriedOnlyByAskingAgain() async throws {
        struct Unreadable: LocalizedError { var errorDescription: String? { "no text" } }
        let calls = Calls()
        let reading = InvoiceReading(file: file) { _, backend in calls.add(backend); throw Unreadable() }
        #expect(await reading.start(backend: .claude) == nil)
        if case .failed(let message) = reading.phase { #expect(message == "no text") } else { Issue.record("not failed") }
        #expect(calls.backends.count == 1)                 // no automatic second attempt
        _ = await reading.start(backend: .claude)
        #expect(calls.backends.count == 2)                 // the user's "Try again"
    }
}
