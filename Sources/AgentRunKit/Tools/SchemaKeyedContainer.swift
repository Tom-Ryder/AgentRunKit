import Foundation

final class SchemaKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: SchemaDecoderImpl
    var codingPath: [any CodingKey]
    var allKeys: [Key] = []
    private var properties: [String: JSONSchema] = [:]
    private var required: [String] = []

    init(decoder: SchemaDecoderImpl, codingPath: [any CodingKey]) {
        self.decoder = decoder
        self.codingPath = codingPath
        decoder.schema = .object(properties: [:], required: [])
    }

    func contains(_: Key) -> Bool { true }

    func decodeNil(forKey _: Key) throws -> Bool { false }

    func decode(_: Bool.Type, forKey key: Key) throws -> Bool {
        record(key: key, schema: .boolean())
        return false
    }

    func decode(_: String.Type, forKey key: Key) throws -> String {
        record(key: key, schema: .string())
        return ""
    }

    func decode(_: Double.Type, forKey key: Key) throws -> Double {
        record(key: key, schema: .number())
        return 0
    }

    func decode(_: Float.Type, forKey key: Key) throws -> Float {
        record(key: key, schema: .number())
        return 0
    }

    func decode(_: Int.Type, forKey key: Key) throws -> Int {
        record(key: key, schema: .integer())
        return 0
    }

    func decode(_: Int8.Type, forKey key: Key) throws -> Int8 {
        record(key: key, schema: .integer())
        return 0
    }

    func decode(_: Int16.Type, forKey key: Key) throws -> Int16 {
        record(key: key, schema: .integer())
        return 0
    }

    func decode(_: Int32.Type, forKey key: Key) throws -> Int32 {
        record(key: key, schema: .integer())
        return 0
    }

    func decode(_: Int64.Type, forKey key: Key) throws -> Int64 {
        record(key: key, schema: .integer())
        return 0
    }

    func decode(_: UInt.Type, forKey key: Key) throws -> UInt {
        record(key: key, schema: .integer())
        return 0
    }

    func decode(_: UInt8.Type, forKey key: Key) throws -> UInt8 {
        record(key: key, schema: .integer())
        return 0
    }

    func decode(_: UInt16.Type, forKey key: Key) throws -> UInt16 {
        record(key: key, schema: .integer())
        return 0
    }

    func decode(_: UInt32.Type, forKey key: Key) throws -> UInt32 {
        record(key: key, schema: .integer())
        return 0
    }

    func decode(_: UInt64.Type, forKey key: Key) throws -> UInt64 {
        record(key: key, schema: .integer())
        return 0
    }

    func decode<T: Decodable>(_: T.Type, forKey key: Key) throws -> T {
        let nestedDecoder = SchemaDecoderImpl()
        nestedDecoder.codingPath = codingPath + [key]
        let value = try T(from: nestedDecoder)
        if let nestedSchema = nestedDecoder.schema {
            record(key: key, schema: nestedSchema)
        }
        return value
    }

    func decodeIfPresent(_: Bool.Type, forKey key: Key) throws -> Bool? {
        recordOptional(key: key, schema: .boolean())
        return nil
    }

    func decodeIfPresent(_: String.Type, forKey key: Key) throws -> String? {
        recordOptional(key: key, schema: .string())
        return nil
    }

    func decodeIfPresent(_: Double.Type, forKey key: Key) throws -> Double? {
        recordOptional(key: key, schema: .number())
        return nil
    }

    func decodeIfPresent(_: Float.Type, forKey key: Key) throws -> Float? {
        recordOptional(key: key, schema: .number())
        return nil
    }

    func decodeIfPresent(_: Int.Type, forKey key: Key) throws -> Int? {
        recordOptional(key: key, schema: .integer())
        return nil
    }

    func decodeIfPresent(_: Int8.Type, forKey key: Key) throws -> Int8? {
        recordOptional(key: key, schema: .integer())
        return nil
    }

    func decodeIfPresent(_: Int16.Type, forKey key: Key) throws -> Int16? {
        recordOptional(key: key, schema: .integer())
        return nil
    }

    func decodeIfPresent(_: Int32.Type, forKey key: Key) throws -> Int32? {
        recordOptional(key: key, schema: .integer())
        return nil
    }

    func decodeIfPresent(_: Int64.Type, forKey key: Key) throws -> Int64? {
        recordOptional(key: key, schema: .integer())
        return nil
    }

    func decodeIfPresent(_: UInt.Type, forKey key: Key) throws -> UInt? {
        recordOptional(key: key, schema: .integer())
        return nil
    }

    func decodeIfPresent(_: UInt8.Type, forKey key: Key) throws -> UInt8? {
        recordOptional(key: key, schema: .integer())
        return nil
    }

    func decodeIfPresent(_: UInt16.Type, forKey key: Key) throws -> UInt16? {
        recordOptional(key: key, schema: .integer())
        return nil
    }

    func decodeIfPresent(_: UInt32.Type, forKey key: Key) throws -> UInt32? {
        recordOptional(key: key, schema: .integer())
        return nil
    }

    func decodeIfPresent(_: UInt64.Type, forKey key: Key) throws -> UInt64? {
        recordOptional(key: key, schema: .integer())
        return nil
    }

    func decodeIfPresent<T: Decodable>(_: T.Type, forKey key: Key) throws -> T? {
        let nestedDecoder = SchemaDecoderImpl()
        nestedDecoder.codingPath = codingPath + [key]
        _ = try T(from: nestedDecoder)
        if let nestedSchema = nestedDecoder.schema {
            properties[key.stringValue] = nestedSchema.optional()
            decoder.schema = .object(properties: properties, required: required)
        }
        return nil
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let container = SchemaKeyedContainer<NestedKey>(
            decoder: decoder,
            codingPath: codingPath + [key]
        )
        return KeyedDecodingContainer(container)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        SchemaUnkeyedContainer(decoder: decoder, codingPath: codingPath + [key])
    }

    func superDecoder() throws -> any Decoder {
        decoder
    }

    func superDecoder(forKey _: Key) throws -> any Decoder {
        decoder
    }

    private func record(key: Key, schema: JSONSchema) {
        properties[key.stringValue] = schema
        required.append(key.stringValue)
        decoder.schema = .object(properties: properties, required: required)
    }

    private func recordOptional(key: Key, schema: JSONSchema) {
        properties[key.stringValue] = schema.optional()
        decoder.schema = .object(properties: properties, required: required)
    }
}
