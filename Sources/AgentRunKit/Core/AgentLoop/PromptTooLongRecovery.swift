import Foundation

func withPromptTooLongRecovery<T>(
    operation: () async throws -> T,
    recover: () async throws -> Bool
) async throws -> T {
    do {
        return try await operation()
    } catch let AgentError.llmError(transport) where transport.isPromptTooLong {
        guard try await recover() else {
            throw AgentError.llmError(transport)
        }
        return try await operation()
    }
}
