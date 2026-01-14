import Foundation

public protocol AnyTool<Context>: Sendable {
    associatedtype Context: ToolContext

    var name: String { get }
    var description: String { get }
    var parametersSchema: JSONSchema { get }

    func execute(arguments: Data, context: Context) async throws -> ToolResult
}
