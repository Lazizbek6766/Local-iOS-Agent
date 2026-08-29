import Darwin
import Foundation
import Testing
@testable import LocalIOSAgent

@Suite("Process runner", .serialized)
struct ProcessRunnerTests {
    private let fastTerminationPolicy = ProcessTerminationPolicy(
        interruptGracePeriod: .milliseconds(100),
        terminateGracePeriod: .milliseconds(100),
        killConfirmationPeriod: .seconds(2)
    )

    @Test("Preserves UTF-8 scalars split across chunks")
    func preservesSplitUTF8Scalars() {
        var decoder = UTF8ChunkDecoder()

        #expect(decoder.decode(Data([0xF0, 0x9F])) == "")
        #expect(decoder.decode(Data([0x98, 0x80])) == "😀")
        #expect(decoder.finish() == "")
    }

    @Test("Collects large stdout and stderr without deadlock")
    func collectsLargeOutputWithoutDeadlock() async throws {
        let runner = ProcessRunner(terminationPolicy: fastTerminationPolicy)
        let byteCount = 524_288
        let command = CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "(/usr/bin/yes O | /usr/bin/head -c \(byteCount)) & "
                    + "(/usr/bin/yes E | /usr/bin/head -c \(byteCount) >&2) & wait"
            ],
            timeout: .seconds(10)
        )

        let result = try await runner.runAndCollect(command, outputLimit: byteCount * 2)

        #expect(result.termination == .exited(0))
        #expect(result.output.utf8.count == byteCount)
        #expect(result.errorOutput.utf8.count == byteCount)
        #expect(!result.outputWasTruncated)
        #expect(!result.errorOutputWasTruncated)
        #expect(!result.streamWasTruncated)
    }

    @Test("Reports nonzero exit status and both output channels")
    func reportsNonzeroExitStatus() async throws {
        let runner = ProcessRunner(terminationPolicy: fastTerminationPolicy)
        let result = try await runner.runAndCollect(
            CommandSpec(
                executable: "/bin/sh",
                arguments: ["-c", "printf success; printf failure >&2; exit 7"],
                timeout: .seconds(2)
            ),
            outputLimit: 1_024
        )

        #expect(result.termination == .exited(7))
        #expect(result.output == "success")
        #expect(result.errorOutput == "failure")
    }

    @Test("Bounds collected output without splitting Unicode")
    func boundsCollectedOutput() async throws {
        let runner = ProcessRunner(terminationPolicy: fastTerminationPolicy)
        let result = try await runner.runAndCollect(
            CommandSpec(
                executable: "/bin/sh",
                arguments: ["-c", "printf '😀😀😀'"],
                timeout: .seconds(2)
            ),
            outputLimit: 9
        )

        #expect(result.termination == .exited(0))
        #expect(result.output == "😀😀")
        #expect(result.output.utf8.count == 8)
        #expect(result.outputWasTruncated)
    }

    @Test("Times out and escalates a process that ignores polite signals")
    func timesOutUncooperativeProcess() async throws {
        let runner = ProcessRunner(terminationPolicy: fastTerminationPolicy)
        let result = try await runner.runAndCollect(
            CommandSpec(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' INT TERM; while :; do /bin/sleep 1; done"
                ],
                timeout: .milliseconds(100)
            ),
            outputLimit: 1_024
        )

        #expect(result.termination == .timedOut)
    }

    @Test("Stops the active foreground process and reports cancellation")
    func stopsForegroundProcess() async throws {
        let runner = ProcessRunner(terminationPolicy: fastTerminationPolicy)
        let stream = try await runner.start(
            CommandSpec(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf ready; trap '' INT TERM; while :; do /bin/sleep 1; done"
                ]
            )
        )

        var didRequestStop = false
        var termination: ProcessTermination?

        for try await event in stream {
            switch event {
            case .standardOutput(let output) where output.contains("ready") && !didRequestStop:
                didRequestStop = true
                let stopped = await runner.stop()
                #expect(stopped)
            case .finished(let value):
                termination = value
            default:
                break
            }
        }

        #expect(didRequestStop)
        #expect(termination == .cancelled)
    }

    @Test("Allows independent health-check commands to run concurrently")
    func allowsConcurrentCollectedCommands() async throws {
        let runner = ProcessRunner(terminationPolicy: fastTerminationPolicy)

        async let first = runner.runAndCollect(
            CommandSpec(
                executable: "/bin/sh",
                arguments: ["-c", "/bin/sleep 0.1; printf first"],
                timeout: .seconds(2)
            ),
            outputLimit: 1_024
        )
        async let second = runner.runAndCollect(
            CommandSpec(
                executable: "/bin/sh",
                arguments: ["-c", "/bin/sleep 0.1; printf second"],
                timeout: .seconds(2)
            ),
            outputLimit: 1_024
        )

        let (firstResult, secondResult) = try await (first, second)
        #expect(firstResult.output == "first")
        #expect(secondResult.output == "second")
        #expect(firstResult.isSuccess)
        #expect(secondResult.isSuccess)
    }

    @Test("Task cancellation waits for background process cleanup")
    func cancellationCleansUpBackgroundProcess() async throws {
        let runner = ProcessRunner(terminationPolicy: fastTerminationPolicy)
        let identifierFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-ios-agent-process-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: identifierFile) }

        let collectionTask = Task {
            try await runner.runAndCollect(
                CommandSpec(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "printf '%s' $$ > \"$1\"; "
                            + "trap '' INT TERM; while :; do /bin/sleep 1; done",
                        "local-ios-agent-test",
                        identifierFile.path
                    ]
                ),
                outputLimit: 1_024
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: identifierFile.path),
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(FileManager.default.fileExists(atPath: identifierFile.path))
        let identifierText = try String(contentsOf: identifierFile, encoding: .utf8)
        let processIdentifier = try #require(pid_t(identifierText))

        collectionTask.cancel()
        do {
            _ = try await collectionTask.value
            Issue.record("CancellationError kutilgan edi")
        } catch is CancellationError {
            // Expected: runAndCollect waits for process cleanup, then propagates cancellation.
        }

        #expect(Darwin.kill(processIdentifier, 0) == -1)
    }

    @Test("Applies explicit environment removal")
    func appliesEnvironmentPolicy() async throws {
        let runner = ProcessRunner(terminationPolicy: fastTerminationPolicy)
        let environment = ProcessEnvironment(
            inheritsParent: false,
            overrides: [
                "VISIBLE_VALUE": "present",
                "OPENAI_API_KEY": "must-not-leak"
            ],
            removedKeys: ["OPENAI_API_KEY"]
        )
        let result = try await runner.runAndCollect(
            CommandSpec(
                executable: "/usr/bin/env",
                environment: environment,
                timeout: .seconds(2)
            ),
            outputLimit: 65_536
        )

        #expect(result.isSuccess)
        #expect(result.output.contains("VISIBLE_VALUE=present"))
        #expect(!result.output.contains("must-not-leak"))
    }
}
