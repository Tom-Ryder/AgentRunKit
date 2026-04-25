@testable import AgentRunKit
import Foundation
import Testing

private func makeCheckpoint(
    sessionID: SessionID,
    iteration: Int,
    timestamp: Date = Date()
) -> AgentCheckpoint {
    AgentCheckpoint(
        messages: [.user("Hi")],
        iteration: iteration,
        tokenUsage: TokenUsage(input: 1, output: 1),
        sessionID: sessionID,
        runID: RunID(),
        timestamp: timestamp
    )
}

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "agent-checkpointer-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct AgentCheckpointerTests {
    @Test
    func inMemorySaveLoadRoundTrip() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpoint = makeCheckpoint(sessionID: session, iteration: 1)
        try await backend.save(checkpoint)
        let loaded = try await backend.load(checkpoint.checkpointID)
        #expect(loaded.checkpointID == checkpoint.checkpointID)
        #expect(loaded.sessionID == session)
        #expect(loaded.iteration == 1)
    }

    @Test
    func inMemoryLoadMissingThrowsNotFound() async {
        let backend = InMemoryCheckpointer()
        do {
            _ = try await backend.load(CheckpointID())
            Issue.record("Expected notFound")
        } catch AgentCheckpointError.notFound(_) {
        } catch {
            Issue.record("Expected notFound, got \(error)")
        }
    }

    @Test
    func inMemoryListFiltersBySessionAndSortsByIteration() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let other = SessionID()
        let second = makeCheckpoint(sessionID: session, iteration: 2)
        let first = makeCheckpoint(sessionID: session, iteration: 1)
        let otherSession = makeCheckpoint(sessionID: other, iteration: 1)
        try await backend.save(second)
        try await backend.save(first)
        try await backend.save(otherSession)
        let ids = try await backend.list(session: session)
        #expect(ids == [first.checkpointID, second.checkpointID])
    }

    @Test
    func inMemoryListTieBreaksSameIterationByTimestamp() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let earlier = makeCheckpoint(
            sessionID: session, iteration: 1, timestamp: Date(timeIntervalSince1970: 1000)
        )
        let later = makeCheckpoint(
            sessionID: session, iteration: 1, timestamp: Date(timeIntervalSince1970: 2000)
        )
        try await backend.save(later)
        try await backend.save(earlier)
        let ids = try await backend.list(session: session)
        #expect(ids == [earlier.checkpointID, later.checkpointID])
    }

    @Test
    func fileSaveLoadRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FileCheckpointer(directory: dir)
        let session = SessionID()
        let checkpoint = makeCheckpoint(
            sessionID: session,
            iteration: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await backend.save(checkpoint)
        let loaded = try await backend.load(checkpoint.checkpointID)
        #expect(loaded.checkpointID == checkpoint.checkpointID)
        #expect(loaded.sessionID == checkpoint.sessionID)
        #expect(loaded.runID == checkpoint.runID)
        #expect(loaded.iteration == checkpoint.iteration)
        #expect(loaded.messages == checkpoint.messages)
        #expect(loaded.tokenUsage == checkpoint.tokenUsage)
        #expect(loaded.timestamp == checkpoint.timestamp)
    }

    @Test
    func fileListFiltersAndSorts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FileCheckpointer(directory: dir)
        let session = SessionID()
        let other = SessionID()
        let second = makeCheckpoint(sessionID: session, iteration: 2)
        let first = makeCheckpoint(sessionID: session, iteration: 1)
        let otherSession = makeCheckpoint(sessionID: other, iteration: 1)
        try await backend.save(second)
        try await backend.save(first)
        try await backend.save(otherSession)
        let ids = try await backend.list(session: session)
        #expect(ids == [first.checkpointID, second.checkpointID])
    }

    @Test
    func fileLoadMissingThrowsNotFound() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FileCheckpointer(directory: dir)
        do {
            _ = try await backend.load(CheckpointID())
            Issue.record("Expected notFound")
        } catch AgentCheckpointError.notFound(_) {
        } catch {
            Issue.record("Expected notFound, got \(error)")
        }
    }

    @Test
    func fileLoadMalformedJSONThrowsFileSystem() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FileCheckpointer(directory: dir)
        let badID = CheckpointID()
        try await backend.save(makeCheckpoint(sessionID: SessionID(), iteration: 0, timestamp: Date()))
        let badURL = dir
            .appending(path: "checkpoints", directoryHint: .isDirectory)
            .appending(path: "\(badID.rawValue.uuidString).json")
        try Data("not json".utf8).write(to: badURL, options: .atomic)
        do {
            _ = try await backend.load(badID)
            Issue.record("Expected fileSystem error")
        } catch AgentCheckpointError.fileSystem(_) {
        } catch {
            Issue.record("Expected fileSystem error, got \(error)")
        }
    }

    @Test
    func fileSaveCreatesDirectory() async throws {
        let dir = try makeTempDir()
        let nested = dir.appending(path: "nested", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FileCheckpointer(directory: nested)
        let checkpoint = makeCheckpoint(sessionID: SessionID(), iteration: 0)
        try await backend.save(checkpoint)
        let path = nested.appending(path: "checkpoints", directoryHint: .isDirectory).path
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test
    func fileListSkipsUnreadableEntriesButReturnsValidOnes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FileCheckpointer(directory: dir)
        let session = SessionID()
        let valid = makeCheckpoint(sessionID: session, iteration: 1)
        try await backend.save(valid)
        let corruptURL = dir
            .appending(path: "checkpoints", directoryHint: .isDirectory)
            .appending(path: "\(UUID().uuidString).json")
        try Data("garbage".utf8).write(to: corruptURL, options: .atomic)

        let ids = try await backend.list(session: session)
        #expect(ids == [valid.checkpointID])
    }
}
