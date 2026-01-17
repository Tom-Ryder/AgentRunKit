import Foundation

public struct ReasoningContent: Sendable, Equatable, Codable {
    public let content: String
    public let signature: String?

    public init(content: String, signature: String? = nil) {
        self.content = content
        self.signature = signature
    }
}
