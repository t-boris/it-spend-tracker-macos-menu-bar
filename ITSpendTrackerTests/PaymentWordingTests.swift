import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-013: a manual service records plain "payments"; a service connected to an API keeps "credit purchases".
@Suite struct PaymentWordingTests {
    private let manual = PaymentWording(isConnected: false)
    private let connected = PaymentWording(isConnected: true)

    @Test func manualServicesSayPayment() {
        #expect(manual.section == "Payments")
        #expect(manual.item == "Payment")
        #expect(manual.chartKind == "Payments")
        #expect(manual.addButton == "Add payment…")
        #expect(manual.formTitle.add == "Add payment" && manual.formTitle.edit == "Edit payment")
        #expect(manual.dateLabel == "Payment date")
        #expect(manual.footer == "Payments count as spend in the month they are paid.")
        for text in [manual.section, manual.item, manual.chartKind, manual.addButton, manual.formTitle.add, manual.formTitle.edit,
                     manual.dateLabel, manual.footer ?? ""] {
            #expect(!text.localizedCaseInsensitiveContains("credit"), "\(text) must be neutral")
            #expect(!text.localizedCaseInsensitiveContains("purchase"), "\(text) must be neutral")
        }
    }

    @Test func apiServicesKeepCreditPurchases() {
        #expect(connected.section == "Credits")
        #expect(connected.item == "Credit purchase")
        #expect(connected.chartKind == "Credit purchases")
        #expect(connected.addButton == "Add credit purchase…")
        #expect(connected.formTitle.add == "Add credit purchase" && connected.formTitle.edit == "Edit credit purchase")
        #expect(connected.dateLabel == "Purchase date")
        #expect(connected.footer == nil)
    }

    @Test func theLedgerNamesAPaymentOfAManualServiceNeutrally() {
        let day = Day(year: 2026, month: 9, day: 30)
        let purchase = (day: day, amount: Decimal(5.5))
        let manualLedger = ServiceLedger(isConnected: false, providerDailyCosts: [:], creditPurchases: [purchase])
        #expect(manualLedger.payments(from: day, through: day).map(\.label) == ["Payment"])
        let apiLedger = ServiceLedger(isConnected: true, providerDailyCosts: [:], creditPurchases: [purchase])
        #expect(apiLedger.payments(from: day, through: day).map(\.label) == ["Credit purchase"])
    }
}
