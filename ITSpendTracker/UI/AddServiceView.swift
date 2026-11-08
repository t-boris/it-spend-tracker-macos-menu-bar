import SwiftUI

/// Adding a service (REQ-005, REQ-007, REQ-012): built-in connector with AI guidance,
/// AI-proposed connector approved by the user, or manual entry.
struct AddServiceView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Route?

    enum Kind: Hashable {
        case builtIn(ConnectorID)
        case discover
        case manual
    }

    @State private var name = ""
    @State private var account = ""
    @State private var note = ""
    @State private var kind: Kind = .discover
    @State private var kindChosenByUser = false

    // Assistant
    @State private var assistantBusy = false
    @State private var guidance: String?
    @State private var assistantError: String?
    @State private var research: ResearchResult?
    @State private var approved = false

    // Connection
    @State private var credentials: [String: String] = [:]
    @State private var connecting = false
    @State private var connectError: String?
    @State private var signingInToCline = false

    // Manual
    @State private var addSubscription = true
    @State private var period: SubscriptionPlan.Period = .monthly
    @State private var start = Date()
    @State private var amount = ""
    @State private var consoleLink = ""

    private var intro: ServiceIntro {
        ServiceIntro(serviceName: name.trimmingCharacters(in: .whitespaces),
                     accountIdentifier: account.trimmingCharacters(in: .whitespaces),
                     note: note.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        Form {
            Section {
                TextField("Service name", text: $name, prompt: Text("e.g. OpenAI, Vercel, XDataAI"))
                    .onChange(of: name) { autoSelectKind() }
                TextField("Account (username or e-mail)", text: $account)
                TextField("Note", text: $note, prompt: Text("e.g. I pay $20 a month"))
            } header: {
                Text("New service")
            } footer: {
                Text("Name the service and ask the assistant: it finds out which keys are needed and where to get them.")
            }

            if kind != .manual {
                Section("Assistant") {
                    assistantButton(title: "Ask \(model.assistantBackend.displayName) to set up this service") {
                        try await askAssistant()
                    }
                    if let guidance { AssistantAnswer(text: guidance) }
                    if let research { AssistantAnswer(text: research.explanation) }
                    if case .builtIn(let id) = kind {
                        Link(destination: id.descriptor.consoleURL) { Label("Open provider console", systemImage: "safari") }
                    }
                }
            }

            Section("How to track it") {
                Picker("Connection", selection: Binding(get: { kind }, set: { kind = $0; kindChosenByUser = true; resetAssistant() })) {
                    ForEach(ConnectorID.allCases) { id in
                        Text("API: \(id.descriptor.displayName)").tag(Kind.builtIn(id))
                    }
                    Text("Find an API with the assistant").tag(Kind.discover)
                    Text("Manual entry (subscription or credits)").tag(Kind.manual)
                }
                switch kind {
                case .builtIn(let id):
                    Text("Built-in connector. Reads: \(capabilityText(id.descriptor.capabilities))")
                        .font(.caption).foregroundStyle(.secondary)
                case .discover:
                    Text("The assistant searches the provider's documentation for an API key that shows spend, tokens or keys. You review what it finds before anything is saved.")
                        .font(.caption).foregroundStyle(.secondary)
                case .manual:
                    Text("For services without an API: enter the subscription price or record credit purchases yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            switch kind {
            case .builtIn(let id): builtInSections(id)
            case .discover: discoverSections()
            case .manual: manualSection()
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Add service"))
    }

    // MARK: Built-in connector

    @ViewBuilder
    private func builtInSections(_ id: ConnectorID) -> some View {
        if id == .cline {
            clineSection()
        } else {
            connectSections(fields: CredentialFieldsView.specs(for: id), connector: id, definition: nil)
        }
    }

    /// Cline signs in to the account instead of taking a key (DEC-040).
    @ViewBuilder
    private func clineSection() -> some View {
        Section {
            if let connectError {
                Label(connectError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            Button {
                connectError = nil
                signingInToCline = true
            } label: {
                HStack {
                    if connecting { ProgressView().controlSize(.small) }
                    Text("Sign in with Cline and connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(connecting)
        } header: {
            Text("Cline account")
        } footer: {
            Text("Cline has no API keys for account data, so the app signs in to your Cline account. The session is stored only in the macOS Keychain.")
        }
        .sheet(isPresented: $signingInToCline) {
            ClineSignInSheet(title: "Sign in with Cline") { session in
                // Not tied to the view: connecting navigates away, which must not cancel the first refresh.
                Task { await connectCline(session) }
            }
        }
    }

    private func connectCline(_ session: [String: String]) async {
        connecting = true
        defer { connecting = false }
        do {
            try await add(connector: .cline, definition: nil, credentials: session,
                          defaultName: "Cline", defaultAccount: session[ClineAuth.Field.email] ?? "")
        } catch {
            connectError = error.localizedDescription
        }
    }

    // MARK: AI-proposed connector (DEC-022)

    @ViewBuilder
    private func discoverSections() -> some View {
        if let research {
            if research.status == .api, let definition = research.definition {
                DefinitionReview(definition: definition, approved: $approved)
                if approved && definition.validationProblems().isEmpty {
                    connectSections(fields: CredentialFieldsView.specs(for: definition), connector: nil, definition: definition)
                }
            } else {
                Section {
                    Text("No usable API found. Add the service manually instead.")
                    Button("Switch to manual entry") { kind = .manual; kindChosenByUser = true }
                }
            }
        }
    }

    /// One action (REQ-005/REQ-012): guidance for a built-in connector, otherwise API research.
    private func askAssistant() async throws {
        let cli = AssistantCLI(backend: model.assistantBackend)
        switch kind {
        case .builtIn(let id):
            guidance = try await cli.ask(AssistantPrompts.guidance(intro: intro, descriptor: id.descriptor))
        case .discover:
            let output = try await cli.ask(AssistantPrompts.research(intro: intro), allowWeb: true, timeout: 420)
            let result = try ResearchResult.parse(output)
            research = result
            approved = false
        case .manual:
            break
        }
    }

    // MARK: Shared connection form

    @ViewBuilder
    private func connectSections(fields: [CredentialFieldsView.FieldSpec], connector: ConnectorID?,
                                 definition: ConnectorDefinition?) -> some View {
        Section {
            CredentialFieldsView(fields: fields, values: $credentials)
        } header: {
            Text("Credentials")
        } footer: {
            Text("Stored only in the macOS Keychain. Never sent to the assistant.")
        }
        Section {
            if let connectError {
                Label(connectError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            Button {
                Task { await connect(fields: fields, connector: connector, definition: definition) }
            } label: {
                HStack {
                    if connecting { ProgressView().controlSize(.small) }
                    Text("Check and connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(connecting || intro.serviceName.isEmpty || CredentialFieldsView.missingRequired(fields, values: credentials))
        }
    }

    private func connect(fields: [CredentialFieldsView.FieldSpec], connector: ConnectorID?, definition: ConnectorDefinition?) async {
        connecting = true
        connectError = nil
        defer { connecting = false }
        let values = credentials.filter { key, value in
            fields.contains { $0.id == key } && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        do {
            try await add(connector: connector, definition: definition, credentials: values)
            credentials = [:]
        } catch {
            connectError = error.localizedDescription
        }
    }

    /// Tests the credentials, saves the service and loads its data.
    private func add(connector: ConnectorID?, definition: ConnectorDefinition?, credentials values: [String: String],
                     defaultName: String = "", defaultAccount: String = "") async throws {
        try await model.refresh.test(connector: connector, definition: definition, credentials: values)
        let service = try model.store.addConnectedService(name: intro.serviceName.isEmpty ? defaultName : intro.serviceName,
                                                          accountIdentifier: intro.accountIdentifier.isEmpty ? defaultAccount : intro.accountIdentifier,
                                                          connector: connector, definition: definition,
                                                          credentials: values)
        if !intro.note.isEmpty { service.note = intro.note; try model.store.save() }
        selection = .service(service.id)
        await model.refresh.refresh(serviceID: service.id)
    }

    // MARK: Manual entry (REQ-007)

    @ViewBuilder
    private func manualSection() -> some View {
        Section {
            Toggle("Recurring subscription", isOn: $addSubscription)
            if addSubscription {
                Picker("Billing period", selection: $period) {
                    ForEach(SubscriptionPlan.Period.allCases) { Text($0.title).tag($0) }
                }
                DatePicker("First payment date", selection: $start, displayedComponents: .date)
                USDField(title: "Amount, USD", text: $amount)
            } else {
                Text("You can record credit purchases on the service page.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Console link (optional)", text: $consoleLink, prompt: Text("https://…"))
            if let connectError { Text(connectError).foregroundStyle(.red) }
            Button("Add service") { addManual() }
                .buttonStyle(.borderedProminent)
                .disabled(intro.serviceName.isEmpty || (addSubscription && Format.parseAmount(amount) == nil))
        } header: {
            Text("Manual entry")
        } footer: {
            Text("Amounts are in USD; convert other currencies when entering.")
        }
    }

    private func addManual() {
        do {
            let service = try model.store.addManualService(name: intro.serviceName, note: intro.note, consoleLink: consoleLink)
            if !intro.accountIdentifier.isEmpty { service.accountIdentifier = intro.accountIdentifier }
            if addSubscription, let value = Format.parseAmount(amount) {
                try model.store.addSubscription(service, name: intro.serviceName, period: period, start: Day(start), end: nil, amount: value)
            }
            try model.store.save()
            selection = .service(service.id)
        } catch {
            connectError = error.localizedDescription
        }
    }

    // MARK: Helpers

    private func assistantButton(title: LocalizedStringKey, action: @escaping () async throws -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task {
                    assistantBusy = true
                    assistantError = nil
                    defer { assistantBusy = false }
                    do { try await action() } catch { assistantError = error.localizedDescription }
                }
            } label: {
                HStack {
                    if assistantBusy { ProgressView().controlSize(.small) }
                    Text(title)
                }
            }
            .disabled(assistantBusy || intro.serviceName.isEmpty)
            if let assistantError {
                Label(assistantError, systemImage: "exclamationmark.bubble").foregroundStyle(.orange).font(.callout)
                    .textSelection(.enabled)
                Text("You can still set up the service manually.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func autoSelectKind() {
        guard !kindChosenByUser else { return }
        let newKind: Kind = ConnectorID.match(serviceName: name).map(Kind.builtIn) ?? .discover
        if newKind != kind {
            kind = newKind
            resetAssistant()
        }
    }

    private func resetAssistant() {
        guidance = nil
        research = nil
        assistantError = nil
        approved = false
        credentials = [:]
        connectError = nil
    }

    private func capabilityText(_ capabilities: ConnectorCapabilities) -> String {
        var parts = [String(localized: "daily spend")]
        if capabilities.keyDetails { parts.append(String(localized: "keys")) }
        if capabilities.tokenUsage { parts.append(String(localized: "token usage")) }
        return parts.joined(separator: ", ")
    }
}

/// Assistant output is shown as text only; nothing in it is executed (DEC-011). Links are clickable.
struct AssistantAnswer: View {
    let text: String

    var body: some View {
        Text(Self.linkified(text))
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Markdown (inline) plus plain https URLs turned into links. Only https destinations stay clickable: a Markdown
    /// link to `file:`, `x-apple.systempreferences:`, `javascript:` or any other scheme is shown as plain text, because
    /// the text comes from an AI and a click would hand its destination to the system (REQ-005).
    static func linkified(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in attributed.runs {
            if let link = run.link, link.scheme?.lowercased() != "https" { attributed[run.range].link = nil }
        }
        let plain = String(attributed.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url, url.scheme == "https", let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed),
                  attributed[lower..<upper].link == nil else { continue }
            attributed[lower..<upper].link = url
        }
        return attributed
    }
}

/// Plain-language review of an AI-proposed connector before the user approves it (REQ-012).
struct DefinitionReview: View {
    let definition: ConnectorDefinition
    @Binding var approved: Bool

    var body: some View {
        let problems = definition.validationProblems()
        Section {
            LabeledContent("Host", value: definition.host)
            if let spend = definition.spend { endpoint("Spend", spend.path) }
            if let tokens = definition.tokens { endpoint("Token usage", tokens.path) }
            if let keys = definition.keys { endpoint("Keys", keys.path) }
            LabeledContent("Secret sent in header") {
                Text(definition.auth.scheme == .bearer ? "Authorization: Bearer …" : "\(definition.auth.headerName ?? ""): …")
                    .font(.caption.monospaced())
            }
            if let url = ConnectorDefinition.safeLink(definition.docsURL) {
                Link("Provider documentation", destination: url)
            }
            if let url = ConnectorDefinition.safeLink(definition.consoleURL) {
                LabeledContent("Billing console") { Link(url.host() ?? url.absoluteString, destination: url) }
            }
            if let url = ConnectorDefinition.safeLink(definition.keysConsoleURL) {
                LabeledContent("Manage keys") { Link(url.host() ?? url.absoluteString, destination: url) }
            }
            if problems.isEmpty {
                Toggle("I reviewed this and allow the app to call these endpoints", isOn: $approved)
            } else {
                ForEach(problems, id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) }
                Text("This description cannot be used. Try again or add the service manually.").font(.caption)
            }
        } header: {
            Text("Proposed connection")
        } footer: {
            Text("The app will only send HTTPS GET requests to this host and read the data listed above.")
        }
    }

    private func endpoint(_ title: LocalizedStringKey, _ path: String) -> some View {
        LabeledContent(title) { Text("GET \(path)").font(.caption.monospaced()).lineLimit(2).truncationMode(.middle) }
    }
}
