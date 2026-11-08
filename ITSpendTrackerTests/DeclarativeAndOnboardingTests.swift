import Foundation
import SwiftData
import Testing
@testable import ITSpendTracker

private func definition(baseURL: String = "https://api.example-ai.test", spendPath: String = "/v1/usage?from={from}&to={to}",
                        auth: ConnectorDefinition.Auth = .init(scheme: .header, headerName: "X-Api-Key", credentialField: "apiKey"))
    -> ConnectorDefinition {
    ConnectorDefinition(
        serviceName: "XDataAI", baseURL: baseURL, docsURL: "https://docs.example-ai.test", auth: auth,
        credentialFields: [.init(id: "apiKey", label: "API key", help: nil, secret: true),
                           .init(id: "org", label: "Org", help: nil, secret: false)],
        spend: .init(path: spendPath, itemsPath: "data.days", datePath: "date", amountPath: "cost", amountUnit: .cents),
        tokens: .init(path: "/v1/tokens?since={month_start}", itemsPath: "", modelPath: "model", keyPath: nil,
                      inputPath: "in", outputPath: "out", cachedInputPath: nil),
        keys: .init(path: "/v1/keys?org={field.org}", itemsPath: "keys", idPath: "id", namePath: "name",
                    createdPath: nil, lastUsedPath: "last_used", expiresPath: nil))
}

@Suite struct DeclarativeConnectorTests {
    @Test func validDefinitionHasNoProblems() {
        #expect(definition().validationProblems().isEmpty)
    }

    @Test func rejectsUnsafeDefinitions() {
        #expect(!definition(baseURL: "http://api.example-ai.test").validationProblems().isEmpty)
        #expect(!definition(baseURL: "https://user:pw@api.example-ai.test").validationProblems().isEmpty)
        #expect(!definition(spendPath: "//evil.example/steal").validationProblems().isEmpty)
        #expect(!definition(spendPath: "/v1/usage?key={field.apiKey}").validationProblems().isEmpty)
        #expect(!definition(spendPath: "/v1/usage?x={env.HOME}").validationProblems().isEmpty)
        #expect(!definition(auth: .init(scheme: .bearer, headerName: nil, credentialField: "org")).validationProblems().isEmpty)
        #expect(!definition(auth: .init(scheme: .header, headerName: "Bad Header\n", credentialField: "apiKey")).validationProblems().isEmpty)
    }

    @Test func resolvedURLsStayOnHost() {
        let def = definition()
        #expect(def.url(for: "/v1/x?q={from}", values: ["from": "a&b=c"])?.absoluteString == "https://api.example-ai.test/v1/x?q=a%26b%3Dc")
        #expect(def.url(for: "@evil.com/x", values: [:]) == nil)
    }

    @Test func fetchesSpendTokensAndKeysWithSecretOnlyInHeader() async throws {
        let http = StubHTTP()
        http.on("/v1/usage", #"{"data":{"days":[{"date":"2026-09-02","cost":250},{"date":1788307200,"cost":"50"}]}}"#)
        http.on("/v1/tokens", #"[{"model":"x-1","in":10,"out":3},{"model":"x-1","in":5,"out":1}]"#)
        http.on("/v1/keys", #"{"keys":[{"id":"k1","name":"Main","last_used":"2026-09-20T10:00:00Z"}]}"#)
        let request = FetchRequest(credentials: ["apiKey": "secret-123", "org": "acme"],
                                   from: Day(year: 2026, month: 9, day: 1), now: Date(timeIntervalSince1970: 1_790_726_400))
        let snapshot = try await DeclarativeConnector(definition: definition(), http: http).fetch(request)
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 2)] == 3)
        #expect(snapshot.tokenUsage == [TokenUsageRow(keyExternalID: nil, model: "x-1", inputTokens: 15, cachedInputTokens: nil, outputTokens: 4)])
        #expect(snapshot.keys?.first?.name == "Main")
        #expect(snapshot.keys?.first?.lastUsedAt != nil)
        for sent in http.allRequests {
            #expect(sent.httpMethod == "GET")
            #expect(sent.url?.host() == "api.example-ai.test")
            #expect(sent.url?.absoluteString.contains("secret-123") == false)
            #expect(sent.value(forHTTPHeaderField: "X-Api-Key") == "secret-123")
        }
        #expect(http.allRequests.contains { $0.url?.query()?.contains("org=acme") == true })
    }

