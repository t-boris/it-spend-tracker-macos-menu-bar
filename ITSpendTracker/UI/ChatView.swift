import SwiftUI

/// Spending chat with the local assistant (REQ-018, DEC-038).
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var status: AssistantStatus?

    var body: some View {
        let chat = model.chat
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty {
                            intro
                        }
                        ForEach(chat.messages) { message in
                            bubble(message).id(message.id)
                        }
                        if chat.isAnswering {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("\(model.assistantBackend.displayName) is thinking…").foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                        if let error = chat.error {
                            Label(error, systemImage: "exclamationmark.bubble").foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.messages.count) {
                    withAnimation { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your spending…", text: $question, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button("Ask") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(chat.isAnswering || question.trimmingCharacters(in: .whitespaces).isEmpty || !assistantReady)
                if !chat.messages.isEmpty {
                    Button("Clear") { chat.clear() }.disabled(chat.isAnswering)
                }
            }
            .padding(12)
            // Same guidance as in Settings (REQ-018): what is missing and the commands to fix it.
            if let status, !assistantReady {
                AssistantGuidance(status: status, backend: model.assistantBackend)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .task(id: model.assistantBackend) { status = await AssistantCLI(backend: model.assistantBackend).status() }
    }

    private var assistantReady: Bool {
        if case .ready = status { return true }
        return false
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about your spending").font(.headline)
            Text("The assistant sees your services, monthly spend, breakdowns, keys and tags — never your credentials. Examples:")
                .foregroundStyle(.secondary)
            ForEach(["Why did my spending grow this month?", "Which keys were not used this month?", "What could I cancel?",
                     "How much do I pay for AI services in total?"], id: \.self) { example in
                Button {
                    question = String(localized: String.LocalizationValue(example))
                } label: {
                    Text(LocalizedStringKey(example)).font(.callout)
                }
                .buttonStyle(.link)
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            Text(AssistantAnswer.linkified(message.text))
                .textSelection(.enabled)
                .padding(10)
                .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10))
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    private func send() {
        // Return in the field must not bypass the disabled Ask button.
        guard assistantReady, !model.chat.isAnswering, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let text = question
        question = ""
        let snapshot = SpendingSnapshot.json(SpendingSnapshot.build(services: model.store.services, today: model.today))
        Task { await model.chat.ask(text, snapshot: snapshot, backend: model.assistantBackend, language: AssistantPrompts.answerLanguage) }
    }
}
