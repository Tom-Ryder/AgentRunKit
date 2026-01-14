import Foundation

public enum ContentPart: Sendable, Equatable {
    case text(String)
    case imageURL(String)
    case imageBase64(data: Data, mimeType: String)
    case videoBase64(data: Data, mimeType: String)
    case pdfBase64(data: Data)

    public static func image(url: String) -> ContentPart {
        .imageURL(url)
    }

    public static func image(data: Data, mimeType: String = "image/jpeg") -> ContentPart {
        .imageBase64(data: data, mimeType: mimeType)
    }

    public static func video(data: Data, mimeType: String = "video/mp4") -> ContentPart {
        .videoBase64(data: data, mimeType: mimeType)
    }

    public static func pdf(data: Data) -> ContentPart {
        .pdfBase64(data: data)
    }
}

extension ContentPart: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, imageURL = "image_url", inlineData = "inline_data"
    }

    private enum ImageURLKeys: String, CodingKey {
        case url
    }

    private enum InlineDataKeys: String, CodingKey {
        case mimeType = "mime_type", data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image_url":
            let urlContainer = try container.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .imageURL)
            let url = try urlContainer.decode(String.self, forKey: .url)
            if let parsed = Self.parseDataURL(url) {
                self = parsed
            } else {
                self = .imageURL(url)
            }
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown content type: \(type)")
            )
        }
    }

    private static func parseDataURL(_ url: String) -> ContentPart? {
        guard url.hasPrefix("data:") else { return nil }
        let afterData = url.dropFirst(5)
        guard let semicolonIndex = afterData.firstIndex(of: ";"),
              let commaIndex = afterData.firstIndex(of: ","),
              semicolonIndex < commaIndex
        else { return nil }

        let mimeType = String(afterData[..<semicolonIndex])
        let encoding = String(afterData[afterData.index(after: semicolonIndex) ..< commaIndex])
        guard encoding == "base64" else { return nil }

        let base64String = String(afterData[afterData.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else { return nil }

        switch mimeType {
        case "application/pdf":
            return .pdfBase64(data: data)
        case let mime where mime.hasPrefix("video/"):
            return .videoBase64(data: data, mimeType: mime)
        case let mime where mime.hasPrefix("image/"):
            return .imageBase64(data: data, mimeType: mime)
        default:
            return nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)

        case let .imageURL(url):
            try container.encode("image_url", forKey: .type)
            var urlContainer = container.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .imageURL)
            try urlContainer.encode(url, forKey: .url)

        case let .imageBase64(data, mimeType):
            try container.encode("image_url", forKey: .type)
            var urlContainer = container.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .imageURL)
            let base64 = data.base64EncodedString()
            try urlContainer.encode("data:\(mimeType);base64,\(base64)", forKey: .url)

        case let .videoBase64(data, mimeType):
            try container.encode("image_url", forKey: .type)
            var urlContainer = container.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .imageURL)
            let base64 = data.base64EncodedString()
            try urlContainer.encode("data:\(mimeType);base64,\(base64)", forKey: .url)

        case let .pdfBase64(data):
            try container.encode("image_url", forKey: .type)
            var urlContainer = container.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .imageURL)
            let base64 = data.base64EncodedString()
            try urlContainer.encode("data:application/pdf;base64,\(base64)", forKey: .url)
        }
    }
}
