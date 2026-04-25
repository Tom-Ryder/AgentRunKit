@testable import AgentRunKit
import Foundation
import Testing

struct ToolDefinitionTests {
    @Test
    func createsFromTool() throws {
        let tool = try Tool<TestParams, TestOutput, EmptyContext>(
            name: "double",
            description: "Doubles a value",
            executor: { params, _ in TestOutput(result: params.value * 2) }
        )
        let def = ToolDefinition(tool)
        #expect(def.name == "double")
        #expect(def.description == "Doubles a value")
        guard case let .object(props, required, _) = def.parametersSchema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(required == ["value"])
        #expect(props["value"] != nil)
    }
}
