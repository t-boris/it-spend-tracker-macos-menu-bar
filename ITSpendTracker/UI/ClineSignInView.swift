import AppKit
import SwiftUI

/// "Sign in with Cline" (DEC-040) as a sheet: opens the browser, shows the code to confirm there and waits for
/// the session. The sign-in belongs to the sheet, so it stops only when the sheet closes. The credentials go
/// straight to `onSignedIn` and are never shown; the sheet closes when it returns.
struct ClineSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let onSignedIn: ([String: String]) throws -> Void

    private enum Phase {
        case starting
        case waiting(ClineAuth.DeviceAuthorization)
        case failed(String)
    }

    @State private var phase: Phase = .starting
    @State private var attempt = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            switch phase {
            case .starting:
                ProgressView().controlSize(.small)
            case .waiting(let authorization):
                Text("Confirm this code on the Cline page that opened in your browser:")
                Text(authorization.userCode)
                    .font(.title2.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for confirmation…").foregroundStyle(.secondary)
                }
                Link("Open the page again", destination: authorization.verificationURL)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                Button("Try again") { phase = .starting; attempt = UUID() }
            }
            Text("Cline has no API keys for account data, so the app signs in to your Cline account. The session is stored only in the macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 400)
        // Cancelled when the sheet closes or a new attempt starts.
        .task(id: attempt) { await signIn() }
    }

    private func signIn() async {
        let auth = ClineAuth(http: URLSessionHTTPClient())
        do {
            let authorization = try await auth.startDeviceAuthorization()
            phase = .waiting(authorization)
            NSWorkspace.shared.open(authorization.verificationURL)
            let credentials = try await auth.completeSignIn(authorization)
            try Task.checkCancellation()
            try onSignedIn(credentials)
            dismiss()
        } catch {
            // Cancelling (sheet closed) may surface as CancellationError or as URLError.cancelled.
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Signing in again after the Cline session ended (DEC-040). The same account keeps its history;
/// a different account is refused, so two accounts' usage is never mixed in one service.
struct ClineReauthForm: View {
    @Environment(AppModel.self) private var model
    let service: TrackedService

    var body: some View {
        ClineSignInSheet(title: "Sign in to Cline") { session in
            let stored = try model.store.credentials(for: service)
            if let previous = stored[ClineAuth.Field.userID], previous != session[ClineAuth.Field.userID] {
                throw ClineAuth.AuthError.differentAccount(stored[ClineAuth.Field.email] ?? previous)
            }
            try model.store.replaceSessionCredentials(service, session)
            // Started independently: the sheet closes right away and must not cancel the refresh.
            Task { await model.refresh.refresh(serviceID: service.id) }
        }
    }
}
