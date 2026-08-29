import Foundation

enum DependencyID: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case openCode
    case xcodeBuildMCP

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: "Ollama"
        case .openCode: "OpenCode"
        case .xcodeBuildMCP: "XcodeBuildMCP"
        }
    }
}

enum DiagnosticStatus: String, Sendable, Equatable {
    case unknown
    case checking
    case ready
    case attention
    case unavailable
    case failed
}

struct DiagnosticFact: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let value: String

    init(_ id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

struct RemediationStep: Identifiable, Sendable, Equatable {
    let id: String
    let instruction: String
    let command: String?

    init(_ id: String, instruction: String, command: String? = nil) {
        self.id = id
        self.instruction = instruction
        self.command = command
    }
}

struct DependencyDiagnostic: Identifiable, Sendable, Equatable {
    let id: DependencyID
    let status: DiagnosticStatus
    let summary: String
    let facts: [DiagnosticFact]
    let remediation: [RemediationStep]
    let technicalDetails: String?
    let blocksAgent: Bool
    let checkedAt: Date?

    var isReady: Bool { !blocksAgent && status != .checking && status != .unknown }

    static func unknown(_ id: DependencyID) -> Self {
        Self(
            id: id,
            status: .unknown,
            summary: "Tekshirilmagan",
            facts: [],
            remediation: [],
            technicalDetails: nil,
            blocksAgent: true,
            checkedAt: nil
        )
    }

    static func checking(_ id: DependencyID) -> Self {
        Self(
            id: id,
            status: .checking,
            summary: "Tekshirilmoqda…",
            facts: [],
            remediation: [],
            technicalDetails: nil,
            blocksAgent: true,
            checkedAt: nil
        )
    }
}

enum ProjectArtifactKind: String, Sendable, Equatable {
    case workspace = "Xcode workspace"
    case project = "Xcode project"
    case swiftPackage = "Swift package"
}

struct ProjectArtifact: Identifiable, Sendable, Equatable {
    let kind: ProjectArtifactKind
    let name: String

    var id: String { "\(kind.rawValue):\(name)" }
}

struct ProjectPreflight: Sendable, Equatable {
    let status: DiagnosticStatus
    let summary: String
    let projectPath: String?
    let artifacts: [ProjectArtifact]
    let facts: [DiagnosticFact]
    let remediation: [RemediationStep]
    let technicalDetails: String?
    let checkedAt: Date?

    static let notSelected = ProjectPreflight(
        status: .unknown,
        summary: "Loyiha tanlanmagan",
        projectPath: nil,
        artifacts: [],
        facts: [],
        remediation: [],
        technicalDetails: nil,
        checkedAt: nil
    )

    static func checking(path: String?) -> Self {
        Self(
            status: .checking,
            summary: "Loyiha tekshirilmoqda…",
            projectPath: path,
            artifacts: [],
            facts: [],
            remediation: [],
            technicalDetails: nil,
            checkedAt: nil
        )
    }
}

protocol LocalEnvironmentDiagnosing: Sendable {
    func diagnoseDependencies(modelName: String) async -> [DependencyDiagnostic]
    func inspectProject(at projectURL: URL?) async -> ProjectPreflight
}

struct OllamaInspection: Sendable, Equatable {
    let version: String?
    let modelName: String
    let modelCount: Int
    let contextLength: Int?
    let parameterSize: String?
    let quantization: String?
}

protocol OllamaInspecting: Sendable {
    func inspect(modelName: String) async throws -> OllamaInspection
}

struct HTTPPayload: Sendable, Equatable {
    let data: Data
    let statusCode: Int
}

protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> HTTPPayload
}

struct URLSessionHTTPDataLoader: HTTPDataLoading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> HTTPPayload {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw DiagnosticError.invalidHTTPResponse
        }
        return HTTPPayload(data: data, statusCode: response.statusCode)
    }
}

struct OllamaHTTPClient: OllamaInspecting {
    private let loader: any HTTPDataLoading
    private let baseURL: URL

    init(
        loader: any HTTPDataLoading = URLSessionHTTPDataLoader(),
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!
    ) {
        self.loader = loader
        self.baseURL = baseURL
    }

    func inspect(modelName: String) async throws -> OllamaInspection {
        let requestedModel = Self.ollamaModelName(from: modelName)
        let tagsPayload = try await load(path: "api/tags")
        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: tagsPayload.data)
        let match = tags.models.first { model in
            Self.modelsMatch(model.name, requestedModel)
                || Self.modelsMatch(model.model, requestedModel)
        }

