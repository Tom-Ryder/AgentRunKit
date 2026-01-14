import Foundation

public struct ToolCall: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var argumentsData: Data {
        Data(arguments.utf8)
    }
}
