import Foundation

public enum AudioInputFormat: String, Sendable, Codable, CaseIterable {
    case wav
    case mp3
    case m4a
    case flac
    case ogg
    case opus
    case webm

    public var mimeType: String {
        switch self {
        case .wav:
            "audio/wav"
        case .mp3:
            "audio/mpeg"
        case .m4a:
            "audio/mp4"
        case .flac:
            "audio/flac"
        case .ogg:
            "audio/ogg"
        case .opus:
            "audio/opus"
        case .webm:
            "audio/webm"
        }
    }

    public var fileExtension: String {
        rawValue
    }
}

public enum ContentPart: Sendable, Equatable {
    case text(String)
    case imageURL(String)
    case imageBase64(data: Data, mimeType: String)
    case videoBase64(data: Data, mimeType: String)
    case pdfBase64(data: Data)
    case audioBase64(data: Data, format: AudioInputFormat)

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

    public static func audio(data: Data, format: AudioInputFormat) -> ContentPart {
        .audioBase64(data: data, format: format)
    }
}

extension ContentPart: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, imageURL = "image_url", inputAudio = "input_audio", inlineData = "inline_data"
    }

    private enum ImageURLKeys: String, CodingKey {
        case url
    }

    private enum InputAudioKeys: String, CodingKey {
        case data, format
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
        case "input_audio":
            let audioContainer = try container.nestedContainer(keyedBy: InputAudioKeys.self, forKey: .inputAudio)
            let dataString = try audioContainer.decode(String.self, forKey: .data)
            guard let data = Data(base64Encoded: dataString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: audioContainer,
                    debugDescription: "input_audio.data is not valid base64"
                )
            }
            let formatString = try audioContainer.decode(String.self, forKey: .format)
            guard let format = AudioInputFormat(rawValue: formatString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .format,
                    in: audioContainer,
                    debugDescription: "Unknown audio format: \(formatString)"
                )
            }
            self = .audioBase64(data: data, format: format)
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

        case let .audioBase64(data, format):
            try container.encode("input_audio", forKey: .type)
            var audioContainer = container.nestedContainer(keyedBy: InputAudioKeys.self, forKey: .inputAudio)
            try audioContainer.encode(data.base64EncodedString(), forKey: .data)
            try audioContainer.encode(format.rawValue, forKey: .format)
        }
    }
}
