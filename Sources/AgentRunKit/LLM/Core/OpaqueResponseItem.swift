import Foundation

/// A response item or stream event whose type the client does not recognize,
/// preserved verbatim for forward compatibility.
public struct OpaqueResponseItem: Sendable, Equatable {
    public let provider: String
    public let type: String
    public let raw: JSONValue

    public init(provider: String, type: String, raw: JSONValue) {
        self.provider = provider
        self.type = type
        self.raw = raw
    }
}
