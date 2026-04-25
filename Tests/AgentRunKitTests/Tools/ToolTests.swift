@testable import AgentRunKit
import Foundation
import Testing

struct TestParams: Codable, SchemaProviding {
    let value: Int

    static var jsonSchema: JSONSchema {
        .object(properties: ["value": .integer()], required: ["value"])
    }
}

struct TestOutput: Codable, Equatable {
    let result: Int
}

enum TestExecutorError: Error {
    case intentionalFailure
}

struct ToolTests {
    @Test
    func executeWithValidArguments() async throws {
        let tool = try Tool<TestParams, TestOutput, EmptyContext>(
            name: "double",
            description: "Doubles a number",
            executor: { params, _ in TestOutput(result: params.value * 2) }
        )

        let args = try JSONEncoder().encode(TestParams(value: 5))
        let result = try await tool.execute(arguments: args, context: EmptyContext())

        #expect(result.isError == false)
        let output = try JSONDecoder().decode(TestOutput.self, from: Data(result.content.utf8))
        #expect(output.result == 10)
    }

    @Test
    func executeWithInvalidArguments() async throws {
        let tool = try Tool<TestParams, TestOutput, EmptyContext>(
            name: "double",
            description: "Doubles a number",
            executor: { params, _ in TestOutput(result: params.value * 2) }
        )

        let badArgs = Data("{}".utf8)
        do {
            _ = try await tool.execute(arguments: badArgs, context: EmptyContext())
            Issue.record("Expected error to be thrown")
        } catch let error as AgentError {
            guard case let .toolDecodingFailed(toolName, _) = error else {
                Issue.record("Expected toolDecodingFailed, got \(error)")
                return
            }
            #expect(toolName == "double")
        } catch {
            Issue.record("Expected AgentError, got \(error)")
        }
    }

    @Test
    func toolProvidesSchema() throws {
        let tool = try Tool<TestParams, TestOutput, EmptyContext>(
            name: "test",
            description: "Test tool",
            executor: { _, _ in TestOutput(result: 0) }
        )

        guard case let .object(props, required, _) = tool.parametersSchema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(required == ["value"])
        guard case .integer = props["value"] else {
            Issue.record("Expected integer schema for 'value'")
            return
        }
    }

    @Test
    func asyncExecutor() async throws {
        let tool = try Tool<TestParams, TestOutput, EmptyContext>(
            name: "async_tool",
            description: "Async operation",
            executor: { params, _ in
                try await Task.sleep(for: .milliseconds(10))
                return TestOutput(result: params.value + 1)
            }
        )

        let args = try JSONEncoder().encode(TestParams(value: 42))
        let result = try await tool.execute(arguments: args, context: EmptyContext())
        let output = try JSONDecoder().decode(TestOutput.self, from: Data(result.content.utf8))
        #expect(output.result == 43)
    }

    @Test
    func executorCanThrow() async throws {
        let tool = try Tool<TestParams, TestOutput, EmptyContext>(
            name: "failing",
            description: "Always fails",
            executor: { _, _ in throw TestExecutorError.intentionalFailure }
        )

        let args = try JSONEncoder().encode(TestParams(value: 1))
        do {
            _ = try await tool.execute(arguments: args, context: EmptyContext())
            Issue.record("Expected error to be thrown")
        } catch let error as AgentError {
            guard case let .toolExecutionFailed(toolName, _) = error else {
                Issue.record("Expected toolExecutionFailed, got \(error)")
                return
            }
            #expect(toolName == "failing")
        } catch {
            Issue.record("Expected AgentError, got \(error)")
        }
    }

    @Test
    func agentErrorPassesThroughUnwrapped() async throws {
        let tool = try Tool<TestParams, TestOutput, EmptyContext>(
            name: "inner",
            description: "Throws AgentError",
            executor: { _, _ in throw AgentError.toolTimeout(tool: "inner") }
        )
        let args = try JSONEncoder().encode(TestParams(value: 1))
        do {
            _ = try await tool.execute(arguments: args, context: EmptyContext())
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .toolTimeout(toolName) = error else {
                Issue.record("Expected toolTimeout, got \(error)")
                return
            }
            #expect(toolName == "inner")
        }
    }

