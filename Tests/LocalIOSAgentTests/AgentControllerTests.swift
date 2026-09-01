import Foundation
import Testing
@testable import LocalIOSAgent

@Suite("Agent controller", .serialized)
struct AgentControllerTests {
    @MainActor
    @Test("Keeps running state until process cancellation is confirmed")
    func waitsForConfirmedProcessCancellation() async throws {
        let runner = ControllableProcessRunner()
        let suiteName = "LocalIOSAgentTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let controller = AgentController(
            runner: runner,
            sessionStore: MemorySessionStore(),
            preferences: preferences
        )
        controller.projectURL = FileManager.default.temporaryDirectory

        controller.execute(task: "Loyihani tekshir")
        try await waitUntil { await runner.hasStarted }

        #expect(controller.isRunning)
        let command = await runner.startedCommand
        #expect(command?.executable == "opencode")
        #expect(command?.workingDirectory == FileManager.default.temporaryDirectory)
        #expect(command?.arguments.last == "Loyihani tekshir")

        controller.stopCurrentTask()
        try await waitUntil { await runner.stopWasRequested }

        #expect(controller.isRunning)
        #expect(controller.isStopping)
        #expect(controller.runSummary == "To‘xtatilmoqda…")

        await runner.completeCancellation()
        try await waitUntil { !controller.isRunning }

        #expect(!controller.isStopping)
        #expect(controller.runSummary == "To‘xtatildi")
        #expect(
            controller.messages.last?.content.contains("foydalanuvchi tomonidan to‘xtatildi")
                == true
        )
    }

    @MainActor
    @Test("Captures OpenCode session ID and resumes it on the next turn")
    func resumesOpenCodeSession() async throws {
        let runner = ControllableProcessRunner()
        let openCode = ScriptedOpenCode()
        let suiteName = "LocalIOSAgentTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let controller = AgentController(
            runner: runner,
            openCode: openCode,
            sessionStore: MemorySessionStore(),
            preferences: preferences
        )
        controller.projectURL = FileManager.default.temporaryDirectory

        controller.execute(task: "Birinchi vazifa")
        try await waitUntil { !controller.isRunning }

        #expect(controller.activeOpenCodeSessionID == "ses_persisted")
        #expect(controller.activeSessionTitle == "Birinchi vazifa")
        #expect(controller.messages.last?.content == "Birinchi javob")

        controller.execute(task: "Ikkinchi vazifa")
        try await waitUntil { !controller.isRunning }

        let requests = await openCode.requests
        #expect(requests.count == 2)
        #expect(requests[0].sessionID == nil)
        #expect(requests[0].title == "Birinchi vazifa")
        #expect(requests[1].sessionID == "ses_persisted")
        #expect(requests[1].title == nil)
        #expect(controller.messages.last?.content == "Ikkinchi javob")
    }

    @MainActor
    @Test("Reports successful OpenCode exit without text as a visible error")
    func reportsEmptyOpenCodeResponse() async throws {
        let suiteName = "LocalIOSAgentTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let openCode = StaticOpenCode(events: [
            .sessionIdentified("ses_empty"),
            .stepStarted,
            .finished(.exited(0)),
        ])
        let controller = AgentController(
            runner: ControllableProcessRunner(),
            openCode: openCode,
            sessionStore: MemorySessionStore(),
            preferences: preferences
        )
        controller.projectURL = FileManager.default.temporaryDirectory

        controller.execute(task: "Javob qaytar")
        try await waitUntil { !controller.isRunning }

        #expect(controller.runSummary == "Javob olinmadi")
        #expect(controller.lastError == AgentError.emptyAgentResponse.localizedDescription)
        #expect(controller.messages.last?.content.contains("ko‘rsatiladigan javob kelmadi") == true)
    }

    @MainActor
    @Test("Keeps an OpenCode error distinct from a successful process exit")
    func reportsStructuredOpenCodeError() async throws {
        let suiteName = "LocalIOSAgentTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let openCode = StaticOpenCode(events: [
            .reportedError("Model topilmadi"),
            .finished(.exited(0)),
        ])
        let controller = AgentController(
            runner: ControllableProcessRunner(),
            openCode: openCode,
            sessionStore: MemorySessionStore(),
            preferences: preferences
        )
        controller.projectURL = FileManager.default.temporaryDirectory

        controller.execute(task: "Modelni ishlat")
        try await waitUntil { !controller.isRunning }

        #expect(controller.runSummary == "OpenCode xatosi bilan yakunlandi")
        #expect(controller.lastError == "Model topilmadi")
        #expect(controller.messages.last?.content.contains("OpenCode xatosi") == true)
    }

    @MainActor
    @Test("Captures Git state before starting OpenCode and refreshes it after completion")
    func surroundsAgentRunWithGitInspection() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitController-\(UUID().uuidString)", isDirectory: true)
        let gitInspector = GatedGitInspector(repositoryRoot: projectURL)
        let openCode = ObservableOpenCode()
        let suiteName = "LocalIOSAgentTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let controller = AgentController(
            runner: ControllableProcessRunner(),
            openCode: openCode,
            sessionStore: MemorySessionStore(),
            gitInspector: gitInspector,
            preferences: preferences
        )
        controller.projectURL = projectURL

        controller.execute(task: "Kod yoz")
        try await waitUntil { await gitInspector.captureStarted }

        #expect(controller.isRunning)
        #expect(!(await openCode.hasStarted))

        await gitInspector.completeSnapshot()
        try await waitUntil { await openCode.hasStarted }
        try await waitUntil { !controller.isRunning }
        try await waitUntil { await gitInspector.changesWereRequested }

        #expect(controller.gitChangeReport?.agentChangeCount == 1)
        #expect(controller.gitStatusMessage == "Agent: 1 · Oldindan: 0")
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await condition())
    }
}

