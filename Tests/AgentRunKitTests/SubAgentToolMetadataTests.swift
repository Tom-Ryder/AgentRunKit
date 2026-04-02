@testable import AgentRunKit
import Foundation
import Testing

private struct MetadataQueryParams: Codable, SchemaProviding {
    let query: String

    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

struct SubAgentToolMetadataTests {
    @Test
    func metadataDefaults() throws {
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: MockLLMClient(responses: []), tools: [])
        let tool = try SubAgentTool<MetadataQueryParams, EmptyContext>(
            name: "research",
            description: "Research tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        #expect(tool.isConcurrencySafe == false)
        #expect(tool.isReadOnly == false)
        #expect(tool.maxResultCharacters == nil)
    }

    @Test
    func helperPreservesMetadataOverrides() throws {
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: MockLLMClient(responses: []), tools: [])
        let tool: SubAgentTool<MetadataQueryParams, EmptyContext> = try subAgentTool(
            name: "research",
            description: "Research tool",
            agent: childAgent,
            isConcurrencySafe: true,
            isReadOnly: true,
            maxResultCharacters: 500,
            messageBuilder: { $0.query }
        )

        #expect(tool.isConcurrencySafe == true)
        #expect(tool.isReadOnly == true)
        #expect(tool.maxResultCharacters == 500)
    }
}
