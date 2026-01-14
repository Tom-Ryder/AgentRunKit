import Foundation

public struct ToolResult: Sendable, Equatable, Codable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func success(_ content: String) -> ToolResult {
        ToolResult(content: content)
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: true)
    }
}
