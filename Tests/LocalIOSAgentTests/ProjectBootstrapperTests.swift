import Foundation
import Testing
@testable import LocalIOSAgent

@Suite("Project bootstrapper")
struct ProjectBootstrapperTests {
    @Test("Creates missing agent files once and is idempotent")
    func createsMissingFilesIdempotently() async throws {
        let root = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrapper = ProjectBootstrapper(templates: StaticProjectTemplates())

        let firstReport = await bootstrapper.bootstrapProject(at: root)

        #expect(Set(firstReport.createdItems) == [
            .agentsInstructions,
            .xcodeBuildMCPSkill,
        ])
        #expect(firstReport.failures.isEmpty)
        #expect(
            try String(contentsOf: root.appending(path: "AGENTS.md"), encoding: .utf8)
                == StaticProjectTemplates.agents
        )
        #expect(
            try String(
                contentsOf: root.appending(path: ".opencode/skills/xcodebuildmcp-cli/SKILL.md"),
                encoding: .utf8
            ) == StaticProjectTemplates.skill
        )

        let secondReport = await bootstrapper.bootstrapProject(at: root)

        #expect(secondReport.createdItems.isEmpty)
        #expect(secondReport.actions.allSatisfy { $0.status == .alreadyPresent })
        #expect(secondReport.failures.isEmpty)
    }

    @Test("Never overwrites an existing AGENTS file")
    func preservesExistingInstructions() async throws {
        let root = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let agentsURL = root.appending(path: "AGENTS.md")
        let existingRules = "# Project-specific rules\nNever overwrite me.\n"
        try Data(existingRules.utf8).write(to: agentsURL)
        let bootstrapper = ProjectBootstrapper(templates: StaticProjectTemplates())

        let report = await bootstrapper.bootstrapProject(at: root)

        let agentsAction = try #require(
            report.actions.first { $0.item == .agentsInstructions }
        )
        #expect(agentsAction.status == .alreadyPresent)
        #expect(try String(contentsOf: agentsURL, encoding: .utf8) == existingRules)
        #expect(report.createdItems == [.xcodeBuildMCPSkill])
    }

    @Test("Does not write agent files into an unsupported folder")
    func rejectsUnsupportedFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LocalIOSAgentInvalid-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bootstrapper = ProjectBootstrapper(templates: StaticProjectTemplates())

        let report = await bootstrapper.bootstrapProject(at: root)

        #expect(report.actions.isEmpty)
        #expect(report.projectError != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "AGENTS.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".opencode").path))
    }

    @Test("Refuses to follow project-internal symbolic links while installing")
    func refusesSymbolicLinkDestination() async throws {
        let root = try makeProjectRoot()
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "LocalIOSAgentOutside-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: ".opencode", directoryHint: .isDirectory),
            withDestinationURL: outside
        )
        let bootstrapper = ProjectBootstrapper(templates: StaticProjectTemplates())

        let report = await bootstrapper.bootstrapProject(at: root)

        #expect(report.createdItems == [.agentsInstructions])
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("symbolic link") == true)
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "skills").path))
    }

    @Test("Controller bootstraps before publishing project preflight")
    @MainActor
    func controllerBootstrapsBeforePreflight() async throws {
        let root = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "ProjectBootstrapperTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let runner = BootstrapNoopProcessRunner()
        let controller = AgentController(
            runner: runner,
            sessionStore: BootstrapMemorySessionStore(),
            environmentDiagnostics: BootstrapEnvironmentDiagnostics(),
            projectBootstrapper: ProjectBootstrapper(templates: StaticProjectTemplates()),
            preferences: preferences
        )
        controller.projectURL = root

        await controller.refreshHealth()

        #expect(controller.projectPreflight.status == .ready)
        #expect(controller.projectBootstrapReport.createdItems.count == 2)
        #expect(controller.projectBootstrapReport.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "AGENTS.md").path))
        #expect(
            FileManager.default.fileExists(
                atPath: root.appending(path: ".opencode/skills/xcodebuildmcp-cli/SKILL.md").path
            )
        )
    }

    private func makeProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LocalIOSAgentProject-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: "Demo.xcodeproj", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        return root
    }
}

private struct StaticProjectTemplates: ProjectTemplateLoading {
    static let agents = "# Auto AGENTS\nUse Swift 6.\n"
    static let skill = "---\nname: xcodebuildmcp-cli\n---\n# CLI skill\n"

    func data(for item: ProjectBootstrapItem) throws -> Data {
        switch item {
        case .agentsInstructions: Data(Self.agents.utf8)
        case .xcodeBuildMCPSkill: Data(Self.skill.utf8)
        }
    }
}

private struct BootstrapEnvironmentDiagnostics: LocalEnvironmentDiagnosing {
    func diagnoseDependencies(modelName: String) async -> [DependencyDiagnostic] {
        DependencyID.allCases.map { id in
            DependencyDiagnostic(
                id: id,
                status: .ready,
                summary: "Tayyor",
                facts: [],
                remediation: [],
                technicalDetails: nil,
                blocksAgent: false,
                checkedAt: Date()
            )
        }
    }

    func inspectProject(at projectURL: URL?) async -> ProjectPreflight {
        ProjectInspector().inspect(projectURL)
    }
}

private actor BootstrapNoopProcessRunner: ProcessRunning {
    func start(_ command: CommandSpec) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(.exited(0)))
            continuation.finish()
        }
    }

    func runAndCollect(_ command: CommandSpec, outputLimit: Int) -> CommandResult {
        CommandResult(
            output: "",
            errorOutput: "",
            termination: .exited(0),
            outputWasTruncated: false,
            errorOutputWasTruncated: false,
            streamWasTruncated: false
        )
    }

    func stop() -> Bool { true }
}

private actor BootstrapMemorySessionStore: SessionStoring {
    func loadSessions() -> [AgentSession] { [] }
    func saveSessions(_ sessions: [AgentSession]) {}
}
