import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct JSONSchemaTests {
    private func encodeToJSON(_ schema: JSONSchema) throws -> [String: Any] {
        let data = try JSONEncoder().encode(schema)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any] else {
            throw SchemaTestError.invalidJSON
        }
        return dict
    }

    @Test
    func stringSchema() throws {
        let schema = JSONSchema.string(description: "A name")
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "string")
        #expect(json["description"] as? String == "A name")
    }

    @Test
    func stringSchemaWithoutDescription() throws {
        let schema = JSONSchema.string()
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "string")
        #expect(json["description"] == nil)
    }

    @Test
    func integerSchema() throws {
        let schema = JSONSchema.integer(description: "Count")
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "integer")
        #expect(json["description"] as? String == "Count")
    }

    @Test
    func numberSchema() throws {
        let schema = JSONSchema.number(description: "Price")
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "number")
        #expect(json["description"] as? String == "Price")
    }

    @Test
    func booleanSchema() throws {
        let schema = JSONSchema.boolean(description: "Is active")
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "boolean")
        #expect(json["description"] as? String == "Is active")
    }

    @Test
    func nullSchema() throws {
        let schema = JSONSchema.null
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "null")
    }

    @Test
    func arraySchema() throws {
        let schema = JSONSchema.array(items: .string(), description: "List of names")
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "array")
        #expect(json["description"] as? String == "List of names")
        let items = json["items"] as? [String: Any]
        #expect(items?["type"] as? String == "string")
    }

    @Test
    func objectSchema() throws {
        let schema = JSONSchema.object(
            properties: [
                "name": .string(description: "User name"),
                "age": .integer(description: "User age")
            ],
            required: ["name"],
            description: "A user object"
        )
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "object")
        #expect(json["description"] as? String == "A user object")
        let required = json["required"] as? [String]
        #expect(required == ["name"])
        let properties = json["properties"] as? [String: Any]
        #expect(properties?.count == 2)
    }

    @Test
    func objectSchemaOmitsEmptyRequired() throws {
        let schema = JSONSchema.object(properties: ["x": .string()], required: [])
        let json = try encodeToJSON(schema)
        #expect(json["required"] == nil)
    }

    @Test
    func optionalSchema() throws {
        let schema = JSONSchema.string(description: "Optional field").optional()
        let json = try encodeToJSON(schema)
        let anyOf = json["anyOf"] as? [[String: Any]]
        #expect(anyOf?.count == 2)
        let types = anyOf?.compactMap { $0["type"] as? String }
        #expect(types?.contains("string") == true)
        #expect(types?.contains("null") == true)
    }

    @Test
    func nestedObjectSchema() throws {
        let schema = JSONSchema.object(
            properties: [
                "user": .object(
                    properties: ["id": .string()],
                    required: ["id"]
                )
            ],
            required: ["user"]
        )
        let json = try encodeToJSON(schema)
        let properties = json["properties"] as? [String: Any]
        let user = properties?["user"] as? [String: Any]
        #expect(user?["type"] as? String == "object")
        let userRequired = user?["required"] as? [String]
        #expect(userRequired == ["id"])
        let userProps = user?["properties"] as? [String: Any]
        let idProp = userProps?["id"] as? [String: Any]
        #expect(idProp?["type"] as? String == "string")
    }

    @Test
    func stringSchemaWithEnumValues() throws {
        let schema = JSONSchema.string(enumValues: ["a", "b", "c"])
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "string")
        #expect(json["enum"] as? [String] == ["a", "b", "c"])
    }

    @Test
    func stringSchemaWithEmptyEnumValues() throws {
        let schema = JSONSchema.string(enumValues: [])
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "string")
        #expect(json["enum"] as? [String] == [])
    }

    @Test
    func stringSchemaWithNilEnumValuesOmitsField() throws {
        let schema = JSONSchema.string(enumValues: nil)
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "string")
        #expect(json["enum"] == nil)
    }

    @Test
    func stringSchemaWithDescriptionAndEnumValues() throws {
        let schema = JSONSchema.string(description: "Status code", enumValues: ["pending", "complete"])
        let json = try encodeToJSON(schema)
        #expect(json["type"] as? String == "string")
        #expect(json["description"] as? String == "Status code")
        #expect(json["enum"] as? [String] == ["pending", "complete"])
    }
}

private enum SchemaTestError: Error {
    case invalidJSON
}

@Suite
struct SchemaDecoderTests {
    @Test
    func basicTypes() throws {
        struct Params: Codable {
            let name: String
            let count: Int
            let price: Double
            let enabled: Bool
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(properties["name"] == .string())
        #expect(properties["count"] == .integer())
        #expect(properties["price"] == .number())
        #expect(properties["enabled"] == .boolean())
        #expect(Set(required) == Set(["name", "count", "price", "enabled"]))
    }

    @Test
    func optionalFieldsNotRequired() throws {
        struct Params: Codable {
            let required: String
            let optional: String?
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(required == ["required"])
        #expect(properties["required"] == .string())
        guard case let .anyOf(options) = properties["optional"] else {
            Issue.record("Expected anyOf for optional field")
            return
        }
        #expect(options.contains(.string()))
        #expect(options.contains(.null))
    }

    @Test
    func arrayFields() throws {
        struct Params: Codable {
            let tags: [String]
            let counts: [Int]
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, _, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        guard case let .array(stringItems, _) = properties["tags"] else {
            Issue.record("Expected array schema for tags")
            return
        }
        #expect(stringItems == .string())
        guard case let .array(intItems, _) = properties["counts"] else {
            Issue.record("Expected array schema for counts")
            return
        }
        #expect(intItems == .integer())
    }

    @Test
    func nestedStructs() throws {
        struct Address: Codable {
            let street: String
            let city: String
        }
        struct Params: Codable {
            let name: String
            let address: Address
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(Set(required) == Set(["name", "address"]))
        #expect(properties["name"] == .string())
        guard case let .object(addressProps, addressRequired, _) = properties["address"] else {
            Issue.record("Expected object schema for address")
            return
        }
        #expect(addressProps["street"] == .string())
        #expect(addressProps["city"] == .string())
        #expect(Set(addressRequired) == Set(["street", "city"]))
    }

    @Test
    func emptyStruct() throws {
        struct Empty: Codable {}
        let schema = try SchemaDecoder.decode(Empty.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(properties.isEmpty)
        #expect(required.isEmpty)
    }

    @Test
    func onlyOptionalFields() throws {
        struct Params: Codable {
            let optionalName: String?
            let optionalCount: Int?
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(required.isEmpty)
        #expect(properties.count == 2)
    }

    @Test
    func defaultSchemaProvidingImplementation() throws {
        struct AutoParams: Codable, SchemaProviding, Sendable {
            let message: String
            let count: Int
        }
        let schema = AutoParams.jsonSchema
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(properties["message"] == .string())
        #expect(properties["count"] == .integer())
        #expect(Set(required) == Set(["message", "count"]))
    }

    @Test
    func floatType() throws {
        struct Params: Codable {
            let value: Float
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(properties["value"] == .number())
        #expect(required == ["value"])
    }

    @Test
    func allIntegerVariants() throws {
        struct Params: Codable {
            let int8: Int8
            let int16: Int16
            let int32: Int32
            let int64: Int64
            let uint: UInt
            let uint8: UInt8
            let uint16: UInt16
            let uint32: UInt32
            let uint64: UInt64
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(properties.count == 9)
        for (_, value) in properties {
            #expect(value == .integer())
        }
        #expect(required.count == 9)
    }
}