    @Test func researchResultParsing() throws {
        let data = try JSONEncoder().encode(definition())
        let output = "Here you go:\n```json\n{\"status\":\"api\",\"explanation\":\"Create a key\",\"definition\":\(String(decoding: data, as: UTF8.self))}\n```"
        let result = try ResearchResult.parse(output)
        #expect(result.status == .api)
        #expect(result.definition == definition())
        #expect(try ResearchResult.parse(#"{"status":"no_api","explanation":"none","definition":null}"#).status == .noAPI)
        #expect(throws: AssistantError.self) { try ResearchResult.parse("no json here") }
        #expect(throws: AssistantError.self) { try ResearchResult.parse(#"{"status":"api","explanation":"x","definition":null}"#) }
    }
}

@Suite struct AssistantSandboxTests {
    @Test func claudeRunsWithoutToolsSettingsOrMCP() {
        let args = AssistantBackend.claude.runArguments(workingDirectory: URL(filePath: "/tmp/x"), allowWeb: false)
        #expect(args.starts(with: ["-p", "--tools", ""]))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--no-session-persistence"))
        let settings = args.firstIndex(of: "--setting-sources").map { args[$0 + 1] }
        #expect(settings == "")
    }

    @Test func claudeResearchAllowsOnlyWebTools() {
        let args = AssistantBackend.claude.runArguments(workingDirectory: URL(filePath: "/tmp/x"), allowWeb: true)
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "WebSearch,WebFetch")
    }

    @Test func codexRunsReadOnlyWithShellDisabled() {
        let args = AssistantBackend.codex.runArguments(workingDirectory: URL(filePath: "/tmp/x"), allowWeb: false)
        #expect(args[args.firstIndex(of: "--sandbox")! + 1] == "read-only")
        #expect(args.contains("--ignore-user-config"))
        #expect(args.contains("web_search=disabled"))
        for feature in ["shell_tool", "unified_exec", "code_mode_host", "computer_use", "browser_use", "plugins"] {
            #expect(args.contains(feature), "\(feature) must be disabled")
        }
        #expect(args.last == "-")
    }

    @Test func environmentContainsNoInheritedSecrets() {
        setenv("OPENAI_API_KEY", "sk-should-not-leak", 1)
        defer { unsetenv("OPENAI_API_KEY") }
        let environment = AssistantCLI.environment(for: URL(filePath: "/opt/homebrew/bin/claude"))
        #expect(Set(environment.keys).isSubset(of: ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR"]))
        #expect(!environment.values.contains("sk-should-not-leak"))
    }

    @Test func promptsCarryOnlyNonSecretInput() {
        let intro = ServiceIntro(serviceName: "OpenAI", accountIdentifier: "me@example.com", note: "API usage")
        let guidance = AssistantPrompts.guidance(intro: intro, descriptor: OpenAIConnector.descriptor, language: "Russian")
        #expect(guidance.contains("OpenAI"))
        #expect(guidance.contains("me@example.com"))
        #expect(guidance.contains("Answer in Russian"))
        #expect(guidance.contains("Never ask the user to paste a key"))
        let research = AssistantPrompts.research(intro: intro, language: "English")
        #expect(research.contains("Never put the secret in a path"))
    }

    @Test func assistantLinksAreClickable() {
        let text = AssistantAnswer.linkified("Откройте https://platform.openai.com/settings/organization/admin-keys и создайте ключ; см. [доку](https://docs.x.ai).")
        let links = text.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links.contains("https://platform.openai.com/settings/organization/admin-keys"))
        #expect(links.contains("https://docs.x.ai"))
        #expect(AssistantAnswer.linkified("run file:///etc/passwd").runs.allSatisfy { $0.link == nil })
    }

    @Test func everyConnectorHasConsoleLinks() {
        for id in ConnectorID.allCases {
            #expect(id.billingConsoleURL.scheme == "https")
            #expect(id.keysConsoleURL.scheme == "https")
        }
    }

    @Test func connectorMatching() {
        #expect(ConnectorID.match(serviceName: "OpenAI") == .openAI)
        #expect(ConnectorID.match(serviceName: "Open AI API") == .openAI)
        #expect(ConnectorID.match(serviceName: "Firebase") == .googleCloud)
        #expect(ConnectorID.match(serviceName: "vercel.com") == .vercel)
        #expect(ConnectorID.match(serviceName: "ChatGPT Plus") == nil)
        #expect(ConnectorID.match(serviceName: "Neon") == .neon)
        #expect(ConnectorID.match(serviceName: "Fly.io") == nil)
        #expect(ConnectorID.match(serviceName: "XDataAI") == nil)
    }
}

