import Darwin
import Foundation
import os

protocol ProcessRunning: Sendable {
    func start(_ command: CommandSpec) async throws -> AsyncThrowingStream<ProcessEvent, Error>
    func runAndCollect(_ command: CommandSpec, outputLimit: Int) async throws -> CommandResult

    @discardableResult
    func stop() async -> Bool
}

actor ProcessRunner: ProcessRunning {
    fileprivate enum RequestedTermination: Sendable {
        case cancelled
        case timedOut
    }

    private enum ExecutionRole {
        case foreground
        case background
    }

    private struct ActiveExecution: Sendable {
        let process: Process
        let control: ProcessControl
        var timeoutTask: Task<Void, Never>?
    }

    private struct LaunchedExecution: Sendable {
        let identifier: UUID
        let stream: AsyncThrowingStream<ProcessEvent, Error>
    }

    private let terminationPolicy: ProcessTerminationPolicy
    private let streamBufferLimit: Int
    private var activeExecutions: [UUID: ActiveExecution] = [:]
    private var foregroundIdentifier: UUID?

    init(
        terminationPolicy: ProcessTerminationPolicy = .default,
        streamBufferLimit: Int = 4_096
    ) {
        self.terminationPolicy = terminationPolicy
        self.streamBufferLimit = max(16, streamBufferLimit)
    }

    func start(_ command: CommandSpec) throws -> AsyncThrowingStream<ProcessEvent, Error> {
        try launch(command, role: .foreground).stream
    }

    func runAndCollect(
        _ command: CommandSpec,
        outputLimit: Int = 1_048_576
    ) async throws -> CommandResult {
        let launchedExecution = try launch(command, role: .background)
        var standardOutput = BoundedTextAccumulator(limit: outputLimit)
        var standardError = BoundedTextAccumulator(limit: outputLimit)
        var streamWasTruncated = false
        var termination: ProcessTermination?

        do {
            for try await event in launchedExecution.stream {
                try Task.checkCancellation()

                switch event {
                case .standardOutput(let value):
                    standardOutput.append(value)
                case .standardError(let value):
                    standardError.append(value)
                case .outputTruncated:
                    streamWasTruncated = true
                case .finished(let processTermination):
                    termination = processTermination
                }
            }

            try Task.checkCancellation()
        } catch is CancellationError {
            let cleanupTask = Task { [self] in
                await stop(
                    identifier: launchedExecution.identifier,
                    requestedTermination: .cancelled
                )
            }
            _ = await cleanupTask.value
            throw CancellationError()
        }

        guard let termination else {
            throw ProcessRunnerError.streamEndedWithoutTermination
        }

        return CommandResult(
            output: standardOutput.value,
            errorOutput: standardError.value,
            termination: termination,
            outputWasTruncated: standardOutput.wasTruncated,
            errorOutputWasTruncated: standardError.wasTruncated,
            streamWasTruncated: streamWasTruncated
        )
    }

    @discardableResult
    func stop() async -> Bool {
        guard let foregroundIdentifier else { return true }
        return await stop(identifier: foregroundIdentifier, requestedTermination: .cancelled)
    }

    private func launch(
        _ command: CommandSpec,
        role: ExecutionRole
    ) throws -> LaunchedExecution {
        if role == .foreground, foregroundIdentifier != nil {
            throw AgentError.processAlreadyRunning
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let identifier = UUID()
        let pair = AsyncThrowingStream<ProcessEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(streamBufferLimit)
        )
        let sink = ProcessEventSink(continuation: pair.continuation)
        let outputEmitter = ProcessOutputEmitter(channel: .standardOutput, sink: sink)
        let errorEmitter = ProcessOutputEmitter(channel: .standardError, sink: sink)
        let control = ProcessControl()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command.executable] + command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.environment = Self.commandEnvironment(for: command.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            outputEmitter.consumeAvailableData(from: handle)
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            errorEmitter.consumeAvailableData(from: handle)
        }

        process.terminationHandler = { [self] terminatedProcess in
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            outputEmitter.finish(from: standardOutput.fileHandleForReading)
            errorEmitter.finish(from: standardError.fileHandleForReading)

            let termination = Self.termination(
                for: terminatedProcess,
                requestedTermination: control.requestedTermination
            )

            Task {
                await completeExecution(
                    identifier: identifier,
                    termination: termination,
                    sink: sink
                )
            }
        }

        pair.continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task {
                await self?.stop(identifier: identifier, requestedTermination: .cancelled)
            }
        }

        if role == .foreground {
            foregroundIdentifier = identifier
        }

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            if foregroundIdentifier == identifier {
                foregroundIdentifier = nil
            }
            sink.fail(with: error)
            throw AgentError.executableLaunchFailed(
                "\(command.executable): \(error.localizedDescription)"
            )
        }

        if setpgid(process.processIdentifier, process.processIdentifier) == 0 {
            control.setProcessGroupIdentifier(process.processIdentifier)
        }

        activeExecutions[identifier] = ActiveExecution(
            process: process,
            control: control,
            timeoutTask: nil
        )

        if let timeout = command.timeout {
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }

                await self?.stop(identifier: identifier, requestedTermination: .timedOut)
            }
            activeExecutions[identifier]?.timeoutTask = timeoutTask
        }

        return LaunchedExecution(identifier: identifier, stream: pair.stream)
    }

    private func completeExecution(
        identifier: UUID,
        termination: ProcessTermination,
        sink: ProcessEventSink
    ) {
        let execution = activeExecutions.removeValue(forKey: identifier)
        execution?.timeoutTask?.cancel()

        if foregroundIdentifier == identifier {
            foregroundIdentifier = nil
        }

        sink.finish(with: termination)
    }

    @discardableResult
    private func stop(
        identifier: UUID,
        requestedTermination: RequestedTermination
    ) async -> Bool {
        guard let execution = activeExecutions[identifier] else { return true }

        if execution.process.isRunning,
           execution.control.requestTermination(requestedTermination) {
            sendSignal(SIGINT, to: execution)
            await pause(for: terminationPolicy.interruptGracePeriod)

            if isRunning(identifier: identifier) {
                sendSignal(SIGTERM, to: execution)
                await pause(for: terminationPolicy.terminateGracePeriod)
            }

            if isRunning(identifier: identifier) {
                sendSignal(SIGKILL, to: execution)
            }
        }

        return await waitUntilStopped(
            identifier: identifier,
            timeout: terminationPolicy.interruptGracePeriod
                + terminationPolicy.terminateGracePeriod
                + terminationPolicy.killConfirmationPeriod
        )
    }

    private func pause(for duration: Duration) async {
        do {
            try await Task.sleep(for: duration)
        } catch {
            // Cancellation only shortens shutdown; every signal remains state-guarded.
        }
    }

    private func waitUntilStopped(identifier: UUID, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while activeExecutions[identifier] != nil, clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                break
            }
        }

        guard let execution = activeExecutions[identifier] else { return true }
        return !execution.process.isRunning
    }

    private func isRunning(identifier: UUID) -> Bool {
        activeExecutions[identifier]?.process.isRunning == true
    }

    private func sendSignal(_ signal: Int32, to execution: ActiveExecution) {
        let rootIdentifier = execution.process.processIdentifier

        if let groupIdentifier = execution.control.processGroupIdentifier {
            _ = Darwin.kill(-groupIdentifier, signal)
            return
        }

        let currentDescendants = Self.descendantProcessIdentifiers(of: rootIdentifier)
        let knownDescendants = execution.control.recordDescendants(currentDescendants)

        _ = Darwin.kill(rootIdentifier, signal)
        for identifier in knownDescendants where identifier != rootIdentifier {
            _ = Darwin.kill(identifier, signal)
        }
    }

    private nonisolated static func termination(
        for process: Process,
        requestedTermination: RequestedTermination?
    ) -> ProcessTermination {
        switch requestedTermination {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case nil:
            switch process.terminationReason {
            case .exit:
                return .exited(process.terminationStatus)
            case .uncaughtSignal:
                return .uncaughtSignal(process.terminationStatus)
            @unknown default:
                return .uncaughtSignal(process.terminationStatus)
            }
        }
    }

    private nonisolated static func descendantProcessIdentifiers(of root: pid_t) -> Set<pid_t> {
        var discovered: Set<pid_t> = []
        var pending = [root]

        while let parent = pending.popLast() {
            for child in immediateChildProcessIdentifiers(of: parent)
            where child > 0 && discovered.insert(child).inserted {
                pending.append(child)
            }
        }

        return discovered
    }

    private nonisolated static func immediateChildProcessIdentifiers(of parent: pid_t) -> [pid_t] {
        var capacity = 16

        while capacity <= 4_096 {
            var identifiers = [pid_t](repeating: 0, count: capacity)
            let count = identifiers.withUnsafeMutableBytes { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
            }

            guard count >= 0 else { return [] }
            if count < capacity {
                return Array(identifiers.prefix(Int(count)))
            }
            capacity *= 2
        }

        return []
    }

    private nonisolated static func commandEnvironment(
        for configuration: ProcessEnvironment
    ) -> [String: String] {
        var environment = configuration.inheritsParent
            ? ProcessInfo.processInfo.environment
            : [:]

        environment.merge(configuration.overrides) { _, newValue in newValue }
        for key in configuration.removedKeys {
            environment.removeValue(forKey: key)
        }

        let userHomePath = FileManager.default.homeDirectoryForCurrentUser.path
        let preferredPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(userHomePath)/.local/bin",
            "\(userHomePath)/.opencode/bin",
            "\(userHomePath)/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existingPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        var seenPaths: Set<String> = []
        environment["PATH"] = (preferredPaths + existingPaths)
            .filter { !$0.isEmpty && seenPaths.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }
}

