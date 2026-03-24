import Foundation

public struct FinishArguments: Codable, Sendable {
    public let content: String
    public let reason: String?

    public init(content: String, reason: String? = nil) {
        self.content = content
        self.reason = reason
    }
}