@Suite @MainActor struct SpendingChatTests {
    @Test func snapshotCarriesDataButNoSecrets() throws {
        let store = SpendStore(container: try Persistence.makeContainer(inMemory: true),
                               keychain: KeychainStore(serviceName: "app.itspendtracker.ITSpendTracker.tests.\(UUID().uuidString)"))
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "me", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "sk-admin-SECRET"])
        try store.apply(ConnectorSnapshot(dailyCosts: [Day(year: 2026, month: 9, day: 2): 7.25], coveredFrom: Day(year: 2025, month: 11, day: 1),
                                          keys: [ProviderKey(externalID: "k1", name: "ci-bot", hint: "Main · sk-proj-…a1b2", currentMonthCost: 4)],
                                          tokenUsage: nil,
                                          breakdown: [BreakdownRow(month: Month(year: 2026, month: 9), dimension: .lineItem, label: "gpt-6, output", amount: 6.2)],
                                          breakdownFrom: Month(year: 2026, month: 9)), to: service, at: .now)
        try store.addSubscription(service, name: "ChatGPT Pro", period: .monthly, start: Day(year: 2025, month: 12, day: 3), end: nil, amount: 100)
        try store.setTags(["bots"], forKey: "k1", of: service)
        let json = SpendingSnapshot.json(SpendingSnapshot.build(services: store.services, today: Day(year: 2026, month: 9, day: 30)))
        #expect(json.contains("\"ci-bot\""))
        #expect(json.contains("\"gpt-6, output\""))
        #expect(json.contains("\"ChatGPT Pro\""))
        #expect(json.contains("\"bots\""))
        #expect(json.contains("\"2026-09\":\"107.25\""))     // usage + subscription, rounded to cents
        #expect(json.contains("\"usd\":\"6.2\"}"))           // no binary-float noise
        #expect(json.contains("\"2025-11\":\"0\""))          // covered month without usage is a real zero
        #expect(json.contains("\"2025-10\":\"no data\""))   // before coverage: unknown, never zero
        #expect(!json.contains("SECRET"))
        #expect(!json.contains("sk-proj"))                       // key hints are never sent
        #expect(!json.contains("a1b2"))
        try store.remove(service)
    }

    @Test func promptIncludesEarlierTurnsAndLanguage() {
        let history = [ChatMessage(role: .user, text: "Why did GitHub grow?"), ChatMessage(role: .assistant, text: "Actions in Example-Org.")]
        let prompt = SpendingChat.prompt(snapshot: "{}", history: history, question: "Which repo?", language: "Russian")
        #expect(prompt.contains("Answer in Russian"))
        #expect(prompt.contains("User: Why did GitHub grow?"))
        #expect(prompt.contains("Assistant: Actions in Example-Org."))
        #expect(prompt.hasSuffix("User: Which repo?\nAssistant:"))
    }
}

@Suite(.serialized) @MainActor struct StoreTests {
    let keychain = KeychainStore(serviceName: "app.itspendtracker.ITSpendTracker.tests.\(UUID().uuidString)")

    private func makeStore() throws -> SpendStore {
        SpendStore(container: try Persistence.makeContainer(inMemory: true), keychain: keychain)
    }

    @Test func keychainRoundTripAndDelete() throws {
        let id = UUID()
        try keychain.save(["adminKey": "sk-1"], for: id)
        try keychain.save(["adminKey": "sk-2"], for: id)
        #expect(try keychain.load(for: id) == ["adminKey": "sk-2"])
        try keychain.delete(for: id)
        #expect(try keychain.load(for: id) == nil)
    }