private final class ProcessControl: Sendable {
    // Foundation invokes termination callbacks outside actor isolation. This lock is the
    // single owner of callback-visible termination and descendant-process state.
    private struct State: Sendable {
        var requestedTermination: ProcessRunner.RequestedTermination?
        var processGroupIdentifier: pid_t?
        var knownDescendants: Set<pid_t> = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var requestedTermination: ProcessRunner.RequestedTermination? {
        lock.withLock { $0.requestedTermination }
    }

    var processGroupIdentifier: pid_t? {
        lock.withLock { $0.processGroupIdentifier }
    }

    func requestTermination(_ termination: ProcessRunner.RequestedTermination) -> Bool {
        lock.withLock { state in
            guard state.requestedTermination == nil else { return false }
            state.requestedTermination = termination
            return true
        }
    }

    func setProcessGroupIdentifier(_ identifier: pid_t) {
        lock.withLock { $0.processGroupIdentifier = identifier }
    }

    func recordDescendants(_ identifiers: Set<pid_t>) -> Set<pid_t> {
        lock.withLock { state in
            state.knownDescendants.formUnion(identifiers)
            return state.knownDescendants
        }
    }
}

private final class ProcessEventSink: Sendable {
    // stdout and stderr callbacks can arrive concurrently, so all continuation access and
    // dropped-event accounting is serialized through this lock.
    private struct State: Sendable {
        let continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation
        var droppedEventCount = 0
        var isFinished = false
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation) {
        lock = OSAllocatedUnfairLock(initialState: State(continuation: continuation))
    }

