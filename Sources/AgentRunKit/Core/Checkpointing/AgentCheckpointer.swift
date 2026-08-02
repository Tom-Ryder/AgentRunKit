import Foundation

/// Persists and loads agent checkpoints by checkpoint and session identity.
///
/// Implementations must round-trip every field of ``AgentCheckpoint`` losslessly: resume treats a loaded
/// checkpoint as authoritative, so a dropped ``AgentCheckpoint/terminalOutcome`` silently downgrades a
/// committed terminal run into a live continuation.
public protocol AgentCheckpointer: Sendable {
    func save(_ checkpoint: AgentCheckpoint) async throws
    func load(_ id: CheckpointID) async throws -> AgentCheckpoint
    func list(session: SessionID) async throws -> [CheckpointID]
}
