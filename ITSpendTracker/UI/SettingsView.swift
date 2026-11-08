import SwiftUI

/// Assistant backend choice and CLI status (REQ-005).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: AssistantStatus?
    @State private var checking = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Assistant", selection: $model.assistantBackend) {
                    ForEach(AssistantBackend.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: model.assistantBackend) { Task { await check() } }
                statusView
                Button("Check again") { Task { await check() } }.disabled(checking)
            } header: {
                Text("AI assistant")
            } footer: {
                Text("Uses the CLI installed on this Mac with your existing subscription. No AI API key is needed. The assistant never receives your credentials and runs without file or shell access.")
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        do {
                            try LaunchAtLogin.setEnabled(enabled)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                        }
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }))
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
                if !Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
                    Text("Login items work for the installed copy in /Applications (run scripts/install.sh).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Startup")
            }
            Section("Refresh") {
                Text("Data is refreshed every 4 hours while the app runs, on launch and after wake when older than 4 hours, and with the Refresh button.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Settings"))
        .task { await check() }
    }

    @ViewBuilder
    private var statusView: some View {
        if checking {
            HStack { ProgressView().controlSize(.small); Text("Checking…") }
        } else if let status {
            AssistantGuidance(status: status, backend: model.assistantBackend, showsManualHint: true)
        } else {
            HStack { ProgressView().controlSize(.small); Text("Checking…") }
        }
    }

    private func check() async {
        checking = true
        status = await AssistantCLI(backend: model.assistantBackend).status()
        checking = false
    }
}
