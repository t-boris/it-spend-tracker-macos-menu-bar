import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-005 / DEC-011: the assistant CLI starts in an empty directory of its own and sees a minimal environment. These tests run
/// real system programs through the same `run` the assistant uses, so they do not need a CLI to be installed.
@Suite struct AssistantSandboxRuntimeTests {
    private func real(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    @Test func theSandboxIsEmptyUniqueAndRemovedAfterwards() async throws {
        var first: URL?, second: URL?
        try await AssistantCLI.withSandbox { dir in
            first = dir
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
            #expect(dir.path.hasPrefix(FileManager.default.temporaryDirectory.path))
            try await AssistantCLI.withSandbox { second = $0 }
        }
        #expect(first != second)
        #expect(!FileManager.default.fileExists(atPath: try #require(first).path))
        #expect(!FileManager.default.fileExists(atPath: try #require(second).path))
    }

    @Test func theSandboxIsRemovedWhenTheRunFails() async throws {
        struct Boom: Error {}
        var directory: URL?
        await #expect(throws: Boom.self) {
            try await AssistantCLI.withSandbox { dir in directory = dir; throw Boom() }
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(directory).path))
    }

    @Test func theProcessStartsInTheSandboxWhichHoldsNoFiles() async throws {
        let cli = AssistantCLI(backend: .claude)
        try await AssistantCLI.withSandbox { dir in
            let where_ = try await cli.run(executable: URL(filePath: "/bin/pwd"), arguments: [], input: "", workingDirectory: dir, timeout: 10)
            #expect(real(URL(filePath: where_.stdout.trimmingCharacters(in: .whitespacesAndNewlines))) == real(dir))
            let listing = try await cli.run(executable: URL(filePath: "/bin/ls"), arguments: ["-A"], input: "", workingDirectory: dir, timeout: 10)
            #expect(listing.stdout.isEmpty, "nothing of the user's is visible from the working directory")
        }
    }

    @Test func theProcessSeesOnlyTheMinimalEnvironment() async throws {
        setenv("ITS_TEST_SECRET", "must-not-leak", 1)
        setenv("ANTHROPIC_API_KEY", "must-not-leak", 1)
        defer { unsetenv("ITS_TEST_SECRET"); unsetenv("ANTHROPIC_API_KEY") }
        let result = try await AssistantCLI(backend: .claude).run(executable: URL(filePath: "/usr/bin/env"), arguments: [], input: "",
                                                                  workingDirectory: FileManager.default.temporaryDirectory, timeout: 10)
        let names = Set(result.stdout.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        // The shell that /usr/bin/env runs under may add its own bookkeeping variables.
        let allowed: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING"]
        #expect(names.isSubset(of: allowed), "unexpected variables: \(names.subtracting(allowed).sorted())")
        #expect(!result.stdout.contains("must-not-leak"))
    }
}
