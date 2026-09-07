import Foundation

/// The text or decoded binary body of an embedded MCP resource.
///
/// Decoding prefers a valid text representation when a resource provides both text and blob fields.
public enum MCPResourceContent: Sendable, Equatable {
    case text(String)
    case blob(Data)
}
