import Foundation
import Testing
@testable import LocalIOSAgent

@Suite("Dependency diagnostics")
struct DependencyDiagnosticsTests {
    @Test("Ollama parser confirms model metadata and context length")
    func parsesOllamaModelDetails() async throws {
        let loader = QueueHTTPDataLoader(payloads: [
            HTTPPayload(
                data: Data(
                    """
                    {
                      "models": [{
                        "name": "qwen3.5-ios:latest",
                        "model": "qwen3.5-ios:latest",
                        "details": {
                          "parameter_size": "9B",
                          "quantization_level": "Q4_K_M"
                        }
                      }]
                    }
                    """.utf8
                ),
                statusCode: 200
            ),
            HTTPPayload(
                data: Data(
                    """
                    {
                      "details": {
                        "parameter_size": "9B",
                        "quantization_level": "Q4_K_M"
                      },
                      "model_info": {
                        "qwen3.context_length": 65536,
                        "qwen3.embedding_length": 4096
                      }
                    }
                    """.utf8
                ),
                statusCode: 200
            ),
        ])
        let client = OllamaHTTPClient(loader: loader)

        let inspection = try await client.inspect(modelName: "ollama/qwen3.5-ios")

        #expect(inspection.modelName == "qwen3.5-ios:latest")
        #expect(inspection.modelCount == 1)
        #expect(inspection.contextLength == 65_536)
        #expect(inspection.parameterSize == "9B")
        #expect(inspection.quantization == "Q4_K_M")
        #expect(await loader.requestCount == 2)
        #expect(await loader.lastRequestMethod == "POST")
    }

    @Test("Ollama parser returns a typed missing-model error")
    func reportsMissingOllamaModel() async throws {
        let loader = QueueHTTPDataLoader(payloads: [
            HTTPPayload(
                data: Data(
                    """
                    {"models":[{"name":"llama3:latest","model":"llama3:latest"}]}
                    """.utf8
                ),
                statusCode: 200
            ),
        ])
        let client = OllamaHTTPClient(loader: loader)

        do {
            _ = try await client.inspect(modelName: "ollama/qwen3.5-ios")
            Issue.record("Missing-model error expected")
        } catch let error as DiagnosticError {
            #expect(
                error == .ollamaModelMissing(
                    requested: "qwen3.5-ios",
                    availableCount: 1
                )
            )
        }
    }

    @Test("Service verifies current XcodeBuildMCP without obsolete doctor command")
    func diagnosesInstalledDependencies() async throws {
        let runner = DiagnosticProcessRunner(results: [
            .init("which", ["ollama"]): .success("/opt/homebrew/bin/ollama\n"),
            .init("ollama", ["--version"]): .success("ollama version 0.11.0\n"),
            .init("which", ["opencode"]): .success("/opt/homebrew/bin/opencode\n"),
            .init("opencode", ["--version"]): .success("1.2.3\n"),
            .init("opencode", ["models"]): .success("ollama/qwen3.5-ios:9b-64k\n"),
            .init("which", ["xcodebuildmcp"]): .success("/opt/homebrew/bin/xcodebuildmcp\n"),
            .init("xcodebuildmcp", ["--version"]): .success("2.7.0\n"),
            .init("xcodebuildmcp", ["tools"]): .success("discover_projs\nbuild_sim\n"),
        ])
        let service = EnvironmentDiagnosticsService(
            runner: runner,
            ollama: ReadyOllamaInspector()
        )

        let diagnostics = await service.diagnoseDependencies(
            modelName: "ollama/qwen3.5-ios:9b-64k"
        )
        let ollama = try #require(diagnostics.first { $0.id == .ollama })
        let openCode = try #require(diagnostics.first { $0.id == .openCode })
        let xcodeBuildMCP = try #require(diagnostics.first { $0.id == .xcodeBuildMCP })

        #expect(ollama.status == .ready)
        #expect(openCode.status == .ready)
        #expect(openCode.facts.contains { $0.id == "version" && $0.value == "1.2.3" })
        #expect(xcodeBuildMCP.status == .ready)
        #expect(!xcodeBuildMCP.blocksAgent)
        #expect(xcodeBuildMCP.isReady)
        #expect(xcodeBuildMCP.technicalDetails == nil)
        #expect(!xcodeBuildMCP.facts.contains { $0.id == "doctor" })
        #expect(await !runner.commands.contains { $0.arguments == ["doctor"] })
    }

    @Test("Missing OpenCode is blocking and includes an install command")
    func diagnosesMissingOpenCode() async throws {
        let runner = DiagnosticProcessRunner(results: [
            .init("which", ["opencode"]): .failure("not found", code: 1),
            .init("which", ["xcodebuildmcp"]): .failure("not found", code: 1),
        ])
        let service = EnvironmentDiagnosticsService(
            runner: runner,
            ollama: ReadyOllamaInspector()
        )

        let diagnostics = await service.diagnoseDependencies(modelName: "ollama/qwen")
        let openCode = try #require(diagnostics.first { $0.id == .openCode })

        #expect(openCode.status == .unavailable)
        #expect(openCode.blocksAgent)
        #expect(openCode.remediation.first?.command?.contains("opencode.ai") == true)
    }

    @Test("Project preflight detects build artifacts and agent instructions")
    func inspectsReadyProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LocalIOSAgentPreflight-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: "Demo.xcworkspace", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("# Rules".utf8).write(to: root.appending(path: "AGENTS.md"))
        let skill = root.appending(
            path: ".opencode/skills/xcodebuildmcp-cli/SKILL.md",
            directoryHint: .notDirectory
        )
        try FileManager.default.createDirectory(
            at: skill.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# Skill".utf8).write(to: skill)

        let preflight = ProjectInspector().inspect(root)

        #expect(preflight.status == .ready)
        #expect(preflight.artifacts == [
            ProjectArtifact(kind: .workspace, name: "Demo.xcworkspace"),
        ])
        #expect(preflight.facts.contains { $0.id == "git" && $0.value == "Repository" })
        #expect(preflight.remediation.isEmpty)
    }

    @Test("Controller publishes structured diagnostics and project preflight")
    @MainActor
    func controllerPublishesDiagnostics() async throws {
        let suiteName = "DependencyDiagnosticsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let diagnostics = StaticEnvironmentDiagnostics()
        let controller = AgentController(
            runner: DiagnosticProcessRunner(results: [:]),
            sessionStore: DiagnosticMemorySessionStore(),
            environmentDiagnostics: diagnostics,
            preferences: preferences
        )
        controller.projectURL = FileManager.default.temporaryDirectory

        await controller.refreshHealth()

        #expect(controller.environmentIssueCount == 1)
        #expect(!controller.isEnvironmentReady)
        #expect(controller.ollamaState.isReady)
        #expect(!controller.openCodeState.isReady)
        #expect(controller.xcodeBuildMCPState.isReady)
        #expect(controller.projectPreflight.status == .attention)
        #expect(!controller.isRefreshingDiagnostics)
        #expect(!controller.isInspectingProject)
    }
}

