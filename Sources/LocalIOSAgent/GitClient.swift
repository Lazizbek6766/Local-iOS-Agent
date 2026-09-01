import Foundation

enum GitFileChangeKind: Sendable, Equatable {
    case added
    case modified
    case deleted
    case renamed
    case copied
}

enum GitChangeOrigin: Sendable, Equatable {
    case preExisting
    case agent
    case agentModifiedPreExisting
}

struct GitLineStatistics: Sendable, Equatable {
    let additions: Int?
    let deletions: Int?

    var isBinary: Bool {
        additions == nil || deletions == nil
    }
}

struct GitFileChange: Identifiable, Sendable, Equatable {
    var id: String { path }

    let path: String
    let previousPath: String?
    let statusCode: String
    let kind: GitFileChangeKind
    let origin: GitChangeOrigin
    let statistics: GitLineStatistics
    let isUntracked: Bool
}

struct GitFileSnapshotState: Sendable, Equatable {
    let statusCode: String
    let previousPath: String?
    let worktreeObjectID: String?
}

struct GitSnapshot: Sendable, Equatable {
    let repositoryRoot: URL
    let capturedAt: Date
    let states: [String: GitFileSnapshotState]
}

struct GitChangeReport: Sendable, Equatable {
    let repositoryRoot: URL
    let baselineCapturedAt: Date?
    let inspectedAt: Date
    let changes: [GitFileChange]

    var agentChangeCount: Int {
        changes.count { $0.origin != .preExisting }
    }

    var preExistingChangeCount: Int {
        changes.count { $0.origin == .preExisting }
    }

    var totalAdditions: Int {
        changes.compactMap(\.statistics.additions).reduce(0, +)
    }

    var totalDeletions: Int {
        changes.compactMap(\.statistics.deletions).reduce(0, +)
    }
}

struct GitDiff: Sendable, Equatable {
    let path: String
    let content: String
    let isBinary: Bool
    let wasTruncated: Bool
}

enum GitClientError: LocalizedError, Sendable, Equatable {
    case notRepository(String)
    case invalidRepositoryRoot
    case snapshotRepositoryChanged
    case commandFailed(operation: String, detail: String)
    case outputTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .notRepository:
            "Tanlangan loyiha Git repository emas."
        case .invalidRepositoryRoot:
            "Git repository ildizini aniqlab bo‘lmadi."
        case .snapshotRepositoryChanged:
            "Git snapshot boshqa repository uchun olingan."
        case .commandFailed(let operation, let detail):
            "Git \(operation) bajarilmadi: \(detail)"
        case .outputTooLarge(let operation):
            "Git \(operation) natijasi xavfsiz limitdan oshdi."
        }
    }
}

protocol GitInspecting: Sendable {
    func captureSnapshot(at projectURL: URL) async throws -> GitSnapshot
    func changes(at projectURL: URL, since baseline: GitSnapshot?) async throws -> GitChangeReport
    func diff(
        for change: GitFileChange,
        in repositoryRoot: URL,
        outputLimit: Int
    ) async throws -> GitDiff
}

