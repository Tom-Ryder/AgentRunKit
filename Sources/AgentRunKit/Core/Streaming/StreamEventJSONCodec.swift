import Foundation

/// Stable JSON encoding for persisting and replaying streamed events.
public enum StreamEventJSONCodec {
    /// Returns a `JSONEncoder` configured for the stable event wire format.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .useDefaultKeys
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    /// Returns a `JSONDecoder` configured for the stable event wire format.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    /// Encodes `event` using the stable wire format.
    public static func encode(_ event: StreamEvent) throws -> Data {
        try makeEncoder().encode(event)
    }

    /// Decodes `data` as a ``StreamEvent`` using the stable wire format.
    public static func decode(_ data: Data) throws -> StreamEvent {
        try makeDecoder().decode(StreamEvent.self, from: data)
    }
}