        guard let match else {
            throw DiagnosticError.ollamaModelMissing(
                requested: requestedModel,
                availableCount: tags.models.count
            )
        }

        var showRequest = URLRequest(url: baseURL.appending(path: "api/show"))
        showRequest.httpMethod = "POST"
        showRequest.timeoutInterval = 4
        showRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        showRequest.httpBody = try JSONEncoder().encode(OllamaShowRequest(model: match.name))
        let showPayload = try await loader.data(for: showRequest)
        guard 200..<300 ~= showPayload.statusCode else {
            throw DiagnosticError.httpStatus(showPayload.statusCode)
        }
        let show = try JSONDecoder().decode(OllamaShowResponse.self, from: showPayload.data)

        return OllamaInspection(
            version: tags.version,
            modelName: match.name,
            modelCount: tags.models.count,
            contextLength: show.contextLength,
            parameterSize: show.details?.parameterSize ?? match.details?.parameterSize,
            quantization: show.details?.quantization ?? match.details?.quantization
        )
    }

    private func load(path: String) async throws -> HTTPPayload {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = 3
        let payload = try await loader.data(for: request)
        guard 200..<300 ~= payload.statusCode else {
            throw DiagnosticError.httpStatus(payload.statusCode)
        }
        return payload
    }

    private static func ollamaModelName(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("ollama/") ? String(trimmed.dropFirst("ollama/".count)) : trimmed
    }

    private static func modelsMatch(_ lhs: String, _ rhs: String) -> Bool {
        func canonical(_ value: String) -> String {
            value.hasSuffix(":latest") ? String(value.dropLast(":latest".count)) : value
        }
        return canonical(lhs) == canonical(rhs)
    }
}

struct EnvironmentDiagnosticsService: LocalEnvironmentDiagnosing {
    private let runner: any ProcessRunning
    private let ollama: any OllamaInspecting
    private let projectInspector: ProjectInspector

    init(
        runner: any ProcessRunning,
        ollama: any OllamaInspecting = OllamaHTTPClient(),
        projectInspector: ProjectInspector = ProjectInspector()
    ) {
        self.runner = runner
        self.ollama = ollama
        self.projectInspector = projectInspector
    }

    func diagnoseDependencies(modelName: String) async -> [DependencyDiagnostic] {
        async let ollamaResult = diagnoseOllama(modelName: modelName)
        async let openCodeResult = diagnoseOpenCode(modelName: modelName)
        async let xcodeBuildMCPResult = diagnoseXcodeBuildMCP()
        return await [ollamaResult, openCodeResult, xcodeBuildMCPResult]
    }

    func inspectProject(at projectURL: URL?) async -> ProjectPreflight {
        projectInspector.inspect(projectURL)
    }

    private func diagnoseOllama(modelName: String) async -> DependencyDiagnostic {
        async let cliInstallation = inspectCLI(executable: "ollama")
        do {
            let inspection = try await ollama.inspect(modelName: modelName)
            let installation = await cliInstallation
            var facts = [
                DiagnosticFact("model", label: "Tanlangan model", value: inspection.modelName),
                DiagnosticFact("models", label: "Lokal modellar", value: "\(inspection.modelCount) ta"),
            ]
            if let installation {
                facts.append(DiagnosticFact("path", label: "Executable", value: installation.path))
                facts.append(DiagnosticFact("version", label: "CLI versiyasi", value: installation.version))
            }
            if let contextLength = inspection.contextLength {
                facts.append(
                    DiagnosticFact(
                        "context",
                        label: "Kontekst",
                        value: contextLength.formatted() + " token"
                    )
                )
            }
            if let parameterSize = inspection.parameterSize {
                facts.append(DiagnosticFact("parameters", label: "Hajm", value: parameterSize))
            }
            if let quantization = inspection.quantization {
                facts.append(DiagnosticFact("quantization", label: "Kvantlash", value: quantization))
            }
            if let version = inspection.version {
                facts.append(DiagnosticFact("server-version", label: "Server versiyasi", value: version))
            }
            return DependencyDiagnostic(
                id: .ollama,
                status: installation == nil ? .attention : .ready,
                summary: installation == nil
                    ? "Server va model tayyor, CLI yo‘li aniqlanmadi"
                    : "Server, CLI va tanlangan model tayyor",
                facts: facts,
                remediation: installation == nil ? [
                    RemediationStep(
                        "cli-path",
                        instruction: "Ollama CLI mavjud bo‘lsa, uning papkasini PATH ichiga qo‘shing."
                    ),
                ] : [],
                technicalDetails: nil,
                blocksAgent: false,
                checkedAt: Date()
            )
        } catch let error as DiagnosticError {
            switch error {
            case .ollamaModelMissing(let requested, let availableCount):
                return DependencyDiagnostic(
                    id: .ollama,
                    status: .attention,
                    summary: "Tanlangan model lokal diskda yo‘q",
                    facts: [
                        DiagnosticFact("model", label: "Kerakli model", value: requested),
                        DiagnosticFact("models", label: "Boshqa modellar", value: "\(availableCount) ta"),
                    ],
                    remediation: [
                        RemediationStep(
                            "pull-model",
                            instruction: "Modelni Ollama orqali yuklang.",
                            command: "ollama pull \(requested)"
                        ),
                    ],
                    technicalDetails: error.localizedDescription,
                    blocksAgent: true,
                    checkedAt: Date()
                )
            default:
                return unavailableOllama(error)
            }
        } catch {
            return unavailableOllama(error)
        }
    }

