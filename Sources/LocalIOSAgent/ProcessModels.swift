import Foundation

enum ProcessOutputChannel: Sendable, Equatable {
    case standardOutput
    case standardError
}

enum ProcessTermination: Sendable, Equatable {
    case exited(Int32)
    case uncaughtSignal(Int32)
    case cancelled
    case timedOut

    var isSuccess: Bool {
        self == .exited(0)
    }

    var exitCode: Int32? {
        guard case .exited(let code) = self else { return nil }
        return code
    }

    var failureDescription: String {
        switch self {
        case .exited(let code):
            "Jarayon \(code) kodi bilan yakunlandi."
        case .uncaughtSignal(let signal):
            "Jarayon \(signal) signali bilan yakunlandi."
        case .cancelled:
            "Jarayon bekor qilindi."
        case .timedOut:
            "Jarayon uchun belgilangan vaqt tugadi."
        }
    }
}

enum ProcessEvent: Sendable, Equatable {
    case standardOutput(String)
    case standardError(String)
    case outputTruncated(droppedEventCount: Int)
    case finished(ProcessTermination)
}

struct CommandResult: Sendable, Equatable {
    let output: String
    let errorOutput: String
    let termination: ProcessTermination
    let outputWasTruncated: Bool
    let errorOutputWasTruncated: Bool
    let streamWasTruncated: Bool

    var isSuccess: Bool {
        termination.isSuccess
    }
}

struct ProcessEnvironment: Sendable, Equatable {
    var inheritsParent: Bool
    var overrides: [String: String]
    var removedKeys: Set<String>

    init(
        inheritsParent: Bool = true,
        overrides: [String: String] = [:],
        removedKeys: Set<String> = []
    ) {
        self.inheritsParent = inheritsParent
        self.overrides = overrides
        self.removedKeys = removedKeys
    }

    static let localAgent = ProcessEnvironment(
        overrides: [
            "OLLAMA_NO_CLOUD": "1",
            "XCODEBUILDMCP_SENTRY_DISABLED": "true",
            "OPENCODE_AUTO_SHARE": "false",
            "NO_COLOR": "1",
            "TERM": "dumb"
        ],
        removedKeys: [
            "ANTHROPIC_API_KEY",
            "AZURE_OPENAI_API_KEY",
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "OPENAI_API_KEY",
            "OPENROUTER_API_KEY"
        ]
    )
}

struct CommandSpec: Sendable, Equatable {
    let executable: String
    let arguments: [String]
    let workingDirectory: URL?
    let environment: ProcessEnvironment
    let timeout: Duration?

    init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: ProcessEnvironment = .localAgent,
        timeout: Duration? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
    }
}

struct ProcessTerminationPolicy: Sendable {
    let interruptGracePeriod: Duration
    let terminateGracePeriod: Duration
    let killConfirmationPeriod: Duration

    static let `default` = ProcessTerminationPolicy(
        interruptGracePeriod: .seconds(2),
        terminateGracePeriod: .seconds(2),
        killConfirmationPeriod: .seconds(1)
    )
}

enum ProcessRunnerError: LocalizedError, Sendable, Equatable {
    case streamEndedWithoutTermination

    var errorDescription: String? {
        switch self {
        case .streamEndedWithoutTermination:
            "Jarayon natija holatisiz yakunlandi."
        }
    }
}