    @Test
    func encodingFailureWrapped() async throws {
        let tool = try Tool<TestParams, UnencodableOutput, EmptyContext>(
            name: "bad_encoder",
            description: "Returns unencodable output",
            executor: { _, _ in UnencodableOutput(value: 42) }
        )
        let args = try JSONEncoder().encode(TestParams(value: 1))
        do {
            _ = try await tool.execute(arguments: args, context: EmptyContext())
            Issue.record("Expected error to be thrown")
        } catch let error as AgentError {
            guard case let .toolEncodingFailed(toolName, _) = error else {
                Issue.record("Expected toolEncodingFailed, got \(error)")
                return
            }
            #expect(toolName == "bad_encoder")
        } catch {
            Issue.record("Expected AgentError, got \(error)")
        }
    }

    @Test
    func schemaInferenceFailureThrows() throws {
        do {
            _ = try Tool<UnsupportedFieldParams, TestOutput, EmptyContext>(
                name: "bad_schema",
                description: "Has unsupported field type",
                executor: { _, _ in TestOutput(result: 0) }
            )
            Issue.record("Expected error to be thrown")
        } catch let error as AgentError {
            guard case let .schemaInferenceFailed(typeName, _) = error else {
                Issue.record("Expected schemaInferenceFailed, got \(error)")
                return
            }
            #expect(typeName == "UnsupportedFieldParams")
        }
    }
}

struct UnencodableOutput: Codable {
    let value: Double

    func encode(to _: any Encoder) throws {
        throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Test failure"))
    }

    init(from _: any Decoder) throws {
        value = 0
    }

    init(value: Double) {
        self.value = value
    }
}

struct UnsupportedFieldParams: Codable, SchemaProviding {
    init() {}

    init(from decoder: any Decoder) throws {
        _ = try decoder.singleValueContainer()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("placeholder")
    }
}

struct ToolClassificationTests {
    @Test
    func classificationDefaults() throws {
        let tool = try Tool<TestParams, TestOutput, EmptyContext>(
            name: "test", description: "Test",
            executor: { params, _ in TestOutput(result: params.value) }
        )
        #expect(tool.isConcurrencySafe == false)
        #expect(tool.isReadOnly == false)
        #expect(tool.maxResultCharacters == nil)
    }

    @Test
    func classificationCustomValues() throws {
        let tool = try Tool<TestParams, TestOutput, EmptyContext>(
            name: "test", description: "Test",
            isConcurrencySafe: true,
            isReadOnly: true,
            maxResultCharacters: 5000,
            executor: { params, _ in TestOutput(result: params.value) }
        )
        #expect(tool.isConcurrencySafe == true)
        #expect(tool.isReadOnly == true)
        #expect(tool.maxResultCharacters == 5000)
    }

    @Test
    func protocolDefaultsOnDirectConformer() {
        let tool = MinimalClassificationTool()
        #expect(tool.isConcurrencySafe == false)
        #expect(tool.isReadOnly == false)
        #expect(tool.maxResultCharacters == nil)
    }

    @Test
    func existentialPreservesOverrides() {
        let tool: any AnyTool<EmptyContext> = OverriddenClassificationTool()
        #expect(tool.isConcurrencySafe == true)
        #expect(tool.isReadOnly == true)
        #expect(tool.maxResultCharacters == 500)
    }
}

private struct MinimalClassificationTool: AnyTool {
    typealias Context = EmptyContext
    let name = "minimal"
    let description = "Minimal"
    let parametersSchema: JSONSchema = .object(properties: [:], required: [])

    func execute(arguments _: Data, context _: EmptyContext) async throws -> ToolResult {
        .success("ok")
    }
}

private struct OverriddenClassificationTool: AnyTool {
    typealias Context = EmptyContext
    let name = "classified"
    let description = "Classified"
    let parametersSchema: JSONSchema = .object(properties: [:], required: [])
    let isConcurrencySafe = true
    let isReadOnly = true
    let maxResultCharacters: Int? = 500

    func execute(arguments _: Data, context _: EmptyContext) async throws -> ToolResult {
        .success("ok")
    }
}

struct ToolResultTests {
    @Test
    func successFactory() {
        let result = ToolResult.success("done")
        #expect(result.content == "done")
        #expect(result.isError == false)
    }

    @Test
    func errorFactory() {
        let result = ToolResult.error("failed")
        #expect(result.content == "failed")
        #expect(result.isError == true)
    }

    @Test
    func roundTrip() throws {
        let original = ToolResult(content: "test", isError: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded == original)
    }
}
