import Foundation

/// Metadata for a tool discovered from an MCP server.
public struct MCPToolInfo: Sendable, Equatable, Decodable {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchema

    public init(name: String, description: String, inputSchema: JSONSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        inputSchema = (try? container.decode(JSONSchema.self, forKey: .inputSchema))
            ?? .object(properties: [:], required: [])
    }
}
