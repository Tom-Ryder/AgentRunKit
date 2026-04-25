import Foundation

/// Persists and loads agent checkpoints by checkpoint and session identity.
public protocol AgentCheckpointer: Sendable {
    func save(_ checkpoint: AgentCheckpoint) async throws
    func load(_ id: CheckpointID) async throws -> AgentCheckpoint
    func list(session: SessionID) async throws -> [CheckpointID]
}