    private func unavailableOllama(_ error: Error) -> DependencyDiagnostic {
        DependencyDiagnostic(
            id: .ollama,
            status: .unavailable,
            summary: "Ollama serveriga ulanib bo‘lmadi",
            facts: [DiagnosticFact("endpoint", label: "Manzil", value: "127.0.0.1:11434")],
            remediation: [
                RemediationStep("open", instruction: "Ollama ilovasini ishga tushiring."),
                RemediationStep(
                    "install",
                    instruction: "Ollama o‘rnatilmagan bo‘lsa, o‘rnating.",
                    command: "brew install --cask ollama"
                ),
            ],
            technicalDetails: error.localizedDescription,
            blocksAgent: true,
            checkedAt: Date()
        )
    }

    private func diagnoseOpenCode(modelName: String) async -> DependencyDiagnostic {
        guard let installation = await inspectCLI(executable: "opencode") else {
            return DependencyDiagnostic(
                id: .openCode,
                status: .unavailable,
                summary: "OpenCode topilmadi",
                facts: [],
                remediation: [
                    RemediationStep(
                        "install",
                        instruction: "OpenCode CLI’ni o‘rnating.",
                        command: "curl -fsSL https://opencode.ai/install | bash"
                    ),
                ],
                technicalDetails: "PATH ichida opencode executable topilmadi.",
                blocksAgent: true,
                checkedAt: Date()
            )
        }

        let modelResult = await run(
            executable: "opencode",
            arguments: ["models"],
            timeout: .seconds(10)
        )
        let requested = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelOutput = clean(modelResult?.output ?? "") + "\n" + clean(modelResult?.errorOutput ?? "")
        let modelAvailable = modelResult?.isSuccess == true && modelOutput.contains(requested)
        let status: DiagnosticStatus = modelAvailable ? .ready : .attention

        return DependencyDiagnostic(
            id: .openCode,
            status: status,
            summary: modelAvailable
                ? "CLI va tanlangan model provider’i tayyor"
                : "CLI ishlaydi, lekin tanlangan model ro‘yxatda tasdiqlanmadi",
            facts: [
                DiagnosticFact("path", label: "Executable", value: installation.path),
                DiagnosticFact("version", label: "Versiya", value: installation.version),
                DiagnosticFact("model", label: "Model", value: requested),
            ],
            remediation: modelAvailable ? [] : [
                RemediationStep(
                    "model",
                    instruction: "OpenCode model ro‘yxatini tekshiring.",
                    command: "opencode models"
                ),
            ],
            technicalDetails: modelAvailable ? nil : firstUsefulLine(modelOutput),
            blocksAgent: !modelAvailable,
            checkedAt: Date()
        )
    }

