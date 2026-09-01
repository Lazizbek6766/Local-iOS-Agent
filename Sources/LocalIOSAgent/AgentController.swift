import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AgentController {
    var projectURL: URL?
    var modelName: String {
        didSet {
            preferences.set(modelName, forKey: Self.modelDefaultsKey)
            guard !isRestoringSession else { return }
            scheduleSessionSave()
        }
    }
    var taskDraft = ""
    var messages: [ChatMessage]
    var sessions: [AgentSession]
    var activeSessionID: UUID?
    var messagesRevision = 0
    var isRunning = false
    var isStopping = false
    var isLoadingSessions = false
    var isRefreshingDiagnostics = false
    var isInspectingProject = false
    var isRefreshingGitChanges = false
    var isLoadingGitDiff = false
    var runSummary = "Tekshirilmoqda…"
    var currentActivity: AgentActivity?
    var dependencyDiagnostics = DependencyID.allCases.map(DependencyDiagnostic.unknown)
    var projectPreflight: ProjectPreflight = .notSelected
    var projectBootstrapReport: ProjectBootstrapReport = .noProject
    var gitChangeReport: GitChangeReport?
    var gitStatusMessage = "Git holati tekshirilmagan"
    var selectedGitDiff: GitDiff?
    var gitDiffError: String?
    var lastError: String?
    var technicalDetails: String?

    @ObservationIgnored private let runner: any ProcessRunning
    @ObservationIgnored private let openCode: any OpenCodeRunning
    @ObservationIgnored private let sessionStore: any SessionStoring
    @ObservationIgnored private let environmentDiagnostics: any LocalEnvironmentDiagnosing
    @ObservationIgnored private let projectBootstrapper: any ProjectBootstrapping
    @ObservationIgnored private let gitInspector: any GitInspecting
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var executionTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    @ObservationIgnored private var gitRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var activeAssistantMessageID: UUID?
    @ObservationIgnored private var diagnosticOutput = ""
    @ObservationIgnored private var didReportOutputTruncation = false
    @ObservationIgnored private var didReceiveOpenCodeError = false
    @ObservationIgnored private var didInitialize = false
    @ObservationIgnored private var isRestoringSession = false
    @ObservationIgnored private var dependencyDiagnosticGeneration = 0
    @ObservationIgnored private var projectDiagnosticGeneration = 0
    @ObservationIgnored private var gitInspectionGeneration = 0
    @ObservationIgnored private var gitDiffGeneration = 0
    @ObservationIgnored private var activeGitBaseline: GitSnapshot?
    @ObservationIgnored private var activeRunProjectURL: URL?

    private static let projectDefaultsKey = "selectedProjectPath"
    private static let modelDefaultsKey = "selectedModelName"
    private static let activeSessionDefaultsKey = "activeSessionID"
    private static let defaultModel = "ollama/qwen3.5-ios:9b-64k"
    private static let maximumDiagnosticLength = 16_384

    init(
        runner: any ProcessRunning = ProcessRunner(),
        openCode: (any OpenCodeRunning)? = nil,
        sessionStore: (any SessionStoring)? = nil,
        environmentDiagnostics: (any LocalEnvironmentDiagnosing)? = nil,
        projectBootstrapper: (any ProjectBootstrapping)? = nil,
        gitInspector: (any GitInspecting)? = nil,
        preferences: UserDefaults = .standard
    ) {
        self.runner = runner
        self.openCode = openCode ?? OpenCodeClient(runner: runner)
        self.sessionStore = sessionStore ?? FileSessionStore()
        self.environmentDiagnostics = environmentDiagnostics
            ?? EnvironmentDiagnosticsService(runner: runner)
        self.projectBootstrapper = projectBootstrapper ?? ProjectBootstrapper()
        self.gitInspector = gitInspector ?? GitClient(runner: runner)
        self.preferences = preferences

        let storedModel = preferences.string(forKey: Self.modelDefaultsKey)
            ?? Self.defaultModel
        modelName = storedModel

        var storedProjectPath: String?
        if let path = preferences.string(forKey: Self.projectDefaultsKey),
           FileManager.default.fileExists(atPath: path) {
            storedProjectPath = path
            projectURL = URL(fileURLWithPath: path, isDirectory: true)
        }

        let initialSession = AgentSession(
            projectPath: storedProjectPath,
            modelName: storedModel
        )
        messages = initialSession.messages
        sessions = [initialSession]
        activeSessionID = initialSession.id
    }

    var projectName: String {
        projectURL?.lastPathComponent ?? "Loyiha tanlanmagan"
    }

    var activeSessionTitle: String {
        activeSession?.title ?? AgentSession.untitledTitle
    }

    var activeOpenCodeSessionID: String? {
        activeSession?.openCodeSessionID
    }

    var orderedSessions: [AgentSession] {
        sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    var canSubmit: Bool {
        projectURL != nil
            && isEnvironmentReady
            && !taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isRunning
    }

    var ollamaState: ComponentState {
        componentState(for: diagnostic(for: .ollama))
    }

    var openCodeState: ComponentState {
        componentState(for: diagnostic(for: .openCode))
    }

    var xcodeBuildMCPState: ComponentState {
        componentState(for: diagnostic(for: .xcodeBuildMCP))
    }

    var isEnvironmentReady: Bool {
        ollamaState.isReady && openCodeState.isReady && xcodeBuildMCPState.isReady
    }

    var environmentIssueCount: Int {
        dependencyDiagnostics.filter(\.blocksAgent).count
    }

    var gitChangeCount: Int {
        gitChangeReport?.changes.count ?? 0
    }

    var agentGitChangeCount: Int {
        gitChangeReport?.agentChangeCount ?? 0
    }

    func diagnostic(for id: DependencyID) -> DependencyDiagnostic {
        dependencyDiagnostics.first(where: { $0.id == id }) ?? .unknown(id)
    }

    func initialize() async {
        guard !didInitialize else { return }
        didInitialize = true
        isLoadingSessions = true

        do {
            let loadedSessions = try await sessionStore.loadSessions()
            if !loadedSessions.isEmpty {
                sessions = loadedSessions
                let preferredID = preferences.string(forKey: Self.activeSessionDefaultsKey)
                    .flatMap(UUID.init(uuidString:))
                let session = sessions.first(where: { $0.id == preferredID })
                    ?? sessions[0]
                restore(session)
            }
        } catch {
            lastError = error.localizedDescription
            technicalDetails = "Sessiya arxivi o‘zgartirilmadi. Fayl: \(FileSessionStore.defaultFileURL().path)"
        }

        isLoadingSessions = false
        await refreshHealth()
        await refreshGitChanges()
    }

    func chooseProject() {
        guard !isRunning else {
            show(AgentError.processAlreadyRunning)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "iOS loyiha papkasini tanlang"
        panel.prompt = "Tanlash"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectURL = url
        resetGitInspection(for: url)
        preferences.set(url.path, forKey: Self.projectDefaultsKey)
        appendMessage(
            ChatMessage(role: .system, content: "Loyiha tanlandi: \(url.path)")
        )
        runSummary = isEnvironmentReady ? "Tayyor" : "Komponentlar yetishmaydi"
        scheduleSessionSave()
        Task {
            await refreshProjectPreflight()
            await refreshGitChanges()
        }
    }

    func startOllama() {
        Task {
            do {
                let result = try await runner.runAndCollect(
                    CommandSpec(
                        executable: "open",
                        arguments: ["-a", "Ollama"],
                        timeout: .seconds(10)
                    ),
                    outputLimit: 65_536
                )
                guard result.isSuccess else {
                    throw AgentError.executableLaunchFailed(
                        result.errorOutput.firstNonEmptyLine
                            ?? result.termination.failureDescription
                    )
                }
                try await Task.sleep(for: .seconds(1))
                await refreshHealth()
            } catch {
                show(error)
            }
        }
    }

    func refreshHealth() async {
        dependencyDiagnosticGeneration += 1
        projectDiagnosticGeneration += 1
        let dependencyGeneration = dependencyDiagnosticGeneration
        let projectGeneration = projectDiagnosticGeneration
        let selectedProject = projectURL
        isRefreshingDiagnostics = true
        isInspectingProject = true
        dependencyDiagnostics = DependencyID.allCases.map(DependencyDiagnostic.checking)
        projectPreflight = .checking(path: selectedProject?.path)

        async let dependencies = environmentDiagnostics.diagnoseDependencies(modelName: modelName)
        let bootstrapResult = await projectBootstrapper.bootstrapProject(at: selectedProject)
        let projectResult = await environmentDiagnostics.inspectProject(at: selectedProject)
        let dependencyResults = await dependencies

        if dependencyGeneration == dependencyDiagnosticGeneration {
            dependencyDiagnostics = DependencyID.allCases.map { id in
                dependencyResults.first(where: { $0.id == id }) ?? .unknown(id)
            }
            isRefreshingDiagnostics = false
        }
        if projectGeneration == projectDiagnosticGeneration {
            projectBootstrapReport = bootstrapResult
            projectPreflight = projectResult
            isInspectingProject = false
        }

        if !isRunning {
            if isEnvironmentReady {
                runSummary = projectURL == nil ? "Loyiha kutilmoqda" : "Tayyor"
            } else {
                runSummary = "\(environmentIssueCount) ta komponent tayyor emas"
            }
        }
    }

    func refreshProjectPreflight() async {
        projectDiagnosticGeneration += 1
        let generation = projectDiagnosticGeneration
        let selectedProject = projectURL
        isInspectingProject = true
        projectPreflight = .checking(path: selectedProject?.path)

        let bootstrapResult = await projectBootstrapper.bootstrapProject(at: selectedProject)
        let result = await environmentDiagnostics.inspectProject(at: selectedProject)
        guard generation == projectDiagnosticGeneration else { return }
        projectBootstrapReport = bootstrapResult
        projectPreflight = result
        isInspectingProject = false
    }

    func submitDraft() {
        let task = taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            show(AgentError.emptyTask)
            return
        }

        taskDraft = ""
        execute(task: task)
    }

    func execute(action: QuickAction) {
        execute(task: action.prompt)
    }

    func execute(task: String) {
        guard let projectURL else {
            show(AgentError.noProjectSelected)
            return
        }
        guard !isRunning else {
            show(AgentError.processAlreadyRunning)
            return
        }

        ensureActiveSession()
        updateUntitledSessionTitle(using: task)

        let assistantID = UUID()
        activeAssistantMessageID = assistantID
        activeRunProjectURL = projectURL
        activeGitBaseline = nil
        gitRefreshTask?.cancel()
        isRunning = true
        isStopping = false
        didReportOutputTruncation = false
        didReceiveOpenCodeError = false
        diagnosticOutput = ""
        runSummary = "Agent ishlayapti…"
        currentActivity = AgentActivity(kind: .preparing)
        lastError = nil
        technicalDetails = nil

        appendMessage(ChatMessage(role: .user, content: task), save: false)
        appendMessage(
            ChatMessage(id: assistantID, role: .assistant, content: ""),
            save: false
        )
        scheduleSessionSave()

        let request = OpenCodeRunRequest(
            task: task,
            model: normalizedModelName,
            projectURL: projectURL,
            sessionID: activeOpenCodeSessionID,
            title: activeOpenCodeSessionID == nil ? activeSessionTitle : nil
        )

        executionTask = Task { [weak self] in
            guard let self else { return }
            do {
                await captureGitBaseline(at: projectURL)
                try Task.checkCancellation()
                let stream = try await openCode.start(request)
                for try await event in stream {
                    try Task.checkCancellation()
                    handle(event: event, messageID: assistantID)
                }
            } catch is CancellationError {
                return
            } catch {
                show(error)
                appendToActiveMessage("\n\n— \(error.localizedDescription) —")
                finishRun(summary: "Vazifa xato bilan yakunlandi")
            }
        }
    }

    func stopCurrentTask() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        runSummary = "To‘xtatilmoqda…"

        stopTask = Task { [weak self] in
            guard let self else { return }
            let stopped = await openCode.stop()
            guard isRunning else { return }

            executionTask?.cancel()
            if stopped {
                appendToActiveMessage("\n\n— Vazifa foydalanuvchi tomonidan to‘xtatildi. —")
                finishRun(summary: "To‘xtatildi")
            } else {
                show(AgentError.processTerminationFailed)
                appendToActiveMessage(
                    "\n\n— Jarayonni belgilangan vaqt ichida to‘xtatib bo‘lmadi. —"
                )
                finishRun(summary: "To‘xtatish muvaffaqiyatsiz")
            }
        }
    }

    func createNewSession() {
        guard !isRunning else { return }
        snapshotActiveSession()

        let session = AgentSession(
            projectPath: projectURL?.path,
            modelName: modelName
        )
        sessions.append(session)
        restore(session)
        runSummary = isEnvironmentReady
            ? (projectURL == nil ? "Loyiha kutilmoqda" : "Tayyor")
            : "Komponentlar yetishmaydi"
        scheduleSessionSave(immediately: true)
    }

    func clearConversation() {
        createNewSession()
    }

    func selectSession(_ id: UUID) {
        guard !isRunning, id != activeSessionID else { return }
        snapshotActiveSession()
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        restore(session)
        scheduleSessionSave()
        Task { await refreshHealth() }
    }

    func deleteSession(_ id: UUID) {
        guard !isRunning else { return }
        let deletedActiveSession = activeSessionID == id
        sessions.removeAll { $0.id == id }

        if sessions.isEmpty {
            let replacement = AgentSession(
                projectPath: projectURL?.path,
                modelName: modelName
            )
            sessions = [replacement]
            restore(replacement)
        } else if activeSessionID == id, let replacement = orderedSessions.first {
            restore(replacement)
        }
        scheduleSessionSave(immediately: true)
        if deletedActiveSession {
            Task { await refreshHealth() }
        }
    }

    func dismissError() {
        lastError = nil
        technicalDetails = nil
    }

    func openInXcode() {
        guard let projectURL else {
            show(AgentError.noProjectSelected)
            return
        }

        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: projectURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let candidate = children.first(where: { $0.pathExtension == "xcworkspace" })
                ?? children.first(where: { $0.pathExtension == "xcodeproj" })
                ?? projectURL
            NSWorkspace.shared.open(candidate)
        } catch {
            NSWorkspace.shared.open(projectURL)
        }
    }

    func refreshGitChanges() async {
        guard let projectURL else {
            resetGitInspection(for: nil)
            return
        }
        let baseline = activeRunProjectURL?.standardizedFileURL == projectURL.standardizedFileURL
            ? activeGitBaseline
            : nil
        await inspectGitChanges(at: projectURL, since: baseline)
    }

    func loadGitDiff(for changeID: GitFileChange.ID?) async {
        gitDiffGeneration += 1
        let generation = gitDiffGeneration
        selectedGitDiff = nil
        gitDiffError = nil

        guard let changeID,
              let report = gitChangeReport,
              let change = report.changes.first(where: { $0.id == changeID }) else {
            isLoadingGitDiff = false
            return
        }

        isLoadingGitDiff = true
        do {
            let diff = try await gitInspector.diff(
                for: change,
                in: report.repositoryRoot,
                outputLimit: 1_048_576
            )
            guard generation == gitDiffGeneration else { return }
            selectedGitDiff = diff
            isLoadingGitDiff = false
        } catch is CancellationError {
            guard generation == gitDiffGeneration else { return }
            isLoadingGitDiff = false
        } catch {
            guard generation == gitDiffGeneration else { return }
            gitDiffError = error.localizedDescription
            isLoadingGitDiff = false
        }
    }

    func openGitChangeInXcode(_ changeID: GitFileChange.ID) {
        guard let fileURL = gitFileURL(for: changeID),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            show(AgentError.gitFileUnavailable)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runner.runAndCollect(
                    CommandSpec(
                        executable: "open",
                        arguments: ["-b", "com.apple.dt.Xcode", fileURL.path],
                        timeout: .seconds(10)
                    ),
                    outputLimit: 65_536
                )
                guard result.isSuccess else {
                    throw AgentError.executableLaunchFailed(
                        result.errorOutput.firstNonEmptyLine
                            ?? result.termination.failureDescription
                    )
                }
            } catch {
                show(error)
            }
        }
    }

    func revealGitChangeInFinder(_ changeID: GitFileChange.ID) {
        guard let fileURL = gitFileURL(for: changeID) else {
            show(AgentError.gitFileUnavailable)
            return
        }
        let target = FileManager.default.fileExists(atPath: fileURL.path)
            ? fileURL
            : fileURL.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private var activeSession: AgentSession? {
        guard let activeSessionID else { return nil }
        return sessions.first(where: { $0.id == activeSessionID })
    }

    private var normalizedModelName: String {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ollama/") {
            return trimmed
        }
        return "ollama/\(trimmed)"
    }

    private func captureGitBaseline(at projectURL: URL) async {
        gitInspectionGeneration += 1
        let generation = gitInspectionGeneration
        isRefreshingGitChanges = true
        gitStatusMessage = "Vazifadan oldingi Git holati saqlanmoqda…"

        do {
            let snapshot = try await gitInspector.captureSnapshot(at: projectURL)
            guard generation == gitInspectionGeneration,
                  activeRunProjectURL?.standardizedFileURL == projectURL.standardizedFileURL else {
                return
            }
            activeGitBaseline = snapshot
            gitStatusMessage = snapshot.states.isEmpty
                ? "Boshlang‘ich Git holati toza"
                : "Boshlang‘ich holat: \(snapshot.states.count) ta mavjud o‘zgarish"
            isRefreshingGitChanges = false
        } catch is CancellationError {
            guard generation == gitInspectionGeneration else { return }
            isRefreshingGitChanges = false
        } catch let error as GitClientError {
            guard generation == gitInspectionGeneration else { return }
            activeGitBaseline = nil
            gitChangeReport = nil
            gitStatusMessage = error.localizedDescription
            isRefreshingGitChanges = false
        } catch {
            guard generation == gitInspectionGeneration else { return }
            activeGitBaseline = nil
            gitChangeReport = nil
            gitStatusMessage = "Git snapshot olinmadi: \(error.localizedDescription)"
            isRefreshingGitChanges = false
        }
    }

    private func inspectGitChanges(
        at projectURL: URL,
        since baseline: GitSnapshot?
    ) async {
        gitInspectionGeneration += 1
        let generation = gitInspectionGeneration
        isRefreshingGitChanges = true
        gitStatusMessage = "Git o‘zgarishlari tekshirilmoqda…"

        do {
            let report = try await gitInspector.changes(at: projectURL, since: baseline)
            guard generation == gitInspectionGeneration,
                  self.projectURL?.standardizedFileURL == projectURL.standardizedFileURL else {
                return
            }
            gitChangeReport = report
            if report.changes.isEmpty {
                gitStatusMessage = "Ishchi daraxt toza"
            } else if baseline != nil {
                gitStatusMessage = "Agent: \(report.agentChangeCount) · Oldindan: \(report.preExistingChangeCount)"
            } else {
                gitStatusMessage = "\(report.changes.count) ta oldindan mavjud o‘zgarish"
            }
            if let selectedPath = selectedGitDiff?.path,
               !report.changes.contains(where: { $0.path == selectedPath }) {
                gitDiffGeneration += 1
                selectedGitDiff = nil
                gitDiffError = nil
                isLoadingGitDiff = false
            }
            isRefreshingGitChanges = false
        } catch is CancellationError {
            guard generation == gitInspectionGeneration else { return }
            isRefreshingGitChanges = false
        } catch GitClientError.snapshotRepositoryChanged where baseline != nil {
            guard generation == gitInspectionGeneration else { return }
            activeGitBaseline = nil
            await inspectGitChanges(at: projectURL, since: nil)
        } catch let error as GitClientError {
            guard generation == gitInspectionGeneration else { return }
            gitChangeReport = nil
            gitStatusMessage = error.localizedDescription
            isRefreshingGitChanges = false
        } catch {
            guard generation == gitInspectionGeneration else { return }
            gitChangeReport = nil
            gitStatusMessage = "Git holatini o‘qib bo‘lmadi: \(error.localizedDescription)"
            isRefreshingGitChanges = false
        }
    }

    private func resetGitInspection(for projectURL: URL?) {
        gitInspectionGeneration += 1
        gitDiffGeneration += 1
        gitRefreshTask?.cancel()
        gitRefreshTask = nil
        activeGitBaseline = nil
        activeRunProjectURL = nil
        gitChangeReport = nil
        selectedGitDiff = nil
        gitDiffError = nil
        isRefreshingGitChanges = false
        isLoadingGitDiff = false
        gitStatusMessage = projectURL == nil
            ? "Git uchun loyiha tanlanmagan"
            : "Git holati tekshirilmagan"
    }

    private func gitFileURL(for changeID: GitFileChange.ID) -> URL? {
        guard let report = gitChangeReport,
              let change = report.changes.first(where: { $0.id == changeID }) else {
            return nil
        }
        let root = report.repositoryRoot.standardizedFileURL
        let fileURL = root.appendingPathComponent(change.path).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(rootPrefix) else { return nil }
        return fileURL
    }

    private func scheduleGitRefreshAfterRun() {
        guard let projectURL = activeRunProjectURL else { return }
        let baseline = activeGitBaseline
        gitRefreshTask?.cancel()
        gitRefreshTask = Task { [weak self] in
            await self?.inspectGitChanges(at: projectURL, since: baseline)
        }
    }

    private func restore(_ session: AgentSession) {
        let previousProjectURL = projectURL
        isRestoringSession = true
        activeSessionID = session.id
        modelName = session.modelName
        messages = session.messages.isEmpty ? [AgentSession.welcomeMessage()] : session.messages
        messagesRevision += 1
        preferences.set(session.id.uuidString, forKey: Self.activeSessionDefaultsKey)

        if let projectPath = session.projectPath,
           FileManager.default.fileExists(atPath: projectPath) {
            projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
            preferences.set(projectPath, forKey: Self.projectDefaultsKey)
        } else {
            projectURL = nil
            if session.projectPath != nil {
                lastError = "Bu sessiyadagi loyiha papkasi endi mavjud emas."
                technicalDetails = session.projectPath
            }
        }
        currentActivity = nil
        isRestoringSession = false

        if previousProjectURL?.standardizedFileURL != projectURL?.standardizedFileURL {
            resetGitInspection(for: projectURL)
        }
    }

    private func ensureActiveSession() {
        guard activeSession == nil else { return }
        let session = AgentSession(
            projectPath: projectURL?.path,
            modelName: modelName
        )
        sessions.append(session)
        activeSessionID = session.id
    }

    private func updateUntitledSessionTitle(using task: String) {
        guard let id = activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].title == AgentSession.untitledTitle else { return }

        let firstLine = task.split(whereSeparator: \ .isNewline).first.map(String.init) ?? task
        let compact = firstLine
            .split(whereSeparator: \ .isWhitespace)
            .joined(separator: " ")
        let prefix = String(compact.prefix(54))
        sessions[index].title = compact.count > prefix.count ? prefix + "…" : prefix
    }

    private func componentState(for diagnostic: DependencyDiagnostic) -> ComponentState {
        switch diagnostic.status {
        case .unknown:
            .unknown
        case .checking:
            .checking
        case .ready:
            .ready(diagnostic.summary)
        case .attention where !diagnostic.blocksAgent:
            .ready(diagnostic.summary)
        case .attention, .unavailable:
            .missing(diagnostic.summary)
        case .failed:
            .failed(diagnostic.summary)
        }
    }

    private func handle(event: OpenCodeEvent, messageID: UUID) {
        switch event {
        case .sessionIdentified(let sessionID):
            guard let id = activeSessionID,
                  let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[index].openCodeSessionID = sessionID
            scheduleSessionSave()
        case .stepStarted:
            currentActivity = AgentActivity(kind: .preparing)
        case .text(_, let content):
            let separator = messageContent(id: messageID).isEmpty ? "" : "\n\n"
            append(separator + content, to: messageID)
        case .tool(let tool):
            currentActivity = AgentActivity(kind: .tool(name: tool.title ?? tool.name, failed: tool.failed))
            if tool.failed {
                let detail = tool.detail ?? "\(tool.name) bajarilmadi."
                appendDiagnostic("\(tool.name): \(detail)\n")
            }
        case .reportedError(let detail):
            didReceiveOpenCodeError = true
            lastError = detail
            technicalDetails = diagnosticOutput.firstNonEmptyLine
            append("\n\nOpenCode xatosi: \(detail)", to: messageID)
        case .diagnostic(let text):
            appendDiagnostic(text)
        case .unstructuredOutput(let text):
            append(text, to: messageID)
        case .outputTruncated(let droppedEventCount):
            guard !didReportOutputTruncation else { return }
            didReportOutputTruncation = true
            append(
                "\n\n— Juda tez output sabab \(droppedEventCount) ta oraliq bo‘lak ko‘rsatilmadi. —\n",
                to: messageID
            )
        case .finished(let termination):
            finish(termination: termination, messageID: messageID)
        }
    }

    private func finish(termination: ProcessTermination, messageID: UUID) {
        switch termination {
        case .exited(0):
            if didReceiveOpenCodeError {
                finishRun(summary: "OpenCode xatosi bilan yakunlandi")
            } else if messageContent(id: messageID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                show(AgentError.emptyAgentResponse)
                technicalDetails = diagnosticOutput.firstNonEmptyLine
                append(
                    "Agent ishni tugatdi, lekin ko‘rsatiladigan javob kelmadi. OpenCode sessiyasi saqlangan bo‘lsa, keyingi xabar shu kontekstni davom ettiradi.",
                    to: messageID
                )
                finishRun(summary: "Javob olinmadi")
            } else {
                finishRun(summary: "Muvaffaqiyatli yakunlandi")
            }
        case .exited(let status):
            appendFailureDetails("Jarayon \(status) kodi bilan yakunlandi.", to: messageID)
            finishRun(summary: "Xato kodi: \(status)")
        case .uncaughtSignal(let signal):
            appendFailureDetails("Jarayon \(signal) signali bilan yakunlandi.", to: messageID)
            finishRun(summary: "Signal: \(signal)")
        case .cancelled:
            append("\n\n— Vazifa foydalanuvchi tomonidan to‘xtatildi. —", to: messageID)
            finishRun(summary: "To‘xtatildi")
        case .timedOut:
            appendFailureDetails("Jarayon uchun belgilangan vaqt tugadi.", to: messageID)
            finishRun(summary: "Vaqt tugadi")
        }
    }

    private func appendFailureDetails(_ headline: String, to messageID: UUID) {
        let detail = diagnosticOutput.firstNonEmptyLine
        let suffix = detail.map { "\n\($0)" } ?? ""
        append("\n\n\(headline)\(suffix)", to: messageID)
        lastError = headline
        technicalDetails = detail
    }

    private func append(_ text: String, to id: UUID) {
        let cleaned = cleanOutput(text)
        guard !cleaned.isEmpty,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += cleaned
        messagesRevision += 1
        scheduleSessionSave()
    }

    private func appendMessage(_ message: ChatMessage, save: Bool = true) {
        messages.append(message)
        messagesRevision += 1
        if save {
            scheduleSessionSave()
        }
    }

    private func appendToActiveMessage(_ text: String) {
        guard let activeAssistantMessageID else { return }
        append(text, to: activeAssistantMessageID)
    }

    private func appendDiagnostic(_ value: String) {
        let cleaned = cleanOutput(value)
        guard !cleaned.isEmpty else { return }
        diagnosticOutput += cleaned
        if diagnosticOutput.count > Self.maximumDiagnosticLength {
            diagnosticOutput = String(diagnosticOutput.suffix(Self.maximumDiagnosticLength))
        }
    }

    private func messageContent(id: UUID) -> String {
        messages.first(where: { $0.id == id })?.content ?? ""
    }

    private func finishRun(summary: String) {
        guard isRunning else { return }
        isRunning = false
        isStopping = false
        runSummary = summary
        currentActivity = nil
        activeAssistantMessageID = nil
        executionTask = nil
        stopTask = nil
        scheduleSessionSave(immediately: true)
        scheduleGitRefreshAfterRun()
    }

    private func snapshotActiveSession() {
        guard let id = activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].projectPath = projectURL?.path
        sessions[index].modelName = modelName
        sessions[index].messages = messages
        sessions[index].updatedAt = Date()
    }

    private func scheduleSessionSave(immediately: Bool = false) {
        guard !isRestoringSession else { return }
        snapshotActiveSession()
        let snapshot = sessions
        let store = sessionStore

        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            do {
                if !immediately {
                    try await Task.sleep(for: .milliseconds(350))
                }
                try Task.checkCancellation()
                try await store.saveSessions(snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                lastError = error.localizedDescription
                technicalDetails = "Sessiya ma’lumotlari bu safar diskka yozilmadi."
            }
        }
    }

    private func show(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func cleanOutput(_ value: String) -> String {
        OutputSanitizer.clean(value)
    }
}

private extension String {
    var firstNonEmptyLine: String? {
        split(whereSeparator: \ .isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}
