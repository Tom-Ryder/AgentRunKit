import Foundation

/// A hosted OpenAI Responses tool that does not map to a local `ToolDefinition`.
public enum ResponsesHostedToolDefinition: Sendable, Equatable {
    case fileSearch(vectorStoreIDs: [String], maxNumResults: Int? = nil, filters: JSONValue? = nil)
    case webSearch(
        externalWebAccess: Bool? = nil,
        filters: JSONValue? = nil,
        userLocation: ResponsesApproximateUserLocation? = nil
    )
}

/// An approximate user location for Responses web search.
public struct ResponsesApproximateUserLocation: Sendable, Equatable, Encodable {
    public let country: String?
    public let city: String?
    public let region: String?
    public let timezone: String?
    let type = "approximate"

    public init(
        country: String? = nil,
        city: String? = nil,
        region: String? = nil,
        timezone: String? = nil
    ) {
        self.country = country
        self.city = city
        self.region = region
        self.timezone = timezone
    }
}

enum ResponsesInputItem: Encodable {
    case userMessage(role: String, content: ResponsesUserMessageContent)
    case assistantMessage(ResponsesAssistantItem)
    case functionCall(ResponsesFunctionCallItem)
    case functionCallOutput(ResponsesFunctionCallOutputItem)
    case reasoning(JSONValue)
    case raw(JSONValue)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case let .userMessage(role, content):
            var container = encoder.container(keyedBy: UserMessageKeys.self)
            try container.encode("message", forKey: .type)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        case let .assistantMessage(item):
            try item.encode(to: encoder)
        case let .functionCall(item):
            try item.encode(to: encoder)
        case let .functionCallOutput(item):
            try item.encode(to: encoder)
        case let .reasoning(value):
            try value.encode(to: encoder)
        case let .raw(value):
            try value.encode(to: encoder)
        }
    }

    private enum UserMessageKeys: String, CodingKey {
        case type, role, content
    }
}

enum ResponsesUserMessageContent: Encodable {
    case text(String)
    case items([ResponsesInputContentItem])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(text):
            try container.encode(text)
        case let .items(items):
            try container.encode(items)
        }
    }
}

enum ResponsesInputContentItem: Encodable, Equatable {
    case inputText(String)
    case inputImageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .inputText(text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .inputImageURL(imageURL):
            try container.encode("input_image", forKey: .type)
            try container.encode(imageURL, forKey: .imageURL)
        }
    }
}

struct ResponsesAssistantItem: Encodable {
    let type = "message"
    let role = "assistant"
    let content: [ResponsesOutputTextItem]

    enum CodingKeys: String, CodingKey {
        case type, role, content
    }
}

struct ResponsesOutputTextItem: Encodable {
    let type = "output_text"
    let text: String

    enum CodingKeys: String, CodingKey {
        case type, text
    }
}

struct ResponsesFunctionCallItem: Encodable {
    let type = "function_call"
    let callId: String
    let name: String
    let arguments: String

    enum CodingKeys: String, CodingKey {
        case type
        case callId = "call_id"
        case name, arguments
    }
}

struct ResponsesFunctionCallOutputItem: Encodable {
    let type = "function_call_output"
    let callId: String
    let output: String

    enum CodingKeys: String, CodingKey {
        case type
        case callId = "call_id"
        case output
    }
}

extension ResponsesHostedToolDefinition: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, filters
        case vectorStoreIDs = "vector_store_ids"
        case maxNumResults = "max_num_results"
        case externalWebAccess = "external_web_access"
        case userLocation = "user_location"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .fileSearch(vectorStoreIDs, maxNumResults, filters):
            try container.encode("file_search", forKey: .type)
            try container.encode(vectorStoreIDs, forKey: .vectorStoreIDs)
            try container.encodeIfPresent(maxNumResults, forKey: .maxNumResults)
            try container.encodeIfPresent(filters, forKey: .filters)
        case let .webSearch(externalWebAccess, filters, userLocation):
            try container.encode("web_search", forKey: .type)
            try container.encodeIfPresent(externalWebAccess, forKey: .externalWebAccess)
            try container.encodeIfPresent(filters, forKey: .filters)
            try container.encodeIfPresent(userLocation, forKey: .userLocation)
        }
    }
}

enum ResponsesToolDefinition: Encodable {
    case function(ResponsesFunctionToolDefinition)
    case hosted(ResponsesHostedToolDefinition)

    init(_ definition: ToolDefinition) {
        self = .function(ResponsesFunctionToolDefinition(definition))
    }

    init(hosted definition: ResponsesHostedToolDefinition) {
        self = .hosted(definition)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case let .function(definition):
            try definition.encode(to: encoder)
        case let .hosted(definition):
            try definition.encode(to: encoder)
        }
    }
}

struct ResponsesFunctionToolDefinition: Encodable {
    let type = "function"
    let name: String
    let description: String
    let parameters: JSONSchema

    enum CodingKeys: String, CodingKey {
        case type, name, description, parameters
    }

    init(_ definition: ToolDefinition) {
        name = definition.name
        description = definition.description
        parameters = definition.parametersSchema
    }
}