actor GitClient: GitInspecting {
    private struct StatusEntry: Sendable, Equatable {
        let path: String
        let previousPath: String?
        let statusCode: String

        var isUntracked: Bool {
            statusCode == "??"
        }

        var kind: GitFileChangeKind {
            if statusCode.contains("R") { return .renamed }
            if statusCode.contains("C") { return .copied }
            if isUntracked || statusCode.first == "A" || statusCode.last == "A" {
                return .added
            }
            if statusCode.contains("D") { return .deleted }
            return .modified
        }
    }

    private let runner: any ProcessRunning
    private let commandTimeout: Duration

    init(
        runner: any ProcessRunning,
        commandTimeout: Duration = .seconds(15)
    ) {
        self.runner = runner
        self.commandTimeout = commandTimeout
    }

    func captureSnapshot(at projectURL: URL) async throws -> GitSnapshot {
        let repositoryRoot = try await repositoryRoot(for: projectURL)
        let entries = try await statusEntries(in: repositoryRoot)
        let states = try await snapshotStates(for: entries, in: repositoryRoot)
        return GitSnapshot(
            repositoryRoot: repositoryRoot,
            capturedAt: Date(),
            states: states
        )
    }

    func changes(
        at projectURL: URL,
        since baseline: GitSnapshot?
    ) async throws -> GitChangeReport {
        let repositoryRoot = try await repositoryRoot(for: projectURL)
        if let baseline,
           baseline.repositoryRoot.standardizedFileURL != repositoryRoot.standardizedFileURL {
            throw GitClientError.snapshotRepositoryChanged
        }

        let entries = try await statusEntries(in: repositoryRoot)
        let currentStates = try await snapshotStates(for: entries, in: repositoryRoot)
        let repositoryHasHead = try await hasHead(in: repositoryRoot)
        var changes: [GitFileChange] = []
        changes.reserveCapacity(entries.count)

        for entry in entries {
            try Task.checkCancellation()
            let state = currentStates[entry.path]
            let baselineState = baseline?.states[entry.path]
                ?? entry.previousPath.flatMap { baseline?.states[$0] }
            let origin: GitChangeOrigin

            if baseline == nil || baselineState == state {
                origin = .preExisting
            } else if baselineState == nil {
                origin = .agent
            } else {
                origin = .agentModifiedPreExisting
            }

            let statistics = try await lineStatistics(
                for: entry,
                in: repositoryRoot,
                repositoryHasHead: repositoryHasHead
            )
            changes.append(
                GitFileChange(
                    path: entry.path,
                    previousPath: entry.previousPath,
                    statusCode: entry.statusCode,
                    kind: entry.kind,
                    origin: origin,
                    statistics: statistics,
                    isUntracked: entry.isUntracked
                )
            )
        }

        changes.sort { lhs, rhs in
            if lhs.origin != rhs.origin {
                return lhs.origin.sortPriority < rhs.origin.sortPriority
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }

        return GitChangeReport(
            repositoryRoot: repositoryRoot,
            baselineCapturedAt: baseline?.capturedAt,
            inspectedAt: Date(),
            changes: changes
        )
    }

    func diff(
        for change: GitFileChange,
        in repositoryRoot: URL,
        outputLimit: Int = 1_048_576
    ) async throws -> GitDiff {
        let hasRepositoryHead = try await hasHead(in: repositoryRoot)
        let fileURL = repositoryRoot.appendingPathComponent(change.path)
        let shouldUseNoIndex = change.isUntracked
            || (!hasRepositoryHead && change.kind == .added)
        let arguments: [String]
        let allowedExitCodes: Set<Int32>

        if shouldUseNoIndex {
            arguments = [
                "-C", repositoryRoot.path,
                "diff", "--no-index", "--no-ext-diff", "--no-color", "--unified=3",
                "--", "/dev/null", fileURL.path,
            ]
            allowedExitCodes = [0, 1]
        } else {
            arguments = [
                "-C", repositoryRoot.path,
                "diff", "--no-ext-diff", "--no-color", "--unified=3",
                "HEAD", "--", change.path,
            ]
            allowedExitCodes = [0]
        }

        let result = try await runGit(
            arguments,
            operation: "diff",
            outputLimit: max(65_536, outputLimit),
            allowedExitCodes: allowedExitCodes,
            permitsTruncation: true
        )
        let wasTruncated = result.outputWasTruncated || result.streamWasTruncated
        let marker = wasTruncated
            ? "\n\n— Diff xavfsiz ko‘rsatish limiti sabab qisqartirildi. —"
            : ""
        let content = result.output.isEmpty
            ? "Bu fayl uchun matnli diff mavjud emas."
            : result.output + marker

        return GitDiff(
            path: change.path,
            content: content,
            isBinary: change.statistics.isBinary || content.contains("Binary files"),
            wasTruncated: wasTruncated
        )
    }

    private func repositoryRoot(for projectURL: URL) async throws -> URL {
        let result: CommandResult
        do {
            result = try await runGit(
                ["-C", projectURL.path, "rev-parse", "--show-toplevel"],
                operation: "repository tekshiruvi",
                outputLimit: 65_536
            )
        } catch GitClientError.commandFailed(_, let detail)
            where detail.localizedCaseInsensitiveContains("not a git repository") {
            throw GitClientError.notRepository(projectURL.path)
        }

        guard let rootPath = result.output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init),
            !rootPath.isEmpty else {
            throw GitClientError.invalidRepositoryRoot
        }
        return URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
    }

    private func statusEntries(in repositoryRoot: URL) async throws -> [StatusEntry] {
        let result = try await runGit(
            [
                "-C", repositoryRoot.path,
                "status", "--porcelain=v1", "-z", "--untracked-files=all",
            ],
            operation: "status",
            outputLimit: 8_388_608
        )
        return try Self.parseStatus(result.output)
    }

    private func snapshotStates(
        for entries: [StatusEntry],
        in repositoryRoot: URL
    ) async throws -> [String: GitFileSnapshotState] {
        var states: [String: GitFileSnapshotState] = [:]
        states.reserveCapacity(entries.count)

        for entry in entries {
            try Task.checkCancellation()
            let objectID = try await worktreeObjectID(for: entry.path, in: repositoryRoot)
            states[entry.path] = GitFileSnapshotState(
                statusCode: entry.statusCode,
                previousPath: entry.previousPath,
                worktreeObjectID: objectID
            )
        }
        return states
    }

    private func worktreeObjectID(
        for path: String,
        in repositoryRoot: URL
    ) async throws -> String? {
        var isDirectory: ObjCBool = false
        let fileURL = repositoryRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        let result = try await runGit(
            ["-C", repositoryRoot.path, "hash-object", "--", path],
            operation: "fayl fingerprinti",
            outputLimit: 65_536
        )
        return result.output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)
    }

    private func hasHead(in repositoryRoot: URL) async throws -> Bool {
        let result = try await runGit(
            ["-C", repositoryRoot.path, "rev-parse", "--verify", "HEAD"],
            operation: "HEAD tekshiruvi",
            outputLimit: 65_536,
            allowedExitCodes: [0, 128]
        )
        return result.termination.exitCode == 0
    }

    private func lineStatistics(
        for entry: StatusEntry,
        in repositoryRoot: URL,
        repositoryHasHead: Bool
    ) async throws -> GitLineStatistics {
        let fileURL = repositoryRoot.appendingPathComponent(entry.path)
        let shouldUseNoIndex = entry.isUntracked
            || (!repositoryHasHead && entry.kind == .added)
        let arguments: [String]
        let allowedExitCodes: Set<Int32>

        if shouldUseNoIndex {
            arguments = [
                "-C", repositoryRoot.path,
                "diff", "--no-index", "--numstat", "--", "/dev/null", fileURL.path,
            ]
            allowedExitCodes = [0, 1]
        } else if repositoryHasHead {
            arguments = [
                "-C", repositoryRoot.path,
                "diff", "--numstat", "HEAD", "--", entry.path,
            ]
            allowedExitCodes = [0]
        } else {
            return GitLineStatistics(additions: nil, deletions: nil)
        }

        let result = try await runGit(
            arguments,
            operation: "qatorlar statistikasi",
            outputLimit: 262_144,
            allowedExitCodes: allowedExitCodes
        )
        return Self.parseLineStatistics(result.output)
    }

    private func runGit(
        _ arguments: [String],
        operation: String,
        outputLimit: Int,
        allowedExitCodes: Set<Int32> = [0],
        permitsTruncation: Bool = false
    ) async throws -> CommandResult {
        let result = try await runner.runAndCollect(
            CommandSpec(
                executable: "git",
                arguments: arguments,
                timeout: commandTimeout
            ),
            outputLimit: outputLimit
        )
        guard let exitCode = result.termination.exitCode,
              allowedExitCodes.contains(exitCode) else {
            let detail = result.errorOutput
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)
                ?? result.termination.failureDescription
            throw GitClientError.commandFailed(operation: operation, detail: detail)
        }
        if !permitsTruncation,
           result.outputWasTruncated || result.streamWasTruncated {
            throw GitClientError.outputTooLarge(operation)
        }
        return result
    }

    private static func parseStatus(_ output: String) throws -> [StatusEntry] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true)
        var entries: [StatusEntry] = []
        var index = 0

        while index < records.count {
            let record = String(records[index])
            guard record.count >= 4 else {
                throw GitClientError.commandFailed(
                    operation: "status parseri",
                    detail: "Git status yozuvi noto‘liq."
                )
            }
            let statusCode = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            var previousPath: String?

            if statusCode.contains("R") || statusCode.contains("C") {
                index += 1
                guard index < records.count else {
                    throw GitClientError.commandFailed(
                        operation: "status parseri",
                        detail: "Rename/copy manba yo‘li topilmadi."
                    )
                }
                previousPath = String(records[index])
            }

            entries.append(
                StatusEntry(
                    path: path,
                    previousPath: previousPath,
                    statusCode: statusCode
                )
            )
            index += 1
        }
        return entries
    }

    private static func parseLineStatistics(_ output: String) -> GitLineStatistics {
        guard let line = output.split(whereSeparator: \.isNewline).first else {
            return GitLineStatistics(additions: 0, deletions: 0)
        }
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2 else {
            return GitLineStatistics(additions: nil, deletions: nil)
        }
        return GitLineStatistics(
            additions: Int(fields[0]),
            deletions: Int(fields[1])
        )
    }
}

private extension GitChangeOrigin {
    var sortPriority: Int {
        switch self {
        case .agent, .agentModifiedPreExisting:
            0
        case .preExisting:
            1
        }
    }
}
