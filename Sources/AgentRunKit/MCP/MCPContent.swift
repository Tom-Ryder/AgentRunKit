import Foundation

/// Content returned from an MCP tool call.
public enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)
    case audio(data: Data, mimeType: String)
    case resourceLink(uri: String, name: String)
    case embeddedResource(uri: String, mimeType: String?, content: MCPResourceContent)
}

extension MCPContent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, resource, uri, name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)

        case "image":
            self = try Self.decodeBinary(from: container, factory: MCPContent.image, label: "image")

        case "audio":
            self = try Self.decodeBinary(from: container, factory: MCPContent.audio, label: "audio")

        case "resource_link":
            self = try .resourceLink(
                uri: container.decode(String.self, forKey: .uri),
                name: container.decode(String.self, forKey: .name)
            )

        case "resource":
            let res = try container.decode(ResourceFields.self, forKey: .resource)
            self = .embeddedResource(uri: res.uri, mimeType: res.mimeType, content: res.content)

        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown content type: \(type)")
            )
        }
    }

    private static func decodeBinary(
        from container: KeyedDecodingContainer<CodingKeys>,
        factory: (Data, String) -> MCPContent,
        label: String
    ) throws -> MCPContent {
        let b64 = try container.decode(String.self, forKey: .data)
        let mime = try container.decode(String.self, forKey: .mimeType)
        guard let decoded = Data(base64Encoded: b64) else {
            throw DecodingError.dataCorruptedError(
                forKey: .data,
                in: container,
                debugDescription: "Invalid base64 data for \(label) content"
            )
        }
        return factory(decoded, mime)
    }
}

private struct ResourceFields: Decodable {
    let uri: String
    let mimeType: String?
    let content: MCPResourceContent

    private enum CodingKeys: String, CodingKey {
        case uri, mimeType, text, blob
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        mimeType = try container.contains(.mimeType) ? container.decode(String.self, forKey: .mimeType) : nil
        let text: String?
        do {
            text = try container.decodeIfPresent(String.self, forKey: .text)
        } catch let DecodingError.typeMismatch(type, _) where type == String.self {
            text = nil
        }
        if let text {
            content = .text(text)
            return
        }
        guard container.contains(.blob) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Embedded resource requires a text string or a base64 blob"
            ))
        }
        let blob = try container.decode(String.self, forKey: .blob)
        guard let data = Data(base64Encoded: blob) else {
            throw DecodingError.dataCorruptedError(
                forKey: .blob, in: container, debugDescription: "Invalid base64 data for embedded resource"
            )
        }
        content = .blob(data)
    }
}

/// The result of an MCP tools/call request.
public struct MCPCallResult: Sendable, Equatable, Decodable {
    public let content: [MCPContent]
    public let structuredContent: Data?
    public let isError: Bool

    public init(content: [MCPContent], structuredContent: Data? = nil, isError: Bool = false) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey {
        case content, structuredContent, isError
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false

        if let structured = try container.decodeIfPresent(JSONValue.self, forKey: .structuredContent) {
            structuredContent = try encodeDeterministicJSON(structured)
        } else {
            structuredContent = nil
        }

        content = try container.decode([MCPContent].self, forKey: .content)
    }

    /// Converts MCP content to a text-based tool result, preferring structured content when available.
    public func toToolResult() -> ToolResult {
        if let structured = structuredContent,
           let text = String(data: structured, encoding: .utf8) {
            return ToolResult(content: text, isError: isError)
        }
        let text = content.map { item -> String in
            switch item {
            case let .text(str): str
            case let .image(_, mimeType): "[Image: \(mimeType)]"
            case let .audio(_, mimeType): "[Audio: \(mimeType)]"
            case let .resourceLink(uri, name): "[\(name)](\(uri))"
            case let .embeddedResource(_, _, .text(text)): text
            case .embeddedResource(_, _, .blob): "[Embedded resource]"
            }
        }.joined(separator: "\n")
        return ToolResult(content: text, isError: isError)
    }
}
