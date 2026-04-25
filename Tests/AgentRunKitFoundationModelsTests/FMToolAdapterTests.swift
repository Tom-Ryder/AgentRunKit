#if canImport(FoundationModels)

    import AgentRunKit
    @testable import AgentRunKitFoundationModels
    import Foundation
    import FoundationModels
    import Testing

    private struct EchoTool: AnyTool {
        typealias Context = EmptyContext
        let name = "echo"
        let description = "Echoes the input"
        let parametersSchema = JSONSchema.object(
            properties: ["message": .string(description: "The message")],
            required: ["message"]
        )

        func execute(arguments: Data, context _: EmptyContext) async throws -> ToolResult {
            let decoded = try JSONDecoder().decode([String: String].self, from: arguments)
            return .success("Echo: \(decoded["message"] ?? "")")
        }
    }

    private struct BadSchemaTool: AnyTool {
        typealias Context = EmptyContext
        let name = "bad"
        let description = "Bad schema"
        let parametersSchema = JSONSchema.string()

        func execute(arguments _: Data, context _: EmptyContext) async throws -> ToolResult {
            .success("")
        }
    }

    @Suite(.serialized) struct FMToolAdapterTests {
        @Test func adapterNameMatchesWrappedTool() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let adapter = try FMToolAdapter(wrapping: EchoTool(), context: EmptyContext())
            #expect(adapter.name == "echo")
            #expect(adapter.description == "Echoes the input")
        }

        @Test func adapterSchemaContainsPropertyTypes() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let adapter = try FMToolAdapter(wrapping: EchoTool(), context: EmptyContext())
            let json = String(describing: adapter.parameters)
            #expect(json.contains("\"message\""))
            #expect(json.contains("\"string\""))
        }

        @Test func adapterWithUnsupportedSchemaThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect(throws: AgentError.self) {
                try FMToolAdapter(wrapping: BadSchemaTool(), context: EmptyContext())
            }
        }

        @Test func toJSONValueString() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let generated = try makeContent(json: #"{"value":"hello"}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["value"] == .string("hello"))
        }

        @Test func toJSONValueInteger() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let generated = try makeContent(json: #"{"count":42}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["count"] == .int(42))
        }

        @Test func toJSONValueDouble() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let generated = try makeContent(json: #"{"score":3.14}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["score"] == .double(3.14))
        }

        @Test func toJSONValueBool() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let generated = try makeContent(json: #"{"flag":true}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["flag"] == .bool(true))
        }

        @Test func toJSONValueArray() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let generated = try makeContent(json: #"{"items":["a","b"]}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["items"] == .array([.string("a"), .string("b")]))
        }

        @Test func toJSONValueRoundTrip() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let generated = try makeContent(json: #"{"name":"test","count":5}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            let data = try JSONEncoder().encode(jsonValue)
            let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
            #expect(decoded["name"] == .string("test"))
            #expect(decoded["count"] == .int(5))
        }

        @Test func toJSONValueNull() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let generated = try makeContent(json: #"{"missing":null}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["missing"] == .null)
        }
    }

    @available(macOS 26, iOS 26, *)
    private func makeContent(json: String) throws -> GeneratedContent {
        try GeneratedContent(json: json)
    }

#endif
