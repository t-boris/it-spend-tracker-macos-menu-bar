import SwiftUI

/// The state of the assistant CLI and what to do about it. Shared by Settings and the chat, so both give the same
/// guidance when the CLI is missing or signed out (REQ-005, REQ-018).
struct AssistantGuidance: View {
    let status: AssistantStatus
    let backend: AssistantBackend
    /// Settings also points out that services can be added without the assistant.
    var showsManualHint = false

    /// Terminal commands the user has to run, in order. None when the assistant is ready.
    static func commands(for status: AssistantStatus, backend: AssistantBackend) -> [String] {
        switch status {
        case .ready: []
        case .notSignedIn: [backend.signInCommand]
        case .notInstalled: [backend.installCommand, backend.signInCommand]
        }
    }

    var body: some View {
        switch status {
        case .ready(let url):
            Label("Ready: \(url.path)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notSignedIn:
            VStack(alignment: .leading, spacing: 4) {
                Label("\(backend.displayName) is installed but not signed in.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Run in Terminal:").font(.caption)
                commandLines
            }
        case .notInstalled:
            VStack(alignment: .leading, spacing: 4) {
                Label("\(backend.displayName) is not installed.", systemImage: "xmark.circle").foregroundStyle(.orange)
                Text("Install it in Terminal, then sign in:").font(.caption)
                commandLines
                if showsManualHint {
                    Text("Services can still be added manually without the assistant.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var commandLines: some View {
        ForEach(Self.commands(for: status, backend: backend), id: \.self) { command in
            Text(command).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}
