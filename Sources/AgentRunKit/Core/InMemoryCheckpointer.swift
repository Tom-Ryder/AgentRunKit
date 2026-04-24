import Foundation

/// In-process checkpointer that stores checkpoints in actor-protected memory.
public actor InMemoryCheckpointer: AgentCheckpointer {
    private var storage: [CheckpointID: AgentCheckpoint] = [:]

    public init() {}

    public func save(_ checkpoint: AgentCheckpoint) async throws {
        storage[checkpoint.checkpointID] = checkpoint
    }

    public func load(_ id: CheckpointID) async throws -> AgentCheckpoint {
        guard let checkpoint = storage[id] else {
            throw AgentCheckpointError.notFound(id)
        }
        return checkpoint
    }

    public func list(session: SessionID) async throws -> [CheckpointID] {
        storage.values
            .filter { $0.sessionID == session }
            .sorted { lhs, rhs in
                if lhs.iteration != rhs.iteration { return lhs.iteration < rhs.iteration }
                return lhs.timestamp < rhs.timestamp
            }
            .map(\.checkpointID)
    }
}
