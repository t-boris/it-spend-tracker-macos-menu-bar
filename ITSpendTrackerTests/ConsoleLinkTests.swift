import Foundation
import SwiftData
import Testing
@testable import ITSpendTracker

/// Optional console link of manual services (DEC-041).
@Suite @MainActor struct ConsoleLinkTests {
    private func makeStore() throws -> SpendStore {
        SpendStore(container: try Persistence.makeContainer(inMemory: true),
                   keychain: KeychainStore(serviceName: "app.itspendtracker.ITSpendTracker.tests.\(UUID().uuidString)"))
    }

    @Test func linkIsNilByDefaultAndSpendIsUnaffected() throws {
        let store = try makeStore()
        let plain = try store.addManualService(name: "Plain")
        let linked = try store.addManualService(name: "Linked", consoleLink: "https://fly.io/dashboard/example-org/billing")
        for service in [plain, linked] {
            try store.addCreditPurchase(service, day: Day(year: 2026, month: 9, day: 10), amount: 42, volume: "")
        }
        #expect(plain.consoleLink == nil)
        #expect(plain.consoleLinkURL == nil)
        #expect(linked.consoleLinkURL?.absoluteString == "https://fly.io/dashboard/example-org/billing")
        let september = Month(year: 2026, month: 9)
        #expect(plain.ledger.spend(in: september) == linked.ledger.spend(in: september))
    }

    @Test func onlyHTTPSAddressesAreAccepted() throws {
        let store = try makeStore()
        for bad in ["http://fly.io/dashboard", "ftp://fly.io", "javascript:alert(1)", "fly.io/dashboard", "https://", "not a url"] {
            #expect(throws: SpendStore.ConsoleLinkError.self, "\(bad)") { _ = try store.addManualService(name: "X", consoleLink: bad) }
        }
        #expect(store.services.isEmpty)  // a rejected link creates nothing
        #expect(try SpendStore.validatedConsoleLink("  ") == nil)
        #expect(try SpendStore.validatedConsoleLink(nil) == nil)
        #expect(try SpendStore.validatedConsoleLink(" https://fly.io/dashboard ") == "https://fly.io/dashboard")
    }

    @Test func invalidStoredValueIsNotRendered() throws {
        let service = TrackedService(name: "Legacy")
        service.consoleLink = "http://insecure.example"
        #expect(service.consoleLinkURL == nil)
    }
}