private actor QueueHTTPDataLoader: HTTPDataLoading {
    private var payloads: [HTTPPayload]
    private(set) var requests: [URLRequest] = []

    init(payloads: [HTTPPayload]) {
        self.payloads = payloads
    }

    var requestCount: Int { requests.count }
    var lastRequestMethod: String? { requests.last?.httpMethod }

    func data(for request: URLRequest) throws -> HTTPPayload {
        requests.append(request)
        guard !payloads.isEmpty else {
            throw DiagnosticError.invalidHTTPResponse
        }
        return payloads.removeFirst()
    }
}

private struct ReadyOllamaInspector: OllamaInspecting {
    func inspect(modelName: String) async throws -> OllamaInspection {
        OllamaInspection(
            version: "0.11.0",
            modelName: modelName.replacingOccurrences(of: "ollama/", with: ""),
            modelCount: 2,
            contextLength: 65_536,
            parameterSize: "9B",
            quantization: "Q4_K_M"
        )
    }
}

private struct CommandKey: Hashable, Sendable {
    let executable: String
    let arguments: [String]

    init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

private actor DiagnosticProcessRunner: ProcessRunning {
    let results: [CommandKey: CommandResult]
    private(set) var commands: [CommandSpec] = []

    init(results: [CommandKey: CommandResult]) {
        self.results = results
    }

    func start(_ command: CommandSpec) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(.exited(0)))
            continuation.finish()
        }
    }

    func runAndCollect(_ command: CommandSpec, outputLimit: Int) -> CommandResult {
        commands.append(command)
        return results[CommandKey(command.executable, command.arguments)]
            ?? .failure("unexpected command: \(command.executable)", code: 127)
    }

    func stop() -> Bool { true }
}

private extension CommandResult {
    static func success(_ output: String) -> Self {
        Self(
            output: output,
            errorOutput: "",
            termination: .exited(0),
            outputWasTruncated: false,
            errorOutputWasTruncated: false,
            streamWasTruncated: false
        )
    }

    static func failure(_ errorOutput: String, code: Int32) -> Self {
        Self(
            output: "",
            errorOutput: errorOutput,
            termination: .exited(code),
            outputWasTruncated: false,
            errorOutputWasTruncated: false,
            streamWasTruncated: false
        )
    }
}

private struct StaticEnvironmentDiagnostics: LocalEnvironmentDiagnosing {
    func diagnoseDependencies(modelName: String) async -> [DependencyDiagnostic] {
        [
            ready(.ollama),
            DependencyDiagnostic(
                id: .openCode,
                status: .unavailable,
                summary: "Topilmadi",
                facts: [],
                remediation: [],
                technicalDetails: nil,
                blocksAgent: true,
                checkedAt: Date()
            ),
            ready(.xcodeBuildMCP),
        ]
    }

    func inspectProject(at projectURL: URL?) async -> ProjectPreflight {
        ProjectPreflight(
            status: .attention,
            summary: "AGENTS.md yo‘q",
            projectPath: projectURL?.path,
            artifacts: [],
            facts: [],
            remediation: [],
            technicalDetails: nil,
            checkedAt: Date()
        )
    }

    private func ready(_ id: DependencyID) -> DependencyDiagnostic {
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

private actor DiagnosticMemorySessionStore: SessionStoring {
    func loadSessions() -> [AgentSession] { [] }
    func saveSessions(_ sessions: [AgentSession]) {}
}
