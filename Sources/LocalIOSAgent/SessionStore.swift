import Foundation

protocol SessionStoring: Sendable {
    func loadSessions() async throws -> [AgentSession]
    func saveSessions(_ sessions: [AgentSession]) async throws
}

actor FileSessionStore: SessionStoring {
    private struct Archive: Codable, Sendable {
        let schemaVersion: Int
        let sessions: [AgentSession]
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let maximumSessionCount: Int

    init(
        fileURL: URL = FileSessionStore.defaultFileURL(),
        fileManager: FileManager = .default,
        maximumSessionCount: Int = 50
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.maximumSessionCount = max(1, maximumSessionCount)
    }

    func loadSessions() throws -> [AgentSession] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            let archive = try Self.decoder.decode(Archive.self, from: data)
            guard archive.schemaVersion == 1 else {
                throw SessionStoreError.unsupportedSchema(archive.schemaVersion)
            }
            return archive.sessions.sorted { $0.updatedAt > $1.updatedAt }
        } catch let error as SessionStoreError {
            throw error
        } catch {
            throw SessionStoreError.unreadableArchive(error.localizedDescription)
        }
    }

    func saveSessions(_ sessions: [AgentSession]) throws {
        let directory = fileURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let retained = sessions
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(maximumSessionCount)
            let archive = Archive(schemaVersion: 1, sessions: Array(retained))
            let data = try Self.encoder.encode(archive)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw SessionStoreError.writeFailed(error.localizedDescription)
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("LocalIOSAgent", isDirectory: true)
            .appendingPathComponent("sessions-v1.json", isDirectory: false)
    }

    private nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum SessionStoreError: LocalizedError, Sendable, Equatable {
    case unsupportedSchema(Int)
    case unreadableArchive(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Sessiya faylining \(version)-versiyasi qo‘llab-quvvatlanmaydi."
        case .unreadableArchive(let detail):
            "Saqlangan sessiyalarni o‘qib bo‘lmadi: \(detail)"
        case .writeFailed(let detail):
            "Sessiyalarni saqlab bo‘lmadi: \(detail)"
        }
    }
}
