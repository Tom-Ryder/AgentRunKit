import Foundation

/// A type-erased tool that an agent can call.
///
/// For guidance on defining tools, see <doc:DefiningTools>.
public protocol AnyTool<Context>: Sendable {
    associatedtype Context: ToolContext

    var name: String { get }
    var description: String { get }
    var parametersSchema: JSONSchema { get }

    func execute(arguments: Data, context: Context) async throws -> ToolResult
}
