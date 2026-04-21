@testable import AgentRunKit
import Foundation
import Testing

private struct GeminiStructuredResult: Codable, SchemaProviding, Equatable {
    let answer: String
}

private func encodeRequest(_ request: GeminiRequest) throws -> [String: Any] {
    let data = try JSONEncoder().encode(request)
    let obj = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any] else {
        preconditionFailure("Encoded request is not an object")
    }
    return dict
}

struct GeminiFunctionCallingModeTests {
    private let tools = [ToolDefinition(
        name: "get_weather", description: "",
        parametersSchema: .object(properties: ["city": .string()], required: ["city"])
    )]

    @Test
    func autoMode_isDefault() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-2.5-flash")
        let request = try client.buildRequest(messages: [.user("Hi")], tools: tools)
        let json = try encodeRequest(request)
        let toolConfig = try #require(json["toolConfig"] as? [String: Any])
        let fcc = try #require(toolConfig["functionCallingConfig"] as? [String: Any])
        #expect(fcc["mode"] as? String == "AUTO")
        #expect(fcc["allowedFunctionNames"] == nil)
    }

    @Test
    func anyMode_withAllowedNames_encodes() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-2.5-flash")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: tools,
            functionCallingMode: .any,
            allowedFunctionNames: ["get_weather"]
        )
        let json = try encodeRequest(request)
        let toolConfig = try #require(json["toolConfig"] as? [String: Any])
        let fcc = try #require(toolConfig["functionCallingConfig"] as? [String: Any])
        #expect(fcc["mode"] as? String == "ANY")
        #expect(fcc["allowedFunctionNames"] as? [String] == ["get_weather"])
    }

    @Test
    func validatedMode_encodes() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-3-flash-preview")
        let request = try client.buildRequest(
            messages: [.user("Hi")], tools: tools, functionCallingMode: .validated
        )
        let json = try encodeRequest(request)
        let toolConfig = try #require(json["toolConfig"] as? [String: Any])
        let fcc = try #require(toolConfig["functionCallingConfig"] as? [String: Any])
        #expect(fcc["mode"] as? String == "VALIDATED")
    }

    @Test
    func noneMode_encodes() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-2.5-flash")
        let request = try client.buildRequest(
            messages: [.user("Hi")], tools: tools, functionCallingMode: .none
        )
        let json = try encodeRequest(request)
        let toolConfig = try #require(json["toolConfig"] as? [String: Any])
        let fcc = try #require(toolConfig["functionCallingConfig"] as? [String: Any])
        #expect(fcc["mode"] as? String == "NONE")
    }

    @Test
    func allowedNamesRequireAnyOrValidated() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-2.5-flash")
        #expect(throws: AgentError.self) {
            _ = try client.buildRequest(
                messages: [.user("Hi")],
                tools: tools,
                functionCallingMode: .auto,
                allowedFunctionNames: ["get_weather"]
            )
        }
    }
}

struct GeminiResponseSchemaRoutingTests {
    @Test
    func gemini25_routesToResponseSchema() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-2.5-flash")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            responseFormat: .jsonSchema(GeminiStructuredResult.self)
        )
        let json = try encodeRequest(request)
        let genConfig = try #require(json["generationConfig"] as? [String: Any])
        #expect(genConfig["responseSchema"] != nil)
        #expect(genConfig["responseJsonSchema"] == nil)
        #expect(genConfig["responseMimeType"] as? String == "application/json")
    }

    @Test
    func gemini3_routesToResponseJsonSchema() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-3-flash-preview")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            responseFormat: .jsonSchema(GeminiStructuredResult.self)
        )
        let json = try encodeRequest(request)
        let genConfig = try #require(json["generationConfig"] as? [String: Any])
        #expect(genConfig["responseJsonSchema"] != nil)
        #expect(genConfig["responseSchema"] == nil)
    }

    @Test
    func gemini31_inheritsJsonSchema() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-3.1-pro-preview")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            responseFormat: .jsonSchema(GeminiStructuredResult.self)
        )
        let json = try encodeRequest(request)
        let genConfig = try #require(json["generationConfig"] as? [String: Any])
        #expect(genConfig["responseJsonSchema"] != nil)
    }
}
