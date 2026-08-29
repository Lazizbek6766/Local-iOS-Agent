import Foundation
import Testing
@testable import LocalIOSAgent

@Suite("OpenCode client")
struct OpenCodeClientTests {
    @Test("Parses split JSONL events and ignores duplicate completed parts")
    func parsesSplitJSONLines() async throws {
        let runner = RecordingProcessRunner(
            events: [
                .standardOutput(
                    "{\"type\":\"step_start\",\"sessionID\":\"ses_123\",\"part\":{\"type\":\"step-start\"}}\n"
                        + "{\"type\":\"text\",\"sessionID\":\"ses_123\",\"part\":{\"id\":\"prt_text\",\"type\":\"text\",\"text\":\"Sal"
                ),
                .standardOutput("om\"}}\n"),
                .standardOutput(
                    "{\"type\":\"text\",\"sessionID\":\"ses_123\",\"part\":{\"id\":\"prt_text\",\"type\":\"text\",\"text\":\"Salom\"}}\n"
                ),
                .standardOutput(
                    "{\"type\":\"tool_use\",\"sessionID\":\"ses_123\",\"part\":{\"id\":\"prt_tool\",\"tool\":\"bash\",\"state\":{\"status\":\"error\",\"title\":\"Build\",\"error\":\"failed\"}}}\n"
                ),
                .finished(.exited(0))
            ]
        )
        let client = OpenCodeClient(runner: runner)
        let stream = try await client.start(
            OpenCodeRunRequest(
                task: "Build qil",
                model: "ollama/test",
                projectURL: URL(fileURLWithPath: "/tmp/project"),
                sessionID: "ses_old",
                title: nil
            )
        )

        var received: [OpenCodeEvent] = []
        for try await event in stream {
            received.append(event)
        }

        #expect(received.filter { $0 == .sessionIdentified("ses_123") }.count == 1)
        #expect(received.contains(.stepStarted))
        #expect(received.filter { event in
            if case .text(partID: "prt_text", content: "Salom") = event { return true }
            return false
        }.count == 1)
        #expect(received.contains(.tool(OpenCodeToolResult(
            id: "prt_tool",
            name: "bash",
            title: "Build",
            failed: true,
            detail: "failed"
        ))))
        #expect(received.last == .finished(.exited(0)))

        let command = await runner.startedCommand
        #expect(command?.workingDirectory?.path == "/tmp/project")
        #expect(command?.arguments == [
            "run", "--format", "json", "--model", "ollama/test",
            "--session", "ses_old", "--", "Build qil"
        ])
    }

    @Test("Falls back to unstructured output when a line is not JSON")
    func preservesUnstructuredOutput() async throws {
        var parser = OpenCodeJSONLineParser()
        #expect(parser.consume("oddiy javob") == [])
        #expect(parser.finish() == [.unstructuredOutput("oddiy javob\n")])
    }

    @Test("Extracts nested OpenCode error message")
    func extractsNestedError() {
        var parser = OpenCodeJSONLineParser()
        let events = parser.consume(
            "{\"type\":\"error\",\"sessionID\":\"ses_x\",\"error\":{\"name\":\"ProviderError\",\"data\":{\"message\":\"Model topilmadi\"}}}\n"
        )

        #expect(events.contains(.sessionIdentified("ses_x")))
        #expect(events.contains(.reportedError("Model topilmadi")))
    }
}

private actor RecordingProcessRunner: ProcessRunning {
    private let events: [ProcessEvent]
    private(set) var startedCommand: CommandSpec?

    init(events: [ProcessEvent]) {
        self.events = events
    }

    func start(_ command: CommandSpec) -> AsyncThrowingStream<ProcessEvent, Error> {
        startedCommand = command
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
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
