import Foundation

/// The AI backend used for onboarding (DEC-003, DEC-004): a locally installed, signed-in CLI.
enum AssistantBackend: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        }
    }

    var executableName: String { rawValue }

    var installCommand: String {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex"
        }
    }

    var signInCommand: String {
        switch self {
        case .claude: "claude auth login"
        case .codex: "codex login"
        }
    }

    var statusArguments: [String] {
        switch self {
        case .claude: ["auth", "status"]
        case .codex: ["login", "status"]
        }
    }

    /// Non-interactive invocation reading the prompt from stdin (DEC-011).
    /// `allowWeb` enables only web search/fetch, for researching unknown services (DEC-022).
    func runArguments(workingDirectory: URL, allowWeb: Bool) -> [String] {
        switch self {
        case .claude:
            let tools = allowWeb ? "WebSearch,WebFetch" : ""
            var arguments = ["-p", "--tools", tools,
                             "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                             "--setting-sources", "",
                             "--no-session-persistence", "--output-format", "text"]
            if allowWeb { arguments += ["--allowedTools", "WebSearch", "WebFetch"] }
            return arguments
        case .codex:
            let disabled = ["shell_tool", "unified_exec", "browser_use", "browser_use_external", "computer_use",
                            "in_app_browser", "image_generation", "apps", "plugins", "view_image", "tool_suggest",
                            "skill_search", "code_mode_host", "goals", "multi_agent", "sleep_tool"]
            return ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                    "--sandbox", "read-only", "--color", "never", "-C", workingDirectory.path,
                    "-c", "web_search=\(allowWeb ? "live" : "disabled")"]
                + disabled.flatMap { ["--disable", $0] }
                + ["-"]
        }
    }
}

enum AssistantStatus: Equatable, Sendable {
    case notInstalled
    case notSignedIn(URL)
    case ready(URL)
}

enum AssistantError: LocalizedError, Equatable {
    case notInstalled(AssistantBackend)
    case notSignedIn(AssistantBackend)
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled(let backend):
            String(localized: "\(backend.displayName) is not installed. Install it with: \(backend.installCommand)")
        case .notSignedIn(let backend):
            String(localized: "\(backend.displayName) is not signed in. Run in Terminal: \(backend.signInCommand)")
        case .failed(let message):
            String(localized: "The assistant failed: \(message)")
        case .timedOut:
            String(localized: "The assistant did not answer in time.")
        }
    }
}

/// Finds and runs the CLI in a sandbox: empty temporary working directory, minimal environment
/// (no provider credentials or other variables), prompt via stdin, no tools (DEC-011).
struct AssistantCLI: Sendable {
    let backend: AssistantBackend

    /// GUI apps do not inherit the login shell PATH, so common install locations are searched.
    func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                           "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.yarn/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            directories += versions.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        for directory in directories {
            let path = "\(directory)/\(backend.executableName)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(filePath: path) }
        }
        return nil
    }

    func status() async -> AssistantStatus {
        guard let executable = locate() else { return .notInstalled }
        let result = try? await run(executable: executable, arguments: backend.statusArguments, input: "",
                                    workingDirectory: FileManager.default.temporaryDirectory, timeout: 30)
        return result?.exitCode == 0 ? .ready(executable) : .notSignedIn(executable)
    }

    /// Asks the assistant. The prompt must never contain credential values (REQ-005).
    func ask(_ prompt: String, allowWeb: Bool = false, timeout: TimeInterval = 240) async throws -> String {
        let executable: URL
        switch await status() {
        case .notInstalled: throw AssistantError.notInstalled(backend)
        case .notSignedIn: throw AssistantError.notSignedIn(backend)
        case .ready(let url): executable = url
        }
        let result = try await Self.withSandbox { sandbox in
            try await run(executable: executable,
                          arguments: backend.runArguments(workingDirectory: sandbox, allowWeb: allowWeb),
                          input: prompt, workingDirectory: sandbox, timeout: timeout)
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !output.isEmpty else {
            throw AssistantError.failed(String((result.stderr.isEmpty ? result.stdout : result.stderr).suffix(400)))
        }
        return output
    }

    /// Runs `body` with an empty directory of its own as the CLI's working directory, and removes it afterwards, so the
    /// CLI never starts inside the user's files (DEC-011).
    static func withSandbox<T>(_ body: (URL) async throws -> T) async throws -> T {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "ITSpendTracker-assistant-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        return try await body(sandbox)
    }

    struct ProcessResult: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// Only these variables are passed; everything else (including any secrets) is dropped.
    static func environment(for executable: URL) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
                .joined(separator: ":"),
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "LANG": "en_US.UTF-8",
        ]
        environment["TMPDIR"] = inherited["TMPDIR"]
        return environment
    }

    func run(executable: URL, arguments: [String], input: String, workingDirectory: URL,
             timeout: TimeInterval) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.environment(for: executable)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = OutputCollector()
        stdout.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, error: false) }
        stderr.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, error: true) }

        return try await withCheckedThrowingContinuation { continuation in
            let finished = OnceFlag()
            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                collector.append(stdout.fileHandleForReading.readDataToEndOfFile(), error: false)
                collector.append(stderr.fileHandleForReading.readDataToEndOfFile(), error: true)
                guard finished.set() else { return }
                let (out, err) = collector.strings
                continuation.resume(returning: ProcessResult(exitCode: process.terminationStatus, stdout: out, stderr: err))
            }
            do {
                try process.run()
            } catch {
                guard finished.set() else { return }
                continuation.resume(throwing: AssistantError.failed(error.localizedDescription))
                return
            }
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning, finished.set() else { return }
                process.terminate()
                continuation.resume(throwing: AssistantError.timedOut)
            }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, error: Bool) {
        lock.lock(); defer { lock.unlock() }
        if error { err.append(data) } else { out.append(data) }
    }

    var strings: (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// Returns `true` the first time only.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
