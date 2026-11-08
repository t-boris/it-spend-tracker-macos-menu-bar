import Foundation

/// How recorded payments are named. A manual service records plain payments (an invoice, a top-up): "Payment". A
/// service connected to an API keeps "credit purchase", which is what its provider calls them (REQ-013).
struct PaymentWording: Equatable {
    let isConnected: Bool

    var section: String { isConnected ? String(localized: "Credits") : String(localized: "Payments") }
    var addButton: String { isConnected ? String(localized: "Add credit purchase…") : String(localized: "Add payment…") }
    var formTitle: (add: String, edit: String) {
        isConnected ? (String(localized: "Add credit purchase"), String(localized: "Edit credit purchase"))
                    : (String(localized: "Add payment"), String(localized: "Edit payment"))
    }
    var dateLabel: String { isConnected ? String(localized: "Purchase date") : String(localized: "Payment date") }
    var item: String { isConnected ? String(localized: "Credit purchase") : String(localized: "Payment") }
    var chartKind: String { isConnected ? String(localized: "Credit purchases") : String(localized: "Payments") }
    var footer: String? {
        isConnected ? nil : String(localized: "Payments count as spend in the month they are paid.")
    }
}
