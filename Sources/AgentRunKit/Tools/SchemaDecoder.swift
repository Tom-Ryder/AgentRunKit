import Foundation

public enum SchemaDecoder {
    public static func decode<T: Decodable>(_: T.Type) throws -> JSONSchema {
        let impl = SchemaDecoderImpl()
        _ = try T(from: impl)
        guard let schema = impl.schema else {
            if !impl.didAccessContainer {
                return .object(properties: [:], required: [])
            }
            throw SchemaDecoderError.inferenceFailed(type: String(describing: T.self))
        }
        return schema
    }
}

public enum SchemaDecoderError: Error, Sendable, Equatable, CustomStringConvertible {
    case inferenceFailed(type: String)

    public var description: String {
        switch self {
        case let .inferenceFailed(type):
            "Schema inference failed for \(type)"
        }
    }
}

final class SchemaDecoderImpl: Decoder {
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    var schema: JSONSchema?
    var didAccessContainer = false
    var pendingNullable = false

    func container<Key: CodingKey>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> {
        didAccessContainer = true
        return KeyedDecodingContainer(SchemaKeyedContainer<Key>(decoder: self, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        didAccessContainer = true
        return SchemaUnkeyedContainer(decoder: self, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        didAccessContainer = true
        return SchemaSingleValueContainer(decoder: self, codingPath: codingPath)
    }
}
