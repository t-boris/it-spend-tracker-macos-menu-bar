import SwiftUI

/// Common sheet chrome: title, content, Cancel / Save.
struct FormSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let canSave: Bool
    let save: () throws -> Void
    @ViewBuilder let content: Content
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 14)
            Form {
                content
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try save()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(14)
        }
        .frame(width: 400)
    }
}

/// USD amount field accepting "12.50" or "12,50".
struct USDField: View {
    let title: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text, prompt: Text("0.00"))
            .multilineTextAlignment(.trailing)
            .overlay(alignment: .trailing) {
                if !text.isEmpty && Format.parseAmount(text) == nil {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red).offset(x: 18)
                }
            }
    }
}

struct SubscriptionForm: View {
    @Environment(AppModel.self) private var model
    let service: TrackedService
    let record: SubscriptionRecord?
    @State private var name: String
    @State private var period: SubscriptionPlan.Period
    @State private var start: Date
    @State private var hasEnd: Bool
    @State private var end: Date
    @State private var amount = ""

    init(service: TrackedService, record: SubscriptionRecord?) {
        self.service = service
        self.record = record
        _name = State(initialValue: record?.name ?? (service.subscriptionRecords.isEmpty ? service.name : ""))
        _period = State(initialValue: record?.period ?? .monthly)
        _start = State(initialValue: record?.start?.date ?? Date())
        _hasEnd = State(initialValue: record?.end != nil)
        _end = State(initialValue: record?.end?.date ?? Date())
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        FormSheet(title: record == nil ? "Add subscription" : "Edit subscription",
                  canSave: !trimmedName.isEmpty && (record != nil || Format.parseAmount(amount) != nil)) {
            if let record {
                try model.store.updateSubscription(record, name: trimmedName, period: period, start: Day(start),
                                                   end: hasEnd ? Day(end) : nil)
            } else if let value = Format.parseAmount(amount) {
                try model.store.addSubscription(service, name: trimmedName, period: period, start: Day(start),
                                                end: hasEnd ? Day(end) : nil, amount: value)
            }
        } content: {
            TextField("Name", text: $name, prompt: Text("e.g. ChatGPT Pro"))
            Picker("Billing period", selection: $period) {
                ForEach(SubscriptionPlan.Period.allCases) { Text($0.title).tag($0) }
            }
            DatePicker("First payment date", selection: $start, displayedComponents: .date)
            Toggle("Has end date", isOn: $hasEnd)
            if hasEnd { DatePicker("End date", selection: $end, in: start..., displayedComponents: .date) }
            if record == nil {
                USDField(title: "Amount, USD", text: $amount)
            } else {
                Text("Use “Change price” to change the amount from a given date.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Payments repeat on this day every period and appear in history in the month they are paid. Amounts are in USD; convert other currencies when entering.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PriceChangeForm: View {
    @Environment(AppModel.self) private var model
    let record: SubscriptionRecord
    @State private var amount = ""
    @State private var effective = Date()

    var body: some View {
        FormSheet(title: "Change price", canSave: Format.parseAmount(amount) != nil) {
            guard let value = Format.parseAmount(amount) else { return }
            try model.store.changePrice(record, amount: value, effectiveFrom: Day(effective))
        } content: {
            LabeledContent("Subscription", value: record.name)
            USDField(title: "New amount, USD", text: $amount)
            DatePicker("Effective from", selection: $effective, displayedComponents: .date)
            Text("Charges before this date keep the old amount.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CreditPurchaseForm: View {
    @Environment(AppModel.self) private var model
    let service: TrackedService
    let purchase: CreditPurchaseRecord?
    @State private var amount: String
    @State private var date: Date
    @State private var volume: String

    init(service: TrackedService, purchase: CreditPurchaseRecord?) {
        self.service = service
        self.purchase = purchase
        _amount = State(initialValue: purchase.map { "\($0.amount)" } ?? "")
        _date = State(initialValue: purchase.flatMap { Day(key: $0.dayKey)?.date } ?? Date())
        _volume = State(initialValue: purchase?.volume ?? "")
    }

    var body: some View {
        let wording = PaymentWording(isConnected: service.isConnected)
        FormSheet(title: LocalizedStringKey(purchase == nil ? wording.formTitle.add : wording.formTitle.edit),
                  canSave: Format.parseAmount(amount) != nil) {
            guard let value = Format.parseAmount(amount) else { return }
            if let purchase {
                try model.store.updateCreditPurchase(purchase, day: Day(date), amount: value, volume: volume)
            } else {
                try model.store.addCreditPurchase(service, day: Day(date), amount: value, volume: volume)
            }
        } content: {
            USDField(title: "Amount paid, USD", text: $amount)
            DatePicker(PaymentWording(isConnected: service.isConnected).dateLabel, selection: $date, displayedComponents: .date)
            TextField("Volume (optional)", text: $volume, prompt: Text("e.g. 1M tokens"))
        }
    }
}

struct BalanceSnapshotForm: View {
    @Environment(AppModel.self) private var model
    let service: TrackedService
    @State private var amount: String
    @State private var date: Date

    init(service: TrackedService) {
        self.service = service
        _amount = State(initialValue: service.balanceSnapshotAmount.map { "\($0)" } ?? "")
        _date = State(initialValue: service.balanceSnapshotDayKey.flatMap { Day(key: $0)?.date } ?? Date())
    }

    var body: some View {
        FormSheet(title: "Credit balance", canSave: amount.isEmpty || Format.parseAmount(amount) != nil) {
            try model.store.setBalanceSnapshot(service, amount: Format.parseAmount(amount), day: Day(date))
        } content: {
            USDField(title: "Balance, USD", text: $amount)
            DatePicker("As of", selection: $date, displayedComponents: .date)
            Text("Remaining is estimated from this balance, later purchases and the usage cost reported by the provider. Leave empty to clear.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Native credential entry (DEC-011): values go straight to the Keychain and are never shown to the AI.
struct CredentialFieldsView: View {
    struct FieldSpec: Identifiable {
        let id: String
        let label: String
        let help: String
        let isSecret: Bool
        let isOptional: Bool
        let isMultiline: Bool
    }

    let fields: [FieldSpec]
    @Binding var values: [String: String]
    var existing: Bool = false

    var body: some View {
        ForEach(fields) { field in
            VStack(alignment: .leading, spacing: 4) {
                let binding = Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
                let placeholder = existing && field.isSecret ? String(localized: "saved — leave empty to keep") : ""
                if field.isMultiline {
                    Text(field.label)
                    TextEditor(text: binding)
                        .font(.caption.monospaced())
                        .frame(height: 90)
                        .overlay(alignment: .topLeading) {
                            if binding.wrappedValue.isEmpty && !placeholder.isEmpty {
                                Text(placeholder).font(.caption).foregroundStyle(.tertiary).padding(4)
                            }
                        }
                } else if field.isSecret {
                    SecureField(field.label, text: binding, prompt: Text(placeholder))
                } else {
                    TextField(field.label, text: binding, prompt: Text(field.isOptional ? String(localized: "optional") : ""))
                }
                Text(AssistantAnswer.linkified(field.help)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func specs(for connector: ConnectorID) -> [FieldSpec] {
        connector.descriptor.credentialFields.map {
            FieldSpec(id: $0.id, label: String(localized: $0.label), help: String(localized: $0.help),
                      isSecret: $0.isSecret, isOptional: $0.isOptional, isMultiline: $0.isMultiline)
        }
    }

    static func specs(for definition: ConnectorDefinition) -> [FieldSpec] {
        definition.credentialFields.map {
            FieldSpec(id: $0.id, label: $0.label, help: $0.help ?? "", isSecret: $0.secret, isOptional: false, isMultiline: false)
        }
    }

    static func specs(for service: TrackedService) -> [FieldSpec] {
        if let connector = service.connector { return specs(for: connector) }
        if let definition = service.definition { return specs(for: definition) }
        return []
    }

    static func missingRequired(_ fields: [FieldSpec], values: [String: String]) -> Bool {
        fields.contains { !$0.isOptional && (values[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct CredentialsUpdateForm: View {
    @Environment(AppModel.self) private var model
    let service: TrackedService
    @State private var values: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        let fields = CredentialFieldsView.specs(for: service)
        FormSheet(title: "Update credentials", canSave: true) {
            var merged = try model.store.credentials(for: service)
            for field in fields {
                let value = values[field.id] ?? ""
                if field.isSecret && value.isEmpty { continue }
                merged[field.id] = value
            }
            try model.store.updateCredentials(service, merged)
            Task { await model.refresh.refresh(serviceID: service.id) }
        } content: {
            CredentialFieldsView(fields: fields, values: $values, existing: true)
        }
        .task {
            guard !loaded else { return }
            loaded = true
            // Only non-secret values are shown back; secrets stay in the Keychain.
            let stored = (try? model.store.credentials(for: service)) ?? [:]
            for field in fields where !field.isSecret { values[field.id] = stored[field.id] ?? "" }
        }
    }
}

struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}
