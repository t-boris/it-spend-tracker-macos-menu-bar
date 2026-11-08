import SwiftUI
import UniformTypeIdentifiers

/// A PDF chosen or dropped by the user.
struct InvoiceFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Reads an invoice PDF with the assistant and books it on a manual service as one dated payment (DEC-046).
/// The user always sees and can edit what was read before it is saved.
struct InvoiceImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: URL
    /// The service the sheet was opened from; otherwise it is chosen by vendor name.
    let preselected: UUID?

    private enum Phase {
        case reading
        case failed(String)
        case ready(InvoiceDraft)
    }

    @State private var phase: Phase = .reading
    @State private var serviceID: UUID?
    @State private var amount = ""
    @State private var paymentDate = PaymentDateEntry()
    @State private var label = ""
    @State private var error: String?

    private var manualServices: [TrackedService] { model.store.services.filter { !$0.isConnected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add invoice from PDF").font(.headline)
            Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            switch phase {
            case .reading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading the invoice with \(model.assistantBackend.displayName)…").foregroundStyle(.secondary)
                }
                Text("The text of the invoice is sent to \(model.assistantBackend.displayName) to read the amount and dates. Nothing else leaves the app.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                Button("Try again") { phase = .reading; Task { await read() } }
            case .ready(let draft):
                form(draft)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if case .ready(let draft) = phase {
                    Button("Save") { save(draft) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave(draft))
                }
            }
        }
        .padding(16)
        .frame(width: 440)
        .task { await read() }
    }

    @ViewBuilder
    private func form(_ draft: InvoiceDraft) -> some View {
        Form {
            Picker("Service", selection: $serviceID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(manualServices) { Text($0.name).tag(Optional($0.id)) }
            }
            LabeledContent("Read from the invoice") {
                Text([draft.vendor.nilIfEmpty, draft.invoiceNumber].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            USDField(title: "Amount, USD", text: $amount)
            if !draft.isUSD {
                Label("The invoice is in \(draft.currency.isEmpty ? String(localized: "an unknown currency") : draft.currency). Enter the amount in USD.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            DatePicker("Payment date",
                       selection: Binding(get: { paymentDate.pickerDate() }, set: { paymentDate.pick($0) }),
                       displayedComponents: .date)
            if !paymentDate.isSet {
                Text("No date found: choose the payment date.").font(.caption).foregroundStyle(.orange)
            }
            TextField("Note", text: $label)
            if let duplicate = duplicateWarning(draft) {
                Label(duplicate, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
    }

    private func duplicateWarning(_ draft: InvoiceDraft) -> String? {
        guard let number = draft.invoiceNumber, let id = serviceID, let service = model.store.service(id: id),
              service.hasInvoice(number: number) else { return nil }
        return String(localized: "Invoice \(number) is already recorded on this service.")
    }

    private func canSave(_ draft: InvoiceDraft) -> Bool {
        serviceID != nil && Format.parseAmount(amount) != nil && paymentDate.isSet && duplicateWarning(draft) == nil
    }

    private func read() async {
        do {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let text = try InvoiceReader.text(from: file)
            let answer = try await AssistantCLI(backend: model.assistantBackend)
                .ask(InvoicePrompts.extraction(text: text), timeout: 180)
            let draft = try InvoiceDraft.parse(answer)
            if draft.isUSD { amount = "\(draft.amount)" }
            paymentDate = PaymentDateEntry(draft.paymentDay)
            label = draft.label
            serviceID = preselected ?? InvoiceMatching.service(forVendor: draft.vendor, in: manualServices)?.id
            phase = .ready(draft)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func save(_ draft: InvoiceDraft) {
        guard let id = serviceID, let service = model.store.service(id: id), let value = Format.parseAmount(amount),
              let day = paymentDate.day else { return }
        do {
            try model.store.addCreditPurchase(service, day: day, amount: value, volume: label)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Opens the file picker for a PDF; the chosen file starts the import sheet.
struct InvoicePicker: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var file: InvoiceFile?

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { file = InvoiceFile(url: url) }
        }
    }
}

extension View {
    func invoicePicker(isPresented: Binding<Bool>, file: Binding<InvoiceFile?>) -> some View {
        modifier(InvoicePicker(isPresented: isPresented, file: file))
    }
}
