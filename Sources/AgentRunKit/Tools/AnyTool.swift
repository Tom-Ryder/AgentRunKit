import Foundation

/// A type-erased tool that an agent can call.
///
/// For guidance on defining tools, see <doc:DefiningTools>.
public protocol AnyTool<Context>: Sendable {
    associatedtype Context: ToolContext

    var name: String { get }
    var description: String { get }
    var parametersSchema: JSONSchema { get }

    /// Whether this tool can safely execute concurrently with other tools.
    var isConcurrencySafe: Bool { get }

    /// Per-tool override for the maximum tool result length before truncation, or `nil` to use the global default.
    var maxResultCharacters: Int? { get }

    /// Per-tool override for execution timeout, or `nil` to use the agent or chat default.
    var toolTimeout: Duration? { get }

    /// Whether to request provider-side strict schema enforcement on this tool's arguments.
    var strict: Bool? { get }

    func execute(arguments: Data, context: Context) async throws -> ToolResult
}

public extension AnyTool {
    var isConcurrencySafe: Bool {
        false
    }

    var maxResultCharacters: Int? {
        nil
    }

    var toolTimeout: Duration? {
        nil
    }

    var strict: Bool? {
        nil
    }
}
