import Foundation
import Testing
@testable import LocalIOSAgent

@Suite("Session store", .serialized)
struct SessionStoreTests {
    @Test("Round-trips a versioned session archive")
    func roundTripsArchive() async throws {
        let location = try temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = FileSessionStore(fileURL: location)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let session = AgentSession(
            id: UUID(uuidString: "02000000-0000-0000-0000-000000000001")!,
            openCodeSessionID: "ses_saved",
            title: "Build tekshiruvi",
            projectPath: "/tmp/iOSApp",
            modelName: "ollama/test",
            messages: [
                ChatMessage(
                    id: UUID(uuidString: "02000000-0000-0000-0000-000000000002")!,
                    role: .assistant,
                    content: "Tayyor",
                    createdAt: timestamp
                )
            ],
            createdAt: timestamp,
            updatedAt: timestamp
        )

        try await store.saveSessions([session])
        let loaded = try await store.loadSessions()

        #expect(loaded == [session])
        let source = try String(contentsOf: location, encoding: .utf8)
        #expect(source.contains("\"schemaVersion\" : 1"))
        #expect(source.contains("ses_saved"))
    }

    @Test("Does not overwrite a corrupted archive while loading")
    func preservesCorruptedArchive() async throws {
        let location = try temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let original = Data("not-json".utf8)
        try original.write(to: location)
        let store = FileSessionStore(fileURL: location)

        await #expect(throws: SessionStoreError.self) {
            try await store.loadSessions()
        }
        #expect(try Data(contentsOf: location) == original)
    }

    @Test("Rejects an unsupported schema without rewriting it")
    func rejectsUnsupportedSchema() async throws {
        let location = try temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let original = Data("{\"schemaVersion\":2,\"sessions\":[]}".utf8)
        try original.write(to: location)
        let store = FileSessionStore(fileURL: location)

        await #expect(throws: SessionStoreError.unsupportedSchema(2)) {
            try await store.loadSessions()
        }
        #expect(try Data(contentsOf: location) == original)
    }

    @Test("Retains only the configured number of recent sessions")
    func limitsArchiveSize() async throws {
        let location = try temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = FileSessionStore(fileURL: location, maximumSessionCount: 2)
        let sessions = (0..<3).map { offset in
            AgentSession(
                title: "Session \(offset)",
                modelName: "ollama/test",
                createdAt: Date(timeIntervalSince1970: TimeInterval(offset)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
        }

        try await store.saveSessions(sessions)
        let loaded = try await store.loadSessions()

        #expect(loaded.map(\.title) == ["Session 2", "Session 1"])
    }

    private func temporaryArchiveURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalIOSAgentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sessions.json")
    }
}