    @Test func credentialsAreNotStoredInDatabase() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "me", connector: .openAI, definition: nil, credentials: ["adminKey": "sk-admin-secret"])
        #expect(try store.credentials(for: service) == ["adminKey": "sk-admin-secret"])
        let mirror = Mirror(reflecting: service).children.map { String(describing: $0.value) }.joined()
        #expect(!mirror.contains("sk-admin-secret"))
        try store.remove(service)
    }

    @Test func applyingSnapshotReplacesCoveredDaysAndKeepsOlderOnes() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "Vercel", accountIdentifier: "", connector: .vercel, definition: nil, credentials: ["token": "t"])
        let now = Date(timeIntervalSince1970: 1_790_726_400)
        try store.apply(ConnectorSnapshot(dailyCosts: [Day(year: 2025, month: 10, day: 5): 7, Day(year: 2026, month: 9, day: 1): 1],
                                          coveredFrom: Day(year: 2025, month: 9, day: 1), keys: [], tokenUsage: nil),
                        to: service, at: now)
        try store.apply(ConnectorSnapshot(dailyCosts: [Day(year: 2026, month: 9, day: 1): 4],
                                          coveredFrom: Day(year: 2026, month: 8, day: 1), keys: nil, tokenUsage: nil),
                        to: service, at: now)
        let ledger = service.ledger
        #expect(ledger.spend(in: Month(year: 2025, month: 10)) == .value(7))
        #expect(ledger.spend(in: Month(year: 2026, month: 9)) == .value(4))
        #expect(ledger.spend(in: Month(year: 2025, month: 8)) == .noData)
        #expect(service.hasKeyData)
        #expect(service.lastSuccessfulRefresh == now)
        try store.remove(service)
    }

    @Test func keyDetailsAndMonthlyCostsAreStored() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "k"])
        let dec = Month(year: 2025, month: 12), sep = Month(year: 2026, month: 9)
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: dec.firstDay,
                                          keys: [ProviderKey(externalID: "k1", name: "Bot", currentMonthCost: 4,
                                                             details: [KeyDetail(kind: .owner, value: "Alex")])],
                                          tokenUsage: nil,
                                          keyMonthlyCosts: [KeyMonthCost(keyExternalID: "k1", month: dec, amount: 1),
                                                            KeyMonthCost(keyExternalID: "k1", month: sep, amount: 4)],
                                          keyCostsFrom: dec), to: service, at: .now)
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: sep.firstDay, keys: nil, tokenUsage: nil,
                                          keyMonthlyCosts: [KeyMonthCost(keyExternalID: "k1", month: sep, amount: 5)],
                                          keyCostsFrom: sep), to: service, at: .now)
        #expect(service.keys.first?.details == [KeyDetail(kind: .owner, value: "Alex")])
        #expect(Set(service.keyCosts.map { "\($0.monthIndex):\($0.amount)" }) == ["\(dec.index):1", "\(sep.index):5"])
        #expect(service.keyCostsStartMonthIndex == dec.index)
        try store.remove(service)
        #expect(try store.context.fetchCount(FetchDescriptor<KeyCostRecord>()) == 0)
    }

    @Test func connectionImportCreatesServiceAndDeletesFile() throws {
        let store = try makeStore()
        let url = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString).json")
        try Data(#"{"name":"Google Cloud","connector":"gcp","accountIdentifier":"owner@example.com","credentials":{"serviceAccountJSON":"{}","dataset":"p.billing_export","unknown":"x"}}"#.utf8).write(to: url)
        let service = try ConnectionImport.run(path: url.path, store: store)
        #expect(service.connector == .googleCloud)
        #expect(try store.credentials(for: service) == ["serviceAccountJSON": "{}", "dataset": "p.billing_export"])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // A second import with the same connector and name updates the service instead of duplicating it.
        try Data(#"{"name":"Google Cloud","connector":"gcp","credentials":{"keyProjects":"example-project"}}"#.utf8).write(to: url)
        let updated = try ConnectionImport.run(path: url.path, store: store)
        #expect(updated.id == service.id)
        #expect(store.services.count == 1)
        #expect(try store.credentials(for: service) == ["serviceAccountJSON": "{}", "dataset": "p.billing_export", "keyProjects": "example-project"])
        try store.remove(service)
    }

    @Test func connectionImportKeepsSignInSession() throws {
        let store = try makeStore()
        let url = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString).json")
        try Data(#"{"name":"Cline","connector":"cline","credentials":{"accessToken":"a","refreshToken":"r","expiresAt":"2026-10-01T13:00:00Z","userId":"usr-1","email":"me@example.com","unknown":"x"}}"#.utf8).write(to: url)
        let service = try ConnectionImport.run(path: url.path, store: store)
        #expect(try store.credentials(for: service) == ["accessToken": "a", "refreshToken": "r", "expiresAt": "2026-10-01T13:00:00Z",
                                                         "userId": "usr-1", "email": "me@example.com"])
        try store.remove(service)
    }

    @Test func connectionImportCreatesManualServiceWithLinkAndPaymentsOnce() throws {
        let store = try makeStore()
        let url = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString).json")
        let file = #"{"name":"Fly.io (billing@example.org)","accountIdentifier":"billing@example.org","consoleLink":"https://fly.io/dashboard/example-org/billing","payments":[{"date":"2026-09-30","amount":4.25,"label":"Invoice A"},{"date":"2026-09-30","amount":"1.75","label":"Invoice B"}]}"#
        try Data(file.utf8).write(to: url)
        let service = try ConnectionImport.run(path: url.path, store: store)
        #expect(!service.isConnected)
        #expect(service.consoleLinkURL?.absoluteString == "https://fly.io/dashboard/example-org/billing")
        #expect(service.accountIdentifier == "billing@example.org")
        #expect(service.creditPurchases.count == 2)
        #expect(service.subscriptionRecords.isEmpty && service.balanceSnapshotAmount == nil)
        #expect(service.ledger.spend(in: Month(year: 2026, month: 9)) == .value(Decimal(string: "6.00")!))
        #expect(service.ledger.spend(in: Month(year: 2026, month: 10)) == .value(0))
        // The same file again changes nothing.
        try Data(file.utf8).write(to: url)
        let again = try ConnectionImport.run(path: url.path, store: store)
        #expect(again.id == service.id && store.services.count == 1 && again.creditPurchases.count == 2)
        // Bad link or date is rejected and creates nothing.
        for bad in [#"{"name":"X","consoleLink":"http://x.example"}"#, #"{"name":"Y","payments":[{"date":"30.09.2026","amount":1}]}"#] {
            try Data(bad.utf8).write(to: url)
            #expect(throws: (any Error).self) { _ = try ConnectionImport.run(path: url.path, store: store) }
        }
        #expect(store.services.count == 1)
    }

    @Test func hiddenNotesPersistAcrossRefreshes() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "GitHub", accountIdentifier: "", connector: .gitHub, definition: nil,
                                                    credentials: ["token": "t", "username": "octocat"])
        let note = ProviderNote(id: "github.org.x", kind: .info, text: "no billing data")
        let snapshot = ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1), keys: nil, tokenUsage: nil,
                                         notes: [note])
        try store.apply(snapshot, to: service, at: .now)
        #expect(service.providerNotes == [note])
        try store.setNoteHidden(note.id, hidden: true, in: service)
        try store.apply(snapshot, to: service, at: .now)
        #expect(service.hiddenNoteIDs == ["github.org.x"])
        try store.setNoteHidden(note.id, hidden: false, in: service)
        #expect(service.hiddenNoteIDs.isEmpty)
        try store.remove(service)
    }

    @Test func updatingCredentialsTriggersFullBackfill() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "GitHub", accountIdentifier: "", connector: .gitHub, definition: nil,
                                                    credentials: ["token": "old", "username": "octocat"])
        try store.apply(ConnectorSnapshot(dailyCosts: [Day(year: 2026, month: 9, day: 1): 5], coveredFrom: Day(year: 2025, month: 10, day: 1),
                                          keys: nil, tokenUsage: nil, breakdown: [], breakdownFrom: Month(year: 2025, month: 10)),
                        to: service, at: .now)
        #expect(!service.needsFullBackfill)
        try store.updateCredentials(service, ["token": "new", "username": "octocat"])
        #expect(service.needsFullBackfill)
        #expect(try store.credentials(for: service)["token"] == "new")
        try store.remove(service)
    }

    @Test func existingServiceWithoutBreakdownNeedsOneFullBackfill() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "k"])
        #expect(service.needsFullBackfill) // no history yet
        service.coverageStartKey = Day(year: 2025, month: 9, day: 1).key // connected before breakdowns existed
        #expect(service.needsFullBackfill)
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 8, day: 1), keys: nil, tokenUsage: nil,
                                          breakdown: [], breakdownFrom: Month(year: 2026, month: 8)), to: service, at: .now)
        #expect(service.needsFullBackfill) // a routine refresh does not count
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2025, month: 9, day: 1), keys: nil, tokenUsage: nil,
                                          breakdown: [], breakdownFrom: Month(year: 2025, month: 9),
                                          keyMonthlyCosts: [], keyCostsFrom: Month(year: 2025, month: 12)), to: service, at: .now)
        #expect(!service.needsFullBackfill)
        try store.remove(service)
    }

    @Test func breakdownRowsReplaceRefreshedMonthsOnly() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "k"])
        let aug = Month(year: 2026, month: 8), sep = Month(year: 2026, month: 9)
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: aug.firstDay, keys: nil, tokenUsage: nil,
                                          breakdown: [BreakdownRow(month: aug, dimension: .lineItem, label: "gpt-5, input", amount: 3),
                                                      BreakdownRow(month: sep, dimension: .lineItem, label: "gpt-5, input", amount: 1)],
                                          breakdownFrom: aug, keyMonthlyCosts: [], keyCostsFrom: sep), to: service, at: .now)
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: sep.firstDay, keys: nil, tokenUsage: nil,
                                          breakdown: [BreakdownRow(month: sep, dimension: .project, label: "Example", amount: 2)],
                                          breakdownFrom: sep), to: service, at: .now)
        #expect(service.breakdown.filter { $0.monthIndex == aug.index }.map(\.amount) == [3])
        #expect(service.breakdown.filter { $0.monthIndex == sep.index }.map(\.label) == ["Example"])
        #expect(service.breakdownStartMonthIndex == aug.index)
        #expect(service.breakdownBackfilled) // the first fetch started at the earliest stored day
        #expect(!service.needsFullBackfill)
        try store.remove(service)
        #expect(try store.context.fetchCount(FetchDescriptor<BreakdownRecord>()) == 0)
    }

    @Test func unavailableSpendShowsNoDataAndKeepsKeys() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "Vercel", accountIdentifier: "", connector: .vercel, definition: nil,
                                                    credentials: ["token": "t"])
        // An earlier refresh stored an (assumed) zero spend…
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2025, month: 9, day: 1), keys: nil, tokenUsage: nil),
                        to: service, at: .now)
        #expect(service.ledger.spend(in: Month(year: 2026, month: 9)) == .value(0))
        // …which is dropped once the provider says it cannot report spend.
        try store.apply(ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2025, month: 9, day: 1),
                                          keys: [ProviderKey(externalID: "t1", name: "CI")], tokenUsage: nil,
                                          spendUnavailableReason: "no billing data"), to: service, at: .now)
        #expect(service.ledger.spend(in: Month(year: 2026, month: 9)) == .noData)
        #expect(service.keys.map(\.name) == ["CI"])
        #expect(service.spendUnavailableReason == "no billing data")
        #expect(service.lastRefreshError == nil)
        try store.addSubscription(service, name: "Vercel Pro", period: .monthly, start: Day(year: 2026, month: 1, day: 5), end: nil, amount: 20)
        #expect(service.ledger.spend(in: Month(year: 2026, month: 9)) == .value(20))
        try store.remove(service)
    }

    @Test func failedRefreshKeepsData() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "Vercel", accountIdentifier: "", connector: .vercel, definition: nil, credentials: ["token": "t"])
        try store.apply(ConnectorSnapshot(dailyCosts: [Day(year: 2026, month: 9, day: 1): 4],
                                          coveredFrom: Day(year: 2026, month: 9, day: 1), keys: nil, tokenUsage: nil),
                        to: service, at: .now)
        store.recordRefreshFailure(service, message: "HTTP 500")
        #expect(service.lastRefreshError == "HTTP 500")
        #expect(service.ledger.spend(in: Month(year: 2026, month: 9)) == .value(4))
        try store.remove(service)
    }

    @Test func removingServiceDeletesEverything() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil, credentials: ["adminKey": "k"])
        try store.apply(ConnectorSnapshot(dailyCosts: [Day(year: 2026, month: 9, day: 1): 4],
                                          coveredFrom: Day(year: 2026, month: 9, day: 1),
                                          keys: [ProviderKey(externalID: "k1", name: "Key")],
                                          tokenUsage: [TokenUsageRow(keyExternalID: "k1", model: "m", inputTokens: 1, outputTokens: 1)]),
                        to: service, at: .now)
        try store.addCreditPurchase(service, day: Day(year: 2026, month: 9, day: 2), amount: 10, volume: "")
        let id = service.id
        try store.remove(service)
        #expect(try keychain.load(for: id) == nil)
        #expect(store.services.isEmpty)
        for count in [try store.context.fetchCount(FetchDescriptor<DailyCost>()),
                      try store.context.fetchCount(FetchDescriptor<KeyRecord>()),
                      try store.context.fetchCount(FetchDescriptor<TokenUsageRecord>()),
                      try store.context.fetchCount(FetchDescriptor<CreditPurchaseRecord>())] {
            #expect(count == 0)
        }
    }

    @Test func keyTagsSurviveRefreshAndFeedTagTotals() throws {
        let store = try makeStore()
        let service = try store.addConnectedService(name: "OpenAI", accountIdentifier: "", connector: .openAI, definition: nil,
                                                    credentials: ["adminKey": "k"])
        let snapshot = ConnectorSnapshot(dailyCosts: [:], coveredFrom: Day(year: 2026, month: 9, day: 1),
                                         keys: [ProviderKey(externalID: "k1", name: "Bot", currentMonthCost: 7),
                                                ProviderKey(externalID: "k2", name: "Scripts", currentMonthCost: 3)],
                                         tokenUsage: nil)
        try store.apply(snapshot, to: service, at: .now)
        try store.setTags([" client X ", "bot", "Client x"], forKey: "k1", of: service)
        try store.setTags(["client X"], forKey: "k2", of: service)
        try store.apply(snapshot, to: service, at: .now) // refresh replaces key records
        #expect(service.tags(forKey: "k1") == ["client X", "bot"])
        #expect(store.allTags == ["bot", "client X"])
        let keys = service.keys.map { TagTotal.TaggedKey(serviceName: service.name, keyName: $0.name, cost: $0.currentMonthCost,
                                                          tags: service.tags(forKey: $0.externalID)) }
        let totals = TagTotal.compute(keys)
        #expect(totals.first?.tag == "client X")
        #expect(totals.first?.total == 10)
        try store.setTags([], forKey: "k2", of: service)
        #expect(service.tags(forKey: "k2").isEmpty)
        try store.remove(service)
        #expect(try store.context.fetchCount(FetchDescriptor<KeyTagRecord>()) == 0)
    }

    @Test func manualSubscriptionWithPriceHistory() throws {
        let store = try makeStore()
        let service = try store.addManualService(name: "ChatGPT Plus")
        let record = try store.addSubscription(service, name: "Plus", period: .monthly, start: Day(year: 2026, month: 1, day: 15),
                                               end: nil, amount: 20)
        try store.changePrice(record, amount: 22, effectiveFrom: Day(year: 2026, month: 6, day: 1))
        #expect(service.ledger.spend(in: Month(year: 2026, month: 5)) == .value(20))
        #expect(service.ledger.spend(in: Month(year: 2026, month: 6)) == .value(22))
        try store.updateSubscription(record, name: "Plus", period: .monthly, start: Day(year: 2026, month: 1, day: 15),
                                     end: Day(year: 2026, month: 7, day: 1))
        #expect(service.ledger.spend(in: Month(year: 2026, month: 8)) == .value(0))
        try store.addSubscription(service, name: "Seats", period: .yearly, start: Day(year: 2026, month: 3, day: 1), end: nil, amount: 240)
        #expect(service.ledger.spend(in: Month(year: 2026, month: 3)) == .value(260))
        try store.deleteSubscription(record, from: service)
        #expect(service.ledger.spend(in: Month(year: 2026, month: 5)) == .value(0))
        #expect(try store.context.fetchCount(FetchDescriptor<SubscriptionPriceRecord>()) == 1)
        try store.remove(service)
    }
}

@Suite struct LocalizationTests {
    /// Every string in the catalog has a Russian translation (DEC-018).
    @Test func catalogHasRussianForEveryKey() throws {
        let catalogURL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ITSpendTracker/Resources/Localizable.xcstrings")
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        #expect(strings.count > 100)
        let missing = strings.filter { _, entry in
            let ru = (entry["localizations"] as? [String: Any])?["ru"] as? [String: Any]
            let unit = ru?["stringUnit"] as? [String: String]
            return unit?["state"] != "translated" || (unit?["value"] ?? "").isEmpty
        }.keys.sorted()
        #expect(missing.isEmpty, "Missing Russian translations: \(missing)")
    }

    @Test func russianTableIsCompiledIntoTheApp() throws {
        let url = try #require(Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                                               localization: "ru"))
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
        #expect(table["no data"] == "нет данных")
        #expect(table["Refresh"] == "Обновить")
    }
}
