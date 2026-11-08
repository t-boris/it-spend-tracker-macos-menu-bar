import Foundation

/// What the user told the app about a service. Contains no credentials by construction (DEC-011).
struct ServiceIntro: Sendable, Equatable {
    var serviceName: String
    var accountIdentifier: String
    var note: String
}

/// Builds prompts from non-secret inputs only: the service intro and connector metadata.
enum AssistantPrompts {
    /// Language the assistant should answer in: the app's current UI language (DEC-018).
    static var answerLanguage: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("ru") == true ? "Russian" : "English"
    }

    /// Step-by-step guidance for connecting a service with a built-in connector.
    static func guidance(intro: ServiceIntro, descriptor: ConnectorDescriptor, language: String = answerLanguage) -> String {
        let fields = descriptor.credentialFields.map { field in
            "- \(field.label.key): \(field.help.key)\(field.isOptional ? " (optional)" : "")"
        }.joined(separator: "\n")
        return """
        You are helping a user connect a service to a personal macOS app that tracks their IT spending.
        Answer in \(language). Be concise and practical; use a short numbered list of steps.

        Service named by the user: \(intro.serviceName)
        Account identifier given by the user: \(intro.accountIdentifier.isEmpty ? "(none)" : intro.accountIdentifier)
        User's note: \(intro.note.isEmpty ? "(none)" : intro.note)

        The app has a built-in connector for this service: \(descriptor.displayName).
        Credential needed: \(descriptor.credentialSummary)
        Fields the user will fill in the app's own form:
        \(fields)
        Where to start: \(descriptor.consoleURL.absoluteString)

        Explain which account and role are required and how to obtain each field, step by step.
        For every step give the direct https link to the exact page where it is done.
        Mention common pitfalls (wrong key type, missing permissions).
        Never ask the user to paste a key or secret into this conversation: they enter it only in the app's form.
        """
    }

    /// Research for a service without a built-in connector (DEC-022). Expects one JSON object back.
    static func research(intro: ServiceIntro, language: String = answerLanguage) -> String {
        """
        You are helping a user track spending on a service in a personal macOS app.
        Service named by the user: \(intro.serviceName)
        Account identifier given by the user: \(intro.accountIdentifier.isEmpty ? "(none)" : intro.accountIdentifier)
        User's note (e.g. what they pay): \(intro.note.isEmpty ? "(none)" : intro.note)

        Using web search and the provider's official documentation, find out whether this provider offers
        an HTTP API, authenticated with an API key or token the user can create, that returns any of:
        (a) the user's spend/cost in USD per day, (b) token usage, (c) the list of API keys with name,
        creation, last-used or expiry dates.

        The app can only call HTTPS GET endpoints on a single host, with the secret sent in one header,
        and read JSON. APIs needing POST queries, OAuth flows or request signing cannot be used.

        Reply with ONE JSON object and nothing else, no markdown fence, with this shape:
        {
          "status": "api" or "no_api",
          "explanation": "<in \(language): what you found; which keys or tokens are needed; how the user obtains each one step by step with the direct https link to the page where it is created; which plan or role is needed; or why there is no usable API and what the user can track manually instead>",
          "definition": null or {
            "serviceName": "<name>",
            "baseURL": "https://<api host>",
            "docsURL": "<documentation URL>",
            "consoleURL": "<https URL of the page where the user sees billing or usage, or null>",
            "keysConsoleURL": "<https URL of the page where the user creates and manages API keys, or null>",
            "auth": {"scheme": "bearer" or "header", "headerName": "<header name, only for scheme header>", "credentialField": "<id of the secret field>"},
            "credentialFields": [{"id": "apiKey", "label": "<label in \(language)>", "help": "<where to get it, in \(language), with the direct https link>", "secret": true}],
            "spend": null or {"path": "/path?start={from}&end={to}", "itemsPath": "<dot path to the array of daily items, empty for root>", "datePath": "<field with the date>", "amountPath": "<field with the amount>", "amountUnit": "usd" or "cents"},
            "tokens": null or {"path": "/path?start={month_start}", "itemsPath": "...", "modelPath": "... or null", "keyPath": "... or null", "inputPath": "...", "outputPath": "...", "cachedInputPath": "... or null"},
            "keys": null or {"path": "/path", "itemsPath": "...", "idPath": "...", "namePath": "... or null", "createdPath": "... or null", "lastUsedPath": "... or null", "expiresPath": "... or null"}
          }
        }
        Path placeholders available: {from}, {to}, {month_start} (yyyy-MM-dd), {from_unix}, {to_unix},
        {month_start_unix} (Unix seconds), {from_iso}, {to_iso}, {month_start_iso} (ISO 8601), and
        {field.<id>} for non-secret credential fields. Never put the secret in a path.
        Only include endpoints you verified in the official documentation. If unsure, use "no_api".
        Never ask the user to share a key with you.
        """
    }
}

/// The assistant's answer to a research prompt, parsed as data (never executed).
struct ResearchResult: Decodable, Sendable, Equatable {
    enum Status: String, Decodable, Sendable { case api, noAPI = "no_api" }
    var status: Status
    var explanation: String
    var definition: ConnectorDefinition?

    /// Extracts the first JSON object from the output, tolerating a markdown fence around it.
    static func parse(_ output: String) throws -> ResearchResult {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else {
            throw AssistantError.failed(String(localized: "The assistant did not return a connector description."))
        }
        do {
            let result = try JSONDecoder().decode(ResearchResult.self, from: Data(output[start...end].utf8))
            if result.status == .api && result.definition == nil {
                throw AssistantError.failed(String(localized: "The assistant did not return a connector description."))
            }
            return result
        } catch let error as AssistantError {
            throw error
        } catch {
            throw AssistantError.failed(String(localized: "The assistant's connector description is invalid: \(error.localizedDescription)"))
        }
    }
}
