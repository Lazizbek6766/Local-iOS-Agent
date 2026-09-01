import Foundation
import Testing
@testable import LocalIOSAgent

@Suite("Git client", .serialized)
struct GitClientTests {
    @Test("Separates pre-existing changes from files touched by the agent")
    func classifiesChangesSinceSnapshot() async throws {
        let repository = try temporaryDirectory(named: "Project With Spaces")
        defer { try? FileManager.default.removeItem(at: repository) }

        try await initializeRepository(at: repository)
        try write("original\n", to: repository.appendingPathComponent("Existing.swift"))
        try write("remove me\n", to: repository.appendingPathComponent("DeleteMe.swift"))
        try await git(["add", "--", "Existing.swift", "DeleteMe.swift"], at: repository)
        try await commit(at: repository, message: "Initial")

        try write("original\nuser change\n", to: repository.appendingPathComponent("Existing.swift"))
        try write("user file\n", to: repository.appendingPathComponent("Before.txt"))

        let client = GitClient(runner: ProcessRunner())
        let baseline = try await client.captureSnapshot(at: repository)

        try write(
            "original\nuser change\nagent change\n",
            to: repository.appendingPathComponent("Existing.swift")
        )
        try write("agent file\n", to: repository.appendingPathComponent("Agent File.swift"))
        try FileManager.default.removeItem(at: repository.appendingPathComponent("DeleteMe.swift"))

        let report = try await client.changes(at: repository, since: baseline)
        let changes = Dictionary(uniqueKeysWithValues: report.changes.map { ($0.path, $0) })

        #expect(changes["Before.txt"]?.origin == .preExisting)
        #expect(changes["Existing.swift"]?.origin == .agentModifiedPreExisting)
        #expect(changes["Existing.swift"]?.kind == .modified)
        #expect(changes["Agent File.swift"]?.origin == .agent)
        #expect(changes["Agent File.swift"]?.kind == .added)
        #expect(changes["DeleteMe.swift"]?.origin == .agent)
        #expect(changes["DeleteMe.swift"]?.kind == .deleted)
        #expect(changes["Existing.swift"]?.statistics.additions == 2)
        #expect(changes["DeleteMe.swift"]?.statistics.deletions == 1)
        #expect(report.agentChangeCount == 3)
        #expect(report.preExistingChangeCount == 1)
    }

    @Test("Produces text diffs for tracked and untracked files")
    func producesDiffPreview() async throws {
        let repository = try temporaryDirectory(named: "Diff Preview")
        defer { try? FileManager.default.removeItem(at: repository) }

        try await initializeRepository(at: repository)
        try write("before\n", to: repository.appendingPathComponent("Tracked.swift"))
        try await git(["add", "--", "Tracked.swift"], at: repository)
        try await commit(at: repository, message: "Initial")

        let client = GitClient(runner: ProcessRunner())
        let baseline = try await client.captureSnapshot(at: repository)
        try write("before\nafter\n", to: repository.appendingPathComponent("Tracked.swift"))
        try write("new value\n", to: repository.appendingPathComponent("New File.swift"))

        let report = try await client.changes(at: repository, since: baseline)
        let tracked = try #require(report.changes.first { $0.path == "Tracked.swift" })
        let untracked = try #require(report.changes.first { $0.path == "New File.swift" })
        let trackedDiff = try await client.diff(
            for: tracked,
            in: report.repositoryRoot,
            outputLimit: 262_144
        )
        let untrackedDiff = try await client.diff(
            for: untracked,
            in: report.repositoryRoot,
            outputLimit: 262_144
        )

        #expect(trackedDiff.content.contains("+after"))
        #expect(untrackedDiff.content.contains("+new value"))
        #expect(!trackedDiff.wasTruncated)
        #expect(!untrackedDiff.wasTruncated)
    }

    @Test("Treats shell metacharacters as a literal file path")
    func doesNotInterpretFilePathAsShell() async throws {
        let repository = try temporaryDirectory(named: "Safe Arguments")
        defer { try? FileManager.default.removeItem(at: repository) }

        try await initializeRepository(at: repository)
        try write("base\n", to: repository.appendingPathComponent("Base.swift"))
        try await git(["add", "--", "Base.swift"], at: repository)
        try await commit(at: repository, message: "Initial")

        let client = GitClient(runner: ProcessRunner())
        let baseline = try await client.captureSnapshot(at: repository)
        let literalName = "Agent; touch INJECTED.swift"
        try write("safe\n", to: repository.appendingPathComponent(literalName))

        let report = try await client.changes(at: repository, since: baseline)

        #expect(report.changes.contains { $0.path == literalName })
        #expect(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("INJECTED.swift").path))
    }

    @Test("Reports a typed error outside a Git repository")
    func rejectsNonRepository() async throws {
        let directory = try temporaryDirectory(named: "Not Git")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = GitClient(runner: ProcessRunner())

        do {
            _ = try await client.captureSnapshot(at: directory)
            Issue.record("Git bo‘lmagan papka qabul qilinmasligi kerak edi")
        } catch let error as GitClientError {
            #expect(error == .notRepository(directory.path))
        }
    }

    private func initializeRepository(at directory: URL) async throws {
        try await git(["init"], at: directory)
    }

    private func commit(at directory: URL, message: String) async throws {
        try await git(
            [
                "-c", "user.name=Local iOS Agent Tests",
                "-c", "user.email=tests@local.invalid",
                "commit", "-m", message,
            ],
            at: directory
        )
    }

    private func git(_ arguments: [String], at directory: URL) async throws {
        let result = try await ProcessRunner().runAndCollect(
            CommandSpec(
                executable: "git",
                arguments: ["-C", directory.path] + arguments,
                timeout: .seconds(10)
            ),
            outputLimit: 262_144
        )
        guard result.isSuccess else {
            throw GitTestError.commandFailed(result.errorOutput)
        }
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LocalIOSAgentTests-\(UUID().uuidString)-\(name)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum GitTestError: Error {
    case commandFailed(String)
}