    func yield(_ event: ProcessEvent) {
        lock.withLock { state in
            guard !state.isFinished else { return }

            if state.droppedEventCount > 0 {
                let droppedCount = state.droppedEventCount
                state.droppedEventCount = 0
                record(
                    state.continuation.yield(
                        .outputTruncated(droppedEventCount: droppedCount)
                    ),
                    in: &state
                )
            }

            record(state.continuation.yield(event), in: &state)
        }
    }

    func finish(with termination: ProcessTermination) {
        lock.withLock { state in
            guard !state.isFinished else { return }

            if state.droppedEventCount > 0 {
                _ = state.continuation.yield(
                    .outputTruncated(droppedEventCount: state.droppedEventCount)
                )
            }
            _ = state.continuation.yield(.finished(termination))
            state.continuation.finish()
            state.isFinished = true
        }
    }

    func fail(with error: Error) {
        lock.withLock { state in
            guard !state.isFinished else { return }
            state.continuation.finish(throwing: error)
            state.isFinished = true
        }
    }

    private func record(
        _ result: AsyncThrowingStream<ProcessEvent, Error>.Continuation.YieldResult,
        in state: inout State
    ) {
        switch result {
        case .enqueued:
            break
        case .dropped:
            state.droppedEventCount += 1
        case .terminated:
            state.isFinished = true
        @unknown default:
            state.isFinished = true
        }
    }
}

private final class ProcessOutputEmitter: Sendable {
    // The lock keeps FileHandle reads, incremental UTF-8 state, and the final drain ordered
    // for one output channel. No await occurs while the lock is held.
    private struct State: Sendable {
        var decoder = UTF8ChunkDecoder()
        var isFinished = false
    }

