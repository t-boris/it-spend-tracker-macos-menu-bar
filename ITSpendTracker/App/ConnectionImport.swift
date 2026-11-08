import Foundation

/// One-time import of a prepared connection (e.g. a Google Cloud setup created for the user), passed at launch as
/// `-ImportConnectionFile <path>`. The file is read once and deleted; secrets go straight to the Keychain.
///
/// Without a `connector` the file describes a manual service (DEC-044): an optional https `consoleLink` and dated
/// `payments` (e.g. monthly invoices), each stored as one dated amount counted in the month of its date (DEC-040).
struct ConnectionImport: Decodable {
    struct Payment: Decodable {
        var date: String
        var amount: FlexibleDecimal
        var label: String?
    }

    var name: String
    var connector: ConnectorID?
    var accountIdentifier: String?
    var credentials: [String: String]?
    var consoleLink: String?
    var payments: [Payment]?

    enum ImportError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): String(localized: "The connection file could not be imported: \(detail)")
            }
        }
    }

    /// Imports the file into the store and deletes it, whether or not the import succeeds. A service with the same
    /// connector and name is updated (the given fields are merged into its saved credentials) instead of duplicated.
    @MainActor
    static func run(path: String, store: SpendStore) throws -> TrackedService {
        let url = URL(filePath: path)
        defer { try? FileManager.default.removeItem(at: url) }
        let connection: ConnectionImport
        do {
            connection = try JSONDecoder().decode(ConnectionImport.self, from: Data(contentsOf: url))
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
        guard let connector = connection.connector else { return try runManual(connection, store: store) }
        let descriptor = connector.descriptor
        let fields = Set(descriptor.credentialFields.map(\.id) + descriptor.sessionFields)
        let credentials = (connection.credentials ?? [:]).filter { fields.contains($0.key) }
        if let existing = store.services.first(where: { $0.connector == connector && $0.name == connection.name }) {
            let merged = try store.credentials(for: existing).merging(credentials) { _, new in new }
            try store.updateCredentials(existing, merged)
            return existing
        }
        return try store.addConnectedService(name: connection.name, accountIdentifier: connection.accountIdentifier ?? "",
                                             connector: connector, definition: nil, credentials: credentials)
    }

    /// A manual service with the same name is updated: the link is replaced, payments already present
    /// (same day, amount and label) are not added twice, so running the same file again changes nothing.
    @MainActor
    private static func runManual(_ connection: ConnectionImport, store: SpendStore) throws -> TrackedService {
        let link = try SpendStore.validatedConsoleLink(connection.consoleLink)
        let payments: [(day: Day, amount: Decimal, label: String)] = try (connection.payments ?? []).map {
            guard let day = Day(isoPrefix: $0.date), $0.date.count == 10 else {
                throw ImportError.unreadable("payment date \($0.date) is not yyyy-MM-dd")
            }
            return (day, $0.amount.value, $0.label ?? "")
        }
        let service: TrackedService
        if let existing = store.services.first(where: { !$0.isConnected && $0.name == connection.name }) {
            service = existing
            if link != nil { service.consoleLink = link }
        } else {
            service = try store.addManualService(name: connection.name, consoleLink: link)
        }
        if let account = connection.accountIdentifier, !account.isEmpty { service.accountIdentifier = account }
        for payment in payments where !service.creditPurchases.contains(where: {
            $0.dayKey == payment.day.key && $0.amount == payment.amount && $0.volume == payment.label
        }) {
            try store.addCreditPurchase(service, day: payment.day, amount: payment.amount, volume: payment.label)
        }
        try store.save()
        return service
    }
}
