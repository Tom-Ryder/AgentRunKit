import Foundation

/// Content returned from an MCP tool call.
public enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)
    case audio(data: Data, mimeType: String)
    case resourceLink(uri: String, name: String?)
    case embeddedResource(uri: String, mimeType: String?, text: String?)
}

extension MCPContent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, resource
    }

    private struct ResourceFields: Decodable {
        let uri: String
        let name: String?
        let mimeType: String?
        let text: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            guard let text = try container.decodeIfPresent(String.self, forKey: .text) else {
                self = .text("[Malformed text content]")
                return
            }
            self = .text(text)

        case "image":
            self = try Self.decodeBinary(from: container, factory: MCPContent.image, label: "image")

        case "audio":
            self = try Self.decodeBinary(from: container, factory: MCPContent.audio, label: "audio")

        case "resource":
            guard let res = try container.decodeIfPresent(ResourceFields.self, forKey: .resource) else {
                self = .text("[Malformed resource content]")
                return
            }
            if res.text != nil || res.mimeType != nil {
                self = .embeddedResource(uri: res.uri, mimeType: res.mimeType, text: res.text)
            } else {
                self = .resourceLink(uri: res.uri, name: res.name)
            }

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
        guard let b64 = try container.decodeIfPresent(String.self, forKey: .data),
              let mime = try container.decodeIfPresent(String.self, forKey: .mimeType)
        else {
            return .text("[Malformed \(label) content]")
        }
        guard let decoded = Data(base64Encoded: b64) else {
            return .text("[Invalid base64 \(mime)]")
        }
        return factory(decoded, mime)
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
        isError = (try? container.decode(Bool.self, forKey: .isError)) ?? false

        if let structured = try container.decodeIfPresent(JSONValue.self, forKey: .structuredContent) {
            structuredContent = try JSONEncoder().encode(structured)
        } else {
            structuredContent = nil
        }

        var items: [MCPContent] = []
        if var contentContainer = try? container.nestedUnkeyedContainer(forKey: .content) {
            while !contentContainer.isAtEnd {
                do {
                    try items.append(contentContainer.decode(MCPContent.self))
                } catch {
                    _ = try? contentContainer.decode(JSONValue.self)
                }
            }
        }
        content = items
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
            case let .resourceLink(uri, name): name.map { "[\($0)](\(uri))" } ?? uri
            case let .embeddedResource(_, _, text): text ?? "[Embedded resource]"
            }
        }.joined(separator: "\n")
        return ToolResult(content: text, isError: isError)
    }
}