    private let channel: ProcessOutputChannel
    private let sink: ProcessEventSink
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(channel: ProcessOutputChannel, sink: ProcessEventSink) {
        self.channel = channel
        self.sink = sink
    }

    func consumeAvailableData(from handle: FileHandle) {
        lock.withLock { state in
            guard !state.isFinished else { return }
            let data = handle.availableData

            if data.isEmpty {
                state.isFinished = true
                emit(state.decoder.finish())
                return
            }

            emit(state.decoder.decode(data))
        }
    }

    func finish(from handle: FileHandle) {
        lock.withLock { state in
            guard !state.isFinished else { return }
            let remainingData = handle.readDataToEndOfFile()
            var output = state.decoder.decode(remainingData)
            output += state.decoder.finish()
            state.isFinished = true
            emit(output)
        }
        try? handle.close()
    }

    private func emit(_ value: String?) {
        guard let value, !value.isEmpty else { return }

        switch channel {
        case .standardOutput:
            sink.yield(.standardOutput(value))
        case .standardError:
            sink.yield(.standardError(value))
        }
    }
}

struct UTF8ChunkDecoder: Sendable {
    private var pendingBytes: [UInt8] = []

    mutating func decode(_ data: Data) -> String {
        pendingBytes.append(contentsOf: data)
        let emissionEnd = completePrefixEnd(in: pendingBytes)
        guard emissionEnd > 0 else { return "" }

        let emittedBytes = pendingBytes[..<emissionEnd]
        pendingBytes.removeFirst(emissionEnd)
        return String(decoding: emittedBytes, as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pendingBytes.removeAll(keepingCapacity: false) }
        return String(decoding: pendingBytes, as: UTF8.self)
    }

    private func completePrefixEnd(in bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }

        var leadIndex = bytes.count - 1
        while leadIndex >= 0, bytes[leadIndex] & 0b1100_0000 == 0b1000_0000 {
            leadIndex -= 1
        }

        guard leadIndex >= 0 else {
            return bytes.count
        }

        let expectedLength: Int
        switch bytes[leadIndex] {
        case 0x00...0x7F:
            expectedLength = 1
        case 0xC2...0xDF:
            expectedLength = 2
        case 0xE0...0xEF:
            expectedLength = 3
        case 0xF0...0xF4:
            expectedLength = 4
        default:
            return bytes.count
        }

        let availableLength = bytes.count - leadIndex
        return availableLength < expectedLength ? leadIndex : bytes.count
    }
}

private struct BoundedTextAccumulator {
    private let limit: Int
    private var chunks: [String] = []
    private var byteCount = 0
    private(set) var wasTruncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    var value: String {
        chunks.joined()
    }

    mutating func append(_ value: String) {
        guard !value.isEmpty, !wasTruncated else { return }
        let remainingCapacity = limit - byteCount
        guard remainingCapacity > 0 else {
            wasTruncated = true
            return
        }

        let valueByteCount = value.utf8.count
        if valueByteCount <= remainingCapacity {
            chunks.append(value)
            byteCount += valueByteCount
            return
        }

        var prefix = ""
        prefix.reserveCapacity(remainingCapacity)
        var prefixByteCount = 0

        for scalar in value.unicodeScalars {
            let scalarText = String(scalar)
            let scalarByteCount = scalarText.utf8.count
            guard prefixByteCount + scalarByteCount <= remainingCapacity else { break }
            prefix.unicodeScalars.append(scalar)
            prefixByteCount += scalarByteCount
        }

        if !prefix.isEmpty {
            chunks.append(prefix)
            byteCount += prefixByteCount
        }
        wasTruncated = true
    }
}
