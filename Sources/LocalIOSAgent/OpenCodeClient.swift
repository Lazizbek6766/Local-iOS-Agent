import Foundation

struct OpenCodeRunRequest: Sendable, Equatable {
    let task: String
    let model: String
    let projectURL: URL
    let sessionID: String?
    let title: String?
}

struct OpenCodeToolResult: Sendable, Equatable {
    let id: String?
    let name: String
    let title: String?
    let failed: Bool
    let detail: String?
}

enum OpenCodeEvent: Sendable, Equatable {
    case sessionIdentified(String)
    case stepStarted
    case text(partID: String?, content: String)
    case tool(OpenCodeToolResult)
    case reportedError(String)
    case diagnostic(String)
    case unstructuredOutput(String)
    case outputTruncated(droppedEventCount: Int)
    case finished(ProcessTermination)
}

protocol OpenCodeRunning: Sendable {
    func start(_ request: OpenCodeRunRequest) async throws -> AsyncThrowingStream<OpenCodeEvent, Error>

    @discardableResult
    func stop() async -> Bool
}

struct OpenCodeClient: OpenCodeRunning {
    private let runner: any ProcessRunning

    init(runner: any ProcessRunning) {
        self.runner = runner
    }

    func start(_ request: OpenCodeRunRequest) async throws -> AsyncThrowingStream<OpenCodeEvent, Error> {
        let processStream = try await runner.start(command(for: request))
        let pair = AsyncThrowingStream<OpenCodeEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(4_096)
        )

        let bridgeTask = Task {
            var parser = OpenCodeJSONLineParser()
            var reportedSessionID: String?
            var deliveredTextPartIDs: Set<String> = []
            var deliveredToolPartIDs: Set<String> = []
            var receivedTermination = false

            do {
                for try await event in processStream {
                    try Task.checkCancellation()

                    switch event {
                    case .standardOutput(let chunk):
                        for parsedEvent in parser.consume(chunk) {
                            yield(
                                parsedEvent,
                                to: pair.continuation,
                                reportedSessionID: &reportedSessionID,
                                deliveredTextPartIDs: &deliveredTextPartIDs,
                                deliveredToolPartIDs: &deliveredToolPartIDs
                            )
                        }
                    case .standardError(let text):
                        pair.continuation.yield(.diagnostic(text))
                    case .outputTruncated(let count):
                        pair.continuation.yield(.outputTruncated(droppedEventCount: count))
                    case .finished(let termination):
                        receivedTermination = true
                        for parsedEvent in parser.finish() {
                            yield(
                                parsedEvent,
                                to: pair.continuation,
                                reportedSessionID: &reportedSessionID,
                                deliveredTextPartIDs: &deliveredTextPartIDs,
                                deliveredToolPartIDs: &deliveredToolPartIDs
                            )
                        }
                        pair.continuation.yield(.finished(termination))
                    }
                }
                guard receivedTermination else {
                    throw ProcessRunnerError.streamEndedWithoutTermination
                }
                pair.continuation.finish()
            } catch is CancellationError {
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }

        pair.continuation.onTermination = { _ in
            bridgeTask.cancel()
        }
        return pair.stream
    }

    func stop() async -> Bool {
        await runner.stop()
    }

    private func command(for request: OpenCodeRunRequest) -> CommandSpec {
        var arguments = [
            "run",
            "--format", "json",
            "--model", request.model
        ]

        if let sessionID = request.sessionID, !sessionID.isEmpty {
            arguments += ["--session", sessionID]
        } else if let title = request.title, !title.isEmpty {
            arguments += ["--title", title]
        }

        arguments += ["--", request.task]
        return CommandSpec(
            executable: "opencode",
            arguments: arguments,
            workingDirectory: request.projectURL
        )
    }

    private func yield(
        _ event: OpenCodeEvent,
        to continuation: AsyncThrowingStream<OpenCodeEvent, Error>.Continuation,
        reportedSessionID: inout String?,
        deliveredTextPartIDs: inout Set<String>,
        deliveredToolPartIDs: inout Set<String>
    ) {
        switch event {
        case .sessionIdentified(let sessionID):
            guard sessionID != reportedSessionID else { return }
            reportedSessionID = sessionID
        case .text(let partID, _):
            if let partID, !deliveredTextPartIDs.insert(partID).inserted { return }
        case .tool(let tool):
            if let id = tool.id, !deliveredToolPartIDs.insert(id).inserted { return }
        default:
            break
        }
        continuation.yield(event)
    }
}

struct OpenCodeJSONLineParser: Sendable {
    private static let maximumLineByteCount = 8 * 1_024 * 1_024
    private var pending = ""

    mutating func consume(_ chunk: String) -> [OpenCodeEvent] {
        pending += chunk
        var events: [OpenCodeEvent] = []

        while let newline = pending.firstIndex(where: \ .isNewline) {
            let line = String(pending[..<newline])
            let nextIndex = pending.index(after: newline)
            pending.removeSubrange(..<nextIndex)
            events += Self.parse(line)
        }
        if pending.utf8.count > Self.maximumLineByteCount {
            pending = ""
            events.append(
                .reportedError("OpenCode JSON eventi 8 MB chegaradan oshdi va xavfsizlik uchun tashlab yuborildi.")
            )
        }
        return events
    }

    mutating func finish() -> [OpenCodeEvent] {
        defer { pending = "" }
        guard !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Self.parse(pending)
    }

    private static func parse(_ rawLine: String) -> [OpenCodeEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }
        guard line.utf8.count <= Self.maximumLineByteCount else {
            return [
                .reportedError("OpenCode JSON eventi 8 MB chegaradan oshdi va xavfsizlik uchun tashlab yuborildi.")
            ]
        }
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return [.unstructuredOutput(rawLine + "\n")]
        }

        var events: [OpenCodeEvent] = []
        if let sessionID = root["sessionID"] as? String, !sessionID.isEmpty {
            events.append(.sessionIdentified(sessionID))
        }

        let type = root["type"] as? String
        let part = root["part"] as? [String: Any]
        switch type {
        case "step_start":
            events.append(.stepStarted)
        case "text":
            guard let content = part?["text"] as? String, !content.isEmpty else { break }
            events.append(.text(partID: part?["id"] as? String, content: content))
        case "tool_use":
            guard let part else { break }
            let state = part["state"] as? [String: Any]
            let status = state?["status"] as? String
            let name = (part["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = name?.isEmpty == false ? name! : "Vosita"
            let detail = Self.firstString(
                in: state?["error"] ?? state?["output"] ?? part["error"],
                preferredKeys: ["message", "error", "detail", "output"]
            )
            events.append(
                .tool(
                    OpenCodeToolResult(
                        id: part["id"] as? String,
                        name: fallbackName,
                        title: state?["title"] as? String ?? part["title"] as? String,
                        failed: status == "error",
                        detail: detail
                    )
                )
            )
        case "error":
            let message = Self.firstString(
                in: root["error"],
                preferredKeys: ["message", "error", "detail", "name"]
            ) ?? "OpenCode noma’lum xato qaytardi."
            events.append(.reportedError(message))
        default:
            break
        }
        return events
    }

    private static func firstString(
        in value: Any?,
        preferredKeys: [String]
    ) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        guard let dictionary = value as? [String: Any] else { return nil }

        if let data = dictionary["data"],
           let match = firstString(in: data, preferredKeys: preferredKeys) {
            return match
        }
        for key in preferredKeys {
            if let match = firstString(in: dictionary[key], preferredKeys: preferredKeys) {
                return match
            }
        }
        return nil
    }
}
