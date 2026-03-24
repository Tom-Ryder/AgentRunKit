#if canImport(FoundationModels)

    import AgentRunKit
    @testable import AgentRunKitFoundationModels
    import Foundation
    import FoundationModels
    import Testing

    @Suite struct FMSchemaConverterTests {
        @Test func flatObjectProducesValidSchema() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let schema = JSONSchema.object(
                properties: [
                    "name": .string(description: "The name"),
                    "age": .integer(description: "The age"),
                ],
                required: ["name", "age"]
            )
            let result = try FMSchemaConverter.convert(schema)
            let json = String(describing: result)
            #expect(json.contains("\"name\""))
            #expect(json.contains("\"age\""))
            #expect(json.contains("\"string\""))
            #expect(json.contains("\"integer\""))
        }

        @Test func optionalPropertyNotInRequired() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let schema = JSONSchema.object(
                properties: [
                    "city": .string(description: "City"),
                    "units": .string(description: "Units"),
                ],
                required: ["city"]
            )
            let result = try FMSchemaConverter.convert(schema)
            let json = String(describing: result)
            #expect(json.contains("\"city\""))
            #expect(json.contains("\"units\""))
            #expect(json.contains("\"required\""))
            #expect(json.contains("\"string\""))
        }

        @Test func arrayPropertyUsesArrayType() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let schema = JSONSchema.object(
                properties: ["tags": .array(items: .string(), description: "Tags")],
                required: ["tags"]
            )
            let result = try FMSchemaConverter.convert(schema)
            let json = String(describing: result)
            #expect(json.contains("\"array\""))
            #expect(json.contains("\"tags\""))
        }

        @Test func nestedObjectContainsChildProperties() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let schema = JSONSchema.object(
                properties: [
                    "address": .object(
                        properties: ["street": .string(), "zip": .integer()],
                        required: ["street"]
                    ),
                ],
                required: ["address"]
            )
            let result = try FMSchemaConverter.convert(schema)
            let json = String(describing: result)
            #expect(json.contains("\"street\""))
            #expect(json.contains("\"zip\""))
            #expect(json.contains("\"string\""))
            #expect(json.contains("\"integer\""))
        }

        @Test func anyOfWithNullProducesOptional() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let schema = JSONSchema.object(
                properties: ["nickname": .anyOf([.string(), .null])],
                required: []
            )
            let result = try FMSchemaConverter.convert(schema)
            let json = String(describing: result)
            #expect(json.contains("\"nickname\""))
            #expect(json.contains("\"string\""))
        }

        @Test func nonObjectTopLevelThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect(throws: AgentError.self) {
                try FMSchemaConverter.convert(.string())
            }
        }

        @Test func emptyObjectSucceeds() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let result = try FMSchemaConverter.convert(
                .object(properties: [:], required: [])
            )
            let json = String(describing: result)
            #expect(json.contains("\"object\""))
        }

        @Test func complexAnyOfThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect(throws: AgentError.self) {
                try FMSchemaConverter.convert(
                    .object(
                        properties: ["value": .anyOf([.string(), .integer()])],
                        required: ["value"]
                    )
                )
            }
        }

        @Test func enumValuesThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect(throws: AgentError.self) {
                try FMSchemaConverter.convert(
                    .object(
                        properties: [
                            "color": .string(
                                description: "Pick a color",
                                enumValues: ["red", "green", "blue"]
                            ),
                        ],
                        required: ["color"]
                    )
                )
            }
        }

        @Test func nullPropertyThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect(throws: AgentError.self) {
                try FMSchemaConverter.convert(
                    .object(properties: ["empty": .null], required: [])
                )
            }
        }
    }

#endif