    private func diagnoseXcodeBuildMCP() async -> DependencyDiagnostic {
        guard let installation = await inspectCLI(executable: "xcodebuildmcp") else {
            return DependencyDiagnostic(
                id: .xcodeBuildMCP,
                status: .unavailable,
                summary: "XcodeBuildMCP topilmadi",
                facts: [],
                remediation: [
                    RemediationStep(
                        "install",
                        instruction: "XcodeBuildMCP CLI’ni Homebrew orqali o‘rnating.",
                        command: "brew tap getsentry/xcodebuildmcp && brew install xcodebuildmcp"
                    ),
                ],
                technicalDetails: "PATH ichida xcodebuildmcp executable topilmadi.",
                blocksAgent: true,
                checkedAt: Date()
            )
        }

        async let toolsResult = run(
            executable: "xcodebuildmcp",
            arguments: ["tools"],
            timeout: .seconds(10)
        )
        async let doctorResult = run(
            executable: "xcodebuildmcp",
            arguments: ["doctor"],
            timeout: .seconds(15)
        )
        let (tools, doctor) = await (toolsResult, doctorResult)
        let toolsReady = tools?.isSuccess == true && !clean(tools?.output ?? "").isEmpty
        let doctorReady = doctor?.isSuccess == true
        let hasWarning = !toolsReady || !doctorReady
        let details = [tools, doctor]
            .compactMap { result -> String? in
                guard let result, !result.isSuccess else { return nil }
                return firstUsefulLine(clean(result.errorOutput) + "\n" + clean(result.output))
                    ?? result.termination.failureDescription
            }
            .joined(separator: "\n")

        return DependencyDiagnostic(
            id: .xcodeBuildMCP,
            status: hasWarning ? .attention : .ready,
            summary: hasWarning
                ? "CLI tayyor, qo‘shimcha diagnostikada ogohlantirish bor"
                : "CLI, tool katalogi va doctor tekshiruvi tayyor",
            facts: [
                DiagnosticFact("path", label: "Executable", value: installation.path),
                DiagnosticFact("version", label: "Versiya", value: installation.version),
                DiagnosticFact("tools", label: "Tool katalogi", value: toolsReady ? "Tayyor" : "Tekshirish kerak"),
                DiagnosticFact("doctor", label: "Doctor", value: doctorReady ? "O‘tdi" : "Ogohlantirish"),
            ],
            remediation: hasWarning ? [
                RemediationStep(
                    "doctor",
                    instruction: "Doctor natijasini terminalda batafsil ko‘ring.",
                    command: "xcodebuildmcp doctor"
                ),
            ] : [],
            technicalDetails: details.isEmpty ? nil : details,
            blocksAgent: false,
            checkedAt: Date()
        )
    }

    private func inspectCLI(executable: String) async -> CLIInstallation? {
        guard let pathResult = await run(
            executable: "which",
            arguments: [executable],
            timeout: .seconds(5)
        ), pathResult.isSuccess,
        let path = firstUsefulLine(clean(pathResult.output)) else {
            return nil
        }

        guard let versionResult = await run(
            executable: executable,
            arguments: ["--version"],
            timeout: .seconds(5)
        ), versionResult.isSuccess else {
            return nil
        }
        let version = firstUsefulLine(
            clean(versionResult.output) + "\n" + clean(versionResult.errorOutput)
        ) ?? "O‘rnatilgan"
        return CLIInstallation(path: path, version: version)
    }

    private func run(
        executable: String,
        arguments: [String],
        timeout: Duration
    ) async -> CommandResult? {
        do {
            return try await runner.runAndCollect(
                CommandSpec(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout
                ),
                outputLimit: 131_072
            )
        } catch {
            return nil
        }
    }

    private func clean(_ value: String) -> String {
        OutputSanitizer.clean(value)
    }

