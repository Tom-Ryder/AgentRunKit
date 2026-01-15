import Foundation

public enum ChatMessage: Sendable, Equatable, Codable {
    case system(String)
    case user(String)
    case userMultimodal([ContentPart])
    case assistant(AssistantMessage)
    case tool(id: String, name: String, content: String)

    public static func user(_ parts: [ContentPart]) -> ChatMessage {
        .userMultimodal(parts)
    }

    public static func user(text: String, imageURL: String) -> ChatMessage {
        .userMultimodal([.text(text), .imageURL(imageURL)])
    }

    public static func user(text: String, imageData: Data, mimeType: String = "image/jpeg") -> ChatMessage {
        .userMultimodal([.text(text), .image(data: imageData, mimeType: mimeType)])
    }

    public static func user(text: String, videoData: Data, mimeType: String = "video/mp4") -> ChatMessage {
        .userMultimodal([.text(text), .video(data: videoData, mimeType: mimeType)])
    }

    public static func user(text: String, audioData: Data, format: AudioInputFormat) -> ChatMessage {
        .userMultimodal([.text(text), .audio(data: audioData, format: format)])
    }

    public static func user(audioData: Data, format: AudioInputFormat) -> ChatMessage {
        .userMultimodal([.audio(data: audioData, format: format)])
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, id, name
    }

    private enum Role: String, Codable {
        case system, user, assistant, tool
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(Role.self, forKey: .role)
        switch role {
        case .system:
            let content = try container.decode(String.self, forKey: .content)
            self = .system(content)
        case .user:
            if let content = try? container.decode(String.self, forKey: .content) {
                self = .user(content)
            } else {
                let parts = try container.decode([ContentPart].self, forKey: .content)
                self = .userMultimodal(parts)
            }
        case .assistant:
            let message = try AssistantMessage(from: decoder)
            self = .assistant(message)
        case .tool:
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let content = try container.decode(String.self, forKey: .content)
            self = .tool(id: id, name: name, content: content)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .system(content):
            try container.encode(Role.system, forKey: .role)
            try container.encode(content, forKey: .content)
        case let .user(content):
            try container.encode(Role.user, forKey: .role)
            try container.encode(content, forKey: .content)
        case let .userMultimodal(parts):
            try container.encode(Role.user, forKey: .role)
            try container.encode(parts, forKey: .content)
        case let .assistant(message):
            try container.encode(Role.assistant, forKey: .role)
            try message.encode(to: encoder)
        case let .tool(id, name, content):
            try container.encode(Role.tool, forKey: .role)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(content, forKey: .content)
        }
    }
}
