import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-018: when the CLI is missing or signed out, the chat shows the same guidance as Settings. Both use
/// `AssistantGuidance`, so what the user has to run is decided in one place.
@Suite struct AssistantGuidanceTests {
    private let location = URL(filePath: "/usr/local/bin/cli")

    @Test func notInstalledNeedsInstallThenSignIn() {
        for backend in AssistantBackend.allCases {
            #expect(AssistantGuidance.commands(for: .notInstalled, backend: backend) == [backend.installCommand, backend.signInCommand])
        }
    }

    @Test func signedOutNeedsOnlySignIn() {
        for backend in AssistantBackend.allCases {
            #expect(AssistantGuidance.commands(for: .notSignedIn(location), backend: backend) == [backend.signInCommand])
        }
    }

    @Test func readyAssistantNeedsNoCommand() {
        for backend in AssistantBackend.allCases {
            #expect(AssistantGuidance.commands(for: .ready(location), backend: backend).isEmpty)
        }
    }
}