    private func firstUsefulLine(_ value: String) -> String? {
        value.split(whereSeparator: \ .isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

struct ProjectInspector: Sendable {
    func inspect(_ projectURL: URL?) -> ProjectPreflight {
        guard let projectURL else { return .notSelected }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return ProjectPreflight(
                status: .failed,
                summary: "Loyiha papkasi mavjud emas",
                projectPath: projectURL.path,
                artifacts: [],
                facts: [],
                remediation: [RemediationStep("select", instruction: "Mavjud loyiha papkasini qayta tanlang.")],
                technicalDetails: projectURL.path,
                checkedAt: Date()
            )
        }

        do {
            let children = try fileManager.contentsOfDirectory(
                at: projectURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let artifacts = children.compactMap { url -> ProjectArtifact? in
                switch url.pathExtension {
                case "xcworkspace": ProjectArtifact(kind: .workspace, name: url.lastPathComponent)
                case "xcodeproj": ProjectArtifact(kind: .project, name: url.lastPathComponent)
                default:
                    url.lastPathComponent == "Package.swift"
                        ? ProjectArtifact(kind: .swiftPackage, name: url.lastPathComponent)
                        : nil
                }
            }.sorted { $0.name < $1.name }

            let hasGit = fileManager.fileExists(atPath: projectURL.appending(path: ".git").path)
            let hasAgents = fileManager.fileExists(atPath: projectURL.appending(path: "AGENTS.md").path)
            let skillCandidates = [
                ".opencode/skills/xcodebuildmcp-cli/SKILL.md",
                ".agents/skills/xcodebuildmcp/SKILL.md",
            ]
            let hasSkill = skillCandidates.contains {
                fileManager.fileExists(atPath: projectURL.appending(path: $0).path)
            }

            var facts = [
                DiagnosticFact("artifacts", label: "Build kirish nuqtasi", value: artifactsDescription(artifacts)),
                DiagnosticFact("git", label: "Git", value: hasGit ? "Repository" : "Aniqlanmadi"),
                DiagnosticFact("agents", label: "AGENTS.md", value: hasAgents ? "Mavjud" : "Yo‘q"),
                DiagnosticFact("skill", label: "XcodeBuildMCP skill", value: hasSkill ? "Mavjud" : "Yo‘q"),
            ]
            if let preferred = artifacts.first(where: { $0.kind == .workspace })
                ?? artifacts.first(where: { $0.kind == .project })
                ?? artifacts.first {
                facts.insert(DiagnosticFact("preferred", label: "Afzal artifact", value: preferred.name), at: 0)
            }

            var remediation: [RemediationStep] = []
            if artifacts.isEmpty {
                remediation.append(
                    RemediationStep(
                        "artifact",
                        instruction: "Papka ichida .xcworkspace, .xcodeproj yoki Package.swift mavjudligini tekshiring."
                    )
                )
            }
            if !hasAgents {
                remediation.append(
                    RemediationStep(
                        "agents",
                        instruction: "Agentning loyiha qoidalarini AGENTS.md fayliga yozing."
                    )
                )
            }
            if !hasSkill {
                remediation.append(
                    RemediationStep(
                        "skill",
                        instruction: "OpenCode uchun XcodeBuildMCP skill ko‘rsatmalarini loyiha ichiga o‘rnating."
                    )
                )
            }

            let status: DiagnosticStatus
            let summary: String
            if artifacts.isEmpty {
                status = .failed
                summary = "Build qilinadigan Xcode/Swift artifact topilmadi"
            } else if !hasAgents || !hasSkill {
                status = .attention
                summary = "Loyiha topildi, agent ko‘rsatmalarini kuchaytirish kerak"
            } else {
                status = .ready
                summary = "Loyiha agent uchun tayyor"
            }

            return ProjectPreflight(
                status: status,
                summary: summary,
                projectPath: projectURL.path,
                artifacts: artifacts,
                facts: facts,
                remediation: remediation,
                technicalDetails: nil,
                checkedAt: Date()
            )
        } catch {
            return ProjectPreflight(
                status: .failed,
                summary: "Loyiha tarkibini o‘qib bo‘lmadi",
                projectPath: projectURL.path,
                artifacts: [],
                facts: [],
                remediation: [RemediationStep("permission", instruction: "Papka ruxsatlarini tekshiring va qayta tanlang.")],
                technicalDetails: error.localizedDescription,
                checkedAt: Date()
            )
        }
    }

    private func artifactsDescription(_ artifacts: [ProjectArtifact]) -> String {
        artifacts.isEmpty ? "Topilmadi" : "\(artifacts.count) ta"
    }
}

enum DiagnosticError: LocalizedError, Sendable, Equatable {
    case invalidHTTPResponse
    case httpStatus(Int)
    case ollamaModelMissing(requested: String, availableCount: Int)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            "HTTP javobi aniqlanmadi."
        case .httpStatus(let status):
            "Server HTTP \(status) holatini qaytardi."
        case .ollamaModelMissing(let requested, let availableCount):
            "\(requested) topilmadi; serverda \(availableCount) ta model bor."
        }
    }
}

private struct CLIInstallation: Sendable {
    let path: String
    let version: String
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModel]
    let version: String?
}

private struct OllamaModel: Decodable {
    let name: String
    let model: String
    let details: OllamaModelDetails?
}

private struct OllamaModelDetails: Decodable {
    let parameterSize: String?
    let quantization: String?

    enum CodingKeys: String, CodingKey {
        case parameterSize = "parameter_size"
        case quantization = "quantization_level"
    }
}

private struct OllamaShowRequest: Encodable {
    let model: String
}

private struct OllamaShowResponse: Decodable {
    let details: OllamaModelDetails?
    let modelInfo: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case details
        case modelInfo = "model_info"
    }

    var contextLength: Int? {
        guard let match = modelInfo?.first(where: { $0.key.hasSuffix(".context_length") }) else {
            return nil
        }
        return match.value.integerValue
    }
}

private enum JSONValue: Decodable {
    case number(Double)
    case string(String)
    case boolean(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    var integerValue: Int? {
        switch self {
        case .number(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }
}
