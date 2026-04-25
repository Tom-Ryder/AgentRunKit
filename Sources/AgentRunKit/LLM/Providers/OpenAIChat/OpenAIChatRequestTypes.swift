import Foundation

extension OpenAIChatToolChoice: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, function, custom
        case allowedTools = "allowed_tools"
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .none:
            var container = encoder.singleValueContainer()
            try container.encode("none")
        case .auto:
            var container = encoder.singleValueContainer()
            try container.encode("auto")
        case .required:
            var container = encoder.singleValueContainer()
            try container.encode("required")
        case let .function(name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("function", forKey: .type)
            try container.encode(RequestToolChoiceName(name: name), forKey: .function)
        case let .custom(name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("custom", forKey: .type)
            try container.encode(RequestToolChoiceName(name: name), forKey: .custom)
        case let .allowedTools(mode, tools):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("allowed_tools", forKey: .type)
            try container.encode(
                RequestAllowedToolsConfiguration(mode: mode, tools: tools),
                forKey: .allowedTools
            )
        }
    }
}

private struct RequestToolChoiceName: Encodable {
    let name: String
}

private struct RequestAllowedToolsConfiguration: Encodable {
    let mode: OpenAIChatAllowedToolsMode
    let tools: [RequestAllowedTool]

    init(mode: OpenAIChatAllowedToolsMode, tools: [OpenAIChatAllowedTool]) {
        self.mode = mode
        self.tools = tools.map(RequestAllowedTool.init)
    }
}

private struct RequestAllowedTool: Encodable {
    let type: String
    let function: RequestToolChoiceName?
    let custom: RequestToolChoiceName?

    init(_ tool: OpenAIChatAllowedTool) {
        switch tool {
        case let .function(name):
            type = "function"
            function = RequestToolChoiceName(name: name)
            custom = nil
        case let .custom(name):
            type = "custom"
            function = nil
            custom = RequestToolChoiceName(name: name)
        }
    }
}

enum RequestTool: Encodable {
    case function(RequestFunctionToolBody)
    case custom(RequestCustomToolBody)

    init(_ definition: ToolDefinition, profile: OpenAIChatProfile) throws {
        self = try .function(RequestFunctionToolBody(definition, profile: profile))
    }

    init(custom definition: OpenAIChatCustomToolDefinition, profile: OpenAIChatProfile) throws {
        self = try .custom(RequestCustomToolBody(definition, profile: profile))
    }

    private enum CodingKeys: String, CodingKey {
        case type, function, custom
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .function(body):
            try container.encode("function", forKey: .type)
            try container.encode(body, forKey: .function)
        case let .custom(body):
            try container.encode("custom", forKey: .type)
            try container.encode(body, forKey: .custom)
        }
    }
}

struct RequestFunctionToolBody: Encodable {
    let name: String
    let description: String
    let parameters: JSONSchema
    let strict: Bool?

    init(_ definition: ToolDefinition, profile: OpenAIChatProfile) throws {
        name = definition.name
        description = definition.description
        parameters = definition.parametersSchema
        let capabilities = OpenAIChatCapabilities.resolve(profile: profile)
        if definition.strict != nil, !capabilities.supportsStrictFunctionSchemas {
            throw AgentError.llmError(.featureUnsupported(
                provider: "openai-chat-\(profile)",
                feature: "strict function schemas"
            ))
        }
        strict = definition.strict
    }
}

struct RequestCustomToolBody: Encodable {
    let name: String
    let description: String?
    let format: RequestCustomToolFormat?

    init(_ definition: OpenAIChatCustomToolDefinition, profile: OpenAIChatProfile) throws {
        let capabilities = OpenAIChatCapabilities.resolve(profile: profile)
        guard capabilities.supportsCustomTools else {
            throw AgentError.llmError(.featureUnsupported(
                provider: "openai-chat-\(profile)",
                feature: "custom tools"
            ))
        }
        name = definition.name
        description = definition.description
        format = definition.format.map(RequestCustomToolFormat.init)
    }
}

enum RequestCustomToolFormat: Encodable {
    case text
    case grammar(RequestCustomToolGrammar)

    init(_ format: OpenAIChatCustomToolFormat) {
        switch format {
        case .text:
            self = .text
        case let .grammar(definition, syntax):
            self = .grammar(RequestCustomToolGrammar(definition: definition, syntax: syntax))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, grammar
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text:
            try container.encode("text", forKey: .type)
        case let .grammar(grammar):
            try container.encode("grammar", forKey: .type)
            try container.encode(grammar, forKey: .grammar)
        }
    }
}

struct RequestCustomToolGrammar: Encodable {
    let definition: String
    let syntax: OpenAIChatCustomToolGrammarSyntax
}
