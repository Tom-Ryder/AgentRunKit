import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct SchemaDecoderAdvancedTests {
    @Test
    func arrayOfObjects() throws {
        struct Item: Codable {
            let id: Int
            let name: String
        }
        struct Params: Codable {
            let items: [Item]
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, _, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        guard case let .array(itemSchema, _) = properties["items"] else {
            Issue.record("Expected array schema for items")
            return
        }
        guard case let .object(itemProps, itemRequired, _) = itemSchema else {
            Issue.record("Expected object schema for array items")
            return
        }
        #expect(itemProps["id"] == .integer())
        #expect(itemProps["name"] == .string())
        #expect(Set(itemRequired) == Set(["id", "name"]))
    }

    @Test
    func optionalNestedObject() throws {
        struct Address: Codable {
            let city: String
        }
        struct Params: Codable {
            let name: String
            let address: Address?
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(required == ["name"])
        #expect(properties["name"] == .string())
        guard case let .anyOf(options) = properties["address"] else {
            Issue.record("Expected anyOf for optional address")
            return
        }
        #expect(options.contains(.null))
        let objectOption = options.first { if case .object = $0 { true } else { false } }
        #expect(objectOption != nil)
    }

    @Test
    func optionalArray() throws {
        struct Params: Codable {
            let tags: [String]?
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(required.isEmpty)
        guard case let .anyOf(options) = properties["tags"] else {
            Issue.record("Expected anyOf for optional array")
            return
        }
        #expect(options.contains(.null))
        let arrayOption = options.first { if case .array = $0 { true } else { false } }
        #expect(arrayOption != nil)
    }

    @Test
    func deeplyNestedStructure() throws {
        struct Level3: Codable {
            let value: String
        }
        struct Level2: Codable {
            let level3: Level3
        }
        struct Level1: Codable {
            let level2: Level2
        }
        struct Root: Codable {
            let level1: Level1
        }
        let schema = try SchemaDecoder.decode(Root.self)
        guard case let .object(rootProps, _, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        guard case let .object(l1Props, _, _) = rootProps["level1"] else {
            Issue.record("Expected object for level1")
            return
        }
        guard case let .object(l2Props, _, _) = l1Props["level2"] else {
            Issue.record("Expected object for level2")
            return
        }
        guard case let .object(l3Props, _, _) = l2Props["level3"] else {
            Issue.record("Expected object for level3")
            return
        }
        #expect(l3Props["value"] == .string())
    }

    @Test
    func mixedOptionalAndRequired() throws {
        struct Params: Codable {
            let required1: String
            let optional1: Int?
            let required2: Bool
            let optional2: Double?
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(Set(required) == Set(["required1", "required2"]))
        #expect(properties["required1"] == .string())
        #expect(properties["required2"] == .boolean())
        #expect(properties.count == 4)
    }

    @Test
    func optionalPrimitiveTypes() throws {
        struct Params: Codable {
            let optBool: Bool?
            let optDouble: Double?
            let optFloat: Float?
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(required.isEmpty)
        for (_, value) in properties {
            guard case .anyOf = value else {
                Issue.record("Expected anyOf for optional field")
                return
            }
        }
    }

    @Test
    func nestedArrayOfArrays() throws {
        struct Params: Codable {
            let matrix: [[Int]]
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, _, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        guard case let .array(outerItems, _) = properties["matrix"] else {
            Issue.record("Expected array for matrix")
            return
        }
        guard case let .array(innerItems, _) = outerItems else {
            Issue.record("Expected nested array")
            return
        }
        #expect(innerItems == .integer())
    }
}
