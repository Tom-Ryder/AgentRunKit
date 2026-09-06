@testable import AgentRunKit

struct HTTPJSONTestParameters: Codable, SchemaProviding, Equatable {
    let zeta: [Entry]
    let alpha: String

    struct Entry: Codable, Equatable {
        let zeta: Bool
        let alpha: String
    }

    static let schemaJSON = #"{"additionalProperties":false,"properties":{"alpha":{"type":"string"},"#
        + #""zeta":{"items":{"additionalProperties":false,"properties":{"alpha":{"type":"string"},"#
        + #""zeta":{"type":"boolean"}},"required":["zeta","alpha"],"type":"object"},"type":"array"}},"#
        + #""required":["zeta","alpha"],"type":"object"}"#

    static let geminiSchemaJSON = #"{"properties":{"alpha":{"type":"string"},"zeta":{"items":{"properties":{"#
        + #""alpha":{"type":"string"},"zeta":{"type":"boolean"}},"required":["zeta","alpha"],"type":"object"},"#
        + #""type":"array"}},"required":["zeta","alpha"],"type":"object"}"#
}