private actor MemorySessionStore: SessionStoring {
    private var sessions: [AgentSession] = []

    func loadSessions() -> [AgentSession] {
        sessions
    }

    func saveSessions(_ sessions: [AgentSession]) {
        self.sessions = sessions
    }
}

private actor ScriptedOpenCode: OpenCodeRunning {
    private(set) var requests: [OpenCodeRunRequest] = []

    func start(_ request: OpenCodeRunRequest) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        requests.append(request)
        let response = requests.count == 1 ? "Birinchi javob" : "Ikkinchi javob"
        return AsyncThrowingStream { continuation in
            continuation.yield(.sessionIdentified("ses_persisted"))
            continuation.yield(.stepStarted)
            continuation.yield(.text(partID: "part-\(requests.count)", content: response))
            continuation.yield(.finished(.exited(0)))
            continuation.finish()
        }
    }

    func stop() -> Bool { true }
}

private actor StaticOpenCode: OpenCodeRunning {
    let events: [OpenCodeEvent]

    init(events: [OpenCodeEvent]) {
        self.events = events
    }

    func start(_ request: OpenCodeRunRequest) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func stop() -> Bool { true }
}

private actor ObservableOpenCode: OpenCodeRunning {
    private(set) var hasStarted = false

    func start(_ request: OpenCodeRunRequest) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        hasStarted = true
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(partID: "git-test", content: "Tayyor"))
            continuation.yield(.finished(.exited(0)))
            continuation.finish()
        }
    }

    func stop() -> Bool { true }
}

private actor GatedGitInspector: GitInspecting {
    private let repositoryRoot: URL
    private var snapshotContinuation: CheckedContinuation<GitSnapshot, Never>?
    private(set) var captureStarted = false
    private(set) var changesWereRequested = false

    init(repositoryRoot: URL) {
        self.repositoryRoot = repositoryRoot
    }

    func captureSnapshot(at projectURL: URL) async -> GitSnapshot {
        captureStarted = true
        return await withCheckedContinuation { continuation in
            snapshotContinuation = continuation
        }
    }

    func completeSnapshot() {
        snapshotContinuation?.resume(
            returning: GitSnapshot(
                repositoryRoot: repositoryRoot,
                capturedAt: Date(),
                states: [:]
            )
        )
        snapshotContinuation = nil
    }

    func changes(
        at projectURL: URL,
        since baseline: GitSnapshot?
    ) -> GitChangeReport {
        changesWereRequested = true
        return GitChangeReport(
            repositoryRoot: repositoryRoot,
            baselineCapturedAt: baseline?.capturedAt,
            inspectedAt: Date(),
            changes: [
                GitFileChange(
                    path: "Feature.swift",
                    previousPath: nil,
                    statusCode: "??",
                    kind: .added,
                    origin: .agent,
                    statistics: GitLineStatistics(additions: 12, deletions: 0),
                    isUntracked: true
                )
            ]
        )
    }

    func diff(
        for change: GitFileChange,
        in repositoryRoot: URL,
        outputLimit: Int
    ) -> GitDiff {
        GitDiff(path: change.path, content: "+code", isBinary: false, wasTruncated: false)
    }
}

private actor ControllableProcessRunner: ProcessRunning {
    private var eventContinuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation?
    private var stopContinuation: CheckedContinuation<Bool, Never>?
    private(set) var startedCommand: CommandSpec?
    private(set) var stopWasRequested = false

    var hasStarted: Bool {
        startedCommand != nil
    }

    func start(_ command: CommandSpec) -> AsyncThrowingStream<ProcessEvent, Error> {
        let pair = AsyncThrowingStream<ProcessEvent, Error>.makeStream()
        startedCommand = command
        eventContinuation = pair.continuation
        return pair.stream
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

    func stop() async -> Bool {
        stopWasRequested = true
        return await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func completeCancellation() {
        eventContinuation?.yield(.finished(.cancelled))
        eventContinuation?.finish()
        eventContinuation = nil
        stopContinuation?.resume(returning: true)
        stopContinuation = nil
    }
}
