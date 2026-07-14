#if canImport(FoundationModels)

    import AgentRunKit
    @testable import AgentRunKitFoundationModels
    import Foundation
    import FoundationModels
    import Testing

    @Suite(.serialized) struct FMSchemaConverterTests {
        @available(macOS 26, iOS 26, *)
        @Test func flatObjectCompilesTypedLexicographicRoot() throws {
            let schema = JSONSchema.object(
                properties: [
                    "name": .string(description: "The name"),
                    "age": .integer(description: "The age"),
                ],
                required: ["name", "age"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.root.title == "Arguments")
            #expect(graph.definitionNames.isEmpty)
            #expect(graph.root.order == ["age", "name"])
            #expect(Set(graph.root.required) == ["age", "name"])
            let name = try graph.scalar(at: ["name"])
            #expect(name.type == "string")
            #expect(name.description == "The name")
            let age = try graph.scalar(at: ["age"])
            #expect(age.type == "integer")
            #expect(age.description == "The age")
        }

        @available(macOS 26, iOS 26, *)
        @Test func optionalPropertyExcludedFromRequired() throws {
            let schema = JSONSchema.object(
                properties: ["city": .string(), "units": .string()],
                required: ["city"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.root.required == ["city"])
            #expect(graph.root.order == ["city", "units"])
            #expect(try graph.scalar(at: ["units"]).type == "string")
        }

        @available(macOS 26, iOS 26, *)
        @Test func scalarArrayCompilesToArrayNodeWithoutIdentity() throws {
            let schema = JSONSchema.object(
                properties: ["tags": .array(items: .string(), description: "Tags")],
                required: ["tags"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.definitionNames.isEmpty)
            #expect(try graph.node(at: ["tags"]).description == "Tags")
            #expect(try graph.scalar(at: ["tags", .items]).type == "string")
        }

        @available(macOS 26, iOS 26, *)
        @Test func nullableScalarAnyOfBecomesOptionalScalar() throws {
            let schema = JSONSchema.object(
                properties: ["nickname": .anyOf([.string(), .null])],
                required: []
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.root.required.isEmpty)
            #expect(try graph.scalar(at: ["nickname"]).type == "string")
        }

        @available(macOS 26, iOS 26, *)
        @Test func emptyRootObjectCompiles() throws {
            let graph = try EncodedSchemaGraph(
                schema: FMSchemaConverter.convert(.object(properties: [:], required: []))
            )
            #expect(graph.root.title == "Arguments")
            #expect(graph.root.properties.isEmpty)
            #expect(graph.definitionNames.isEmpty)
        }

        @available(macOS 26, iOS 26, *)
        @Test(arguments: [
            (JSONSchema.string(), "Arguments"),
            (.object(properties: ["value": .anyOf([.string(), .integer()])], required: ["value"]), "anyOf"),
            (
                .object(
                    properties: ["color": .string(description: "Pick a color", enumValues: ["red", "green"])],
                    required: ["color"]
                ),
                "string"
            ),
            (.object(properties: ["empty": .null], required: []), "null"),
            (.object(properties: ["value": .string()], required: ["missing"]), "Arguments"),
            (
                .object(
                    properties: ["outer": .object(properties: [:], required: ["ghost"])],
                    required: ["outer"]
                ),
                "Object_1"
            ),
        ])
        func unsupportedSchemaThrowsSchemaInferenceFailure(schema: JSONSchema, expectedType: String) {
            let error = #expect(throws: AgentError.self) {
                try FMSchemaConverter.convert(schema)
            }
            guard case let .schemaInferenceFailed(type, _) = error else {
                Issue.record("Expected schemaInferenceFailed, got \(String(describing: error))")
                return
            }
            #expect(type == expectedType)
        }
    }

    @Suite(.serialized) struct FMSchemaConverterGraphTests {
        @available(macOS 26, iOS 26, *)
        @Test func distinctSiblingsKeepSeparateContracts() throws {
            let schema = JSONSchema.object(
                properties: [
                    "address": .object(properties: ["street": .string()], required: ["street"]),
                    "location": .object(properties: ["latitude": .number()], required: ["latitude"]),
                ],
                required: ["address", "location"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.definitionNames == ["Object_1", "Object_2"])
            #expect(try graph.validateFiniteResolution() == ["Object_1", "Object_2"])
            #expect(try graph.reference(at: ["address"]).target == "Object_1")
            #expect(try graph.reference(at: ["location"]).target == "Object_2")
            #expect(try graph.resolvedObject(at: ["address"]).properties.keys.sorted() == ["street"])
            #expect(try graph.resolvedObject(at: ["location"]).properties.keys.sorted() == ["latitude"])
            #expect(try graph.scalar(at: ["address", "street"]).type == "string")
            #expect(try graph.scalar(at: ["location", "latitude"]).type == "number")
        }

        @available(macOS 26, iOS 26, *)
        @Test func deepChainRemainsFiniteWithDistinctIdentities() throws {
            let schema = JSONSchema.object(
                properties: [
                    "wrapper": .object(
                        properties: [
                            "child": .object(properties: ["value": .string()], required: ["value"]),
                        ],
                        required: ["child"]
                    ),
                ],
                required: ["wrapper"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.definitionNames == ["Object_1", "Object_2"])
            #expect(try graph.validateFiniteResolution() == ["Object_1", "Object_2"])
            #expect(try graph.reference(at: ["wrapper"]).target == "Object_1")
            #expect(try graph.reference(at: ["wrapper", "child"]).target == "Object_2")
            #expect(try graph.scalar(at: ["wrapper", "child", "value"]).type == "string")
        }

        @available(macOS 26, iOS 26, *)
        @Test func objectArraysKeepDistinctItemContracts() throws {
            let schema = JSONSchema.object(
                properties: [
                    "alpha": .array(items: .object(properties: ["code": .string()], required: ["code"])),
                    "beta": .array(items: .object(properties: ["count": .integer()], required: ["count"])),
                ],
                required: ["alpha", "beta"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.definitionNames == ["Object_1", "Object_2"])
            #expect(try graph.reference(at: ["alpha", .items]).target == "Object_1")
            #expect(try graph.reference(at: ["beta", .items]).target == "Object_2")
            #expect(try graph.resolvedObject(at: ["alpha", .items]).properties.keys.sorted() == ["code"])
            #expect(try graph.resolvedObject(at: ["beta", .items]).properties.keys.sorted() == ["count"])
            #expect(try graph.scalar(at: ["alpha", .items, "code"]).type == "string")
            #expect(try graph.scalar(at: ["beta", .items, "count"]).type == "integer")
        }

        @available(macOS 26, iOS 26, *)
        @Test func directObjectAndObjectArrayReceiveSeparateIdentities() throws {
            let schema = JSONSchema.object(
                properties: [
                    "direct": .object(properties: ["flag": .boolean()], required: ["flag"]),
                    "listed": .array(items: .object(properties: ["label": .string()], required: ["label"])),
                ],
                required: ["direct", "listed"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.definitionNames == ["Object_1", "Object_2"])
            #expect(try graph.reference(at: ["direct"]).target == "Object_1")
            #expect(try graph.reference(at: ["listed", .items]).target == "Object_2")
            #expect(try graph.scalar(at: ["direct", "flag"]).type == "boolean")
            #expect(try graph.scalar(at: ["listed", .items, "label"]).type == "string")
        }

        @available(macOS 26, iOS 26, *)
        @Test func optionalNestedObjectsAllocateDistinctIdentities() throws {
            let schema = JSONSchema.object(
                properties: [
                    "primary": .object(properties: ["a": .string()], required: ["a"]).optional(),
                    "secondary": .object(properties: ["b": .integer()], required: ["b"]).optional(),
                ],
                required: []
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.root.required.isEmpty)
            #expect(graph.definitionNames == ["Object_1", "Object_2"])
            #expect(try graph.reference(at: ["primary"]).target == "Object_1")
            #expect(try graph.reference(at: ["secondary"]).target == "Object_2")
            #expect(try graph.scalar(at: ["primary", "a"]).type == "string")
            #expect(try graph.scalar(at: ["secondary", "b"]).type == "integer")
        }

        @available(macOS 26, iOS 26, *)
        @Test func optionalArrayOfObjectsResolvesItemIdentity() throws {
            let schema = JSONSchema.object(
                properties: [
                    "entries": .array(items: .object(properties: ["id": .string()], required: ["id"])).optional(),
                ],
                required: []
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.root.required.isEmpty)
            #expect(graph.definitionNames == ["Object_1"])
            #expect(try graph.reference(at: ["entries", .items]).target == "Object_1")
            #expect(try graph.scalar(at: ["entries", .items, "id"]).type == "string")
        }

        @available(macOS 26, iOS 26, *)
        @Test func repeatedPropertyKeysUnderDifferentParentsKeepTheirTypes() throws {
            let schema = JSONSchema.object(
                properties: [
                    "first": .object(properties: ["value": .string()], required: ["value"]),
                    "second": .object(properties: ["value": .integer()], required: ["value"]),
                ],
                required: ["first", "second"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(try graph.scalar(at: ["first", "value"]).type == "string")
            #expect(try graph.scalar(at: ["second", "value"]).type == "integer")
        }

        @available(macOS 26, iOS 26, *)
        @Test func structurallyIdenticalSiblingsRemainDistinctOccurrences() throws {
            let twin = JSONSchema.object(properties: ["id": .string()], required: ["id"])
            let schema = JSONSchema.object(
                properties: ["twinA": twin, "twinB": twin],
                required: ["twinA", "twinB"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.definitionNames == ["Object_1", "Object_2"])
            #expect(try graph.reference(at: ["twinA"]).target == "Object_1")
            #expect(try graph.reference(at: ["twinB"]).target == "Object_2")
            #expect(try graph.resolvedObject(at: ["twinA"]).properties.keys.sorted() == ["id"])
            #expect(try graph.resolvedObject(at: ["twinB"]).properties.keys.sorted() == ["id"])
        }

        @available(macOS 26, iOS 26, *)
        @Test func requiredNestedEmptyObjectBecomesZeroPropertyDependency() throws {
            let schema = JSONSchema.object(
                properties: [
                    "empty": .object(properties: [:], required: [], description: "Empty payload"),
                ],
                required: ["empty"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.definitionNames == ["Object_1"])
            #expect(graph.root.required == ["empty"])
            #expect(try graph.reference(at: ["empty"]).target == "Object_1")
            let definition = try graph.resolvedObject(at: ["empty"])
            #expect(definition.properties.isEmpty)
            #expect(definition.description == "Empty payload")
            try graph.validateFiniteResolution()
        }

        @available(macOS 26, iOS 26, *)
        @Test func definitionCountMatchesNonRootObjectOccurrences() throws {
            let schema = JSONSchema.object(
                properties: [
                    "outer": .object(
                        properties: [
                            "inner": .object(properties: ["leaf": .string()], required: ["leaf"]),
                        ],
                        required: ["inner"]
                    ),
                    "rows": .array(items: .object(properties: ["cell": .integer()], required: ["cell"])),
                    "extra": .object(properties: ["note": .string()], required: []).optional(),
                ],
                required: ["outer", "rows"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.definitionNames == ["Object_1", "Object_2", "Object_3", "Object_4"])
            #expect(try graph.reference(at: ["extra"]).target == "Object_1")
            #expect(try graph.reference(at: ["outer"]).target == "Object_2")
            #expect(try graph.reference(at: ["outer", "inner"]).target == "Object_3")
            #expect(try graph.reference(at: ["rows", .items]).target == "Object_4")
            #expect(try graph.validateFiniteResolution() == Set(graph.definitionNames))
        }
    }

    @Suite(.serialized) struct FMSchemaConverterMetadataTests {
        @available(macOS 26, iOS 26, *)
        @Test func descriptionsSurviveAtEveryBoundary() throws {
            let schema = JSONSchema.object(
                properties: [
                    "kind": .string(description: "Kind leaf"),
                    "payload": .object(
                        properties: ["value": .string(description: "Value leaf")],
                        required: ["value"],
                        description: "Payload definition"
                    ),
                ],
                required: ["kind", "payload"],
                description: "Root description"
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.root.description == "Root description")
            #expect(try graph.scalar(at: ["kind"]).description == "Kind leaf")
            let payload = try graph.reference(at: ["payload"])
            #expect(payload.target == "Object_1")
            #expect(payload.description == "Payload definition")
            let definition = try graph.definition("Object_1")
            #expect(definition.title == "Object_1")
            #expect(definition.description == "Payload definition")
            #expect(try graph.scalar(at: ["payload", "value"]).description == "Value leaf")
        }

        @available(macOS 26, iOS 26, *)
        @Test func descriptionsSurviveTheNullableUnwrap() throws {
            let schema = JSONSchema.object(
                properties: [
                    "nickname": .string(description: "Preferred nickname").optional(),
                    "tags": .array(items: .string(), description: "Free-form tags").optional(),
                    "payload": .object(
                        properties: ["value": .string()],
                        required: ["value"],
                        description: "Payload definition"
                    ).optional(),
                ],
                required: []
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.root.required.isEmpty)
            let nickname = try graph.scalar(at: ["nickname"])
            #expect(nickname.type == "string")
            #expect(nickname.description == "Preferred nickname")
            #expect(try graph.node(at: ["tags"]).description == "Free-form tags")
            let payload = try graph.reference(at: ["payload"])
            #expect(payload.target == "Object_1")
            #expect(payload.description == "Payload definition")
            #expect(try graph.resolvedObject(at: ["payload"]).description == "Payload definition")
        }

        @available(macOS 26, iOS 26, *)
        @Test func lexicographicOrderHoldsAtRootAndInsideDefinitions() throws {
            let schema = JSONSchema.object(
                properties: [
                    "zebra": .string(),
                    "apple": .integer(),
                    "mango": .object(
                        properties: ["delta": .integer(), "charlie": .string()],
                        required: ["delta"]
                    ),
                ],
                required: ["zebra", "mango"]
            )
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.root.order == ["apple", "mango", "zebra"])
            let mango = try graph.resolvedObject(at: ["mango"])
            #expect(mango.order == ["charlie", "delta"])
            #expect(mango.required == ["delta"])
        }
    }

    @Suite(.serialized) struct FMSchemaConverterDeterminismTests {
        @available(macOS 26, iOS 26, *)
        @Test func differentDictionaryAssemblyOrdersCompileIdentically() throws {
            var forward: [String: JSONSchema] = [:]
            forward["alpha"] = .object(properties: ["code": .string()], required: ["code"])
            forward["beta"] = .object(properties: ["count": .integer()], required: ["count"])
            var reversed: [String: JSONSchema] = [:]
            reversed["beta"] = .object(properties: ["count": .integer()], required: ["count"])
            reversed["alpha"] = .object(properties: ["code": .string()], required: ["code"])
            let first = try EncodedSchemaGraph(
                schema: FMSchemaConverter.convert(.object(properties: forward, required: ["alpha", "beta"]))
            )
            let second = try EncodedSchemaGraph(
                schema: FMSchemaConverter.convert(.object(properties: reversed, required: ["beta", "alpha"]))
            )
            #expect(first.root == second.root)
            #expect(first.definitions == second.definitions)
        }

        @available(macOS 26, iOS 26, *)
        @Test func nonLexicalDictionaryEnumerationStillCompilesLexicographically() throws {
            let properties = try #require(Self.nonLexicallyEnumeratedProperties())
            let schema = JSONSchema.object(properties: properties, required: Array(properties.keys))
            let graph = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            #expect(graph.root.order == properties.keys.sorted())
            #expect(Set(graph.root.required) == Set(properties.keys))
        }

        @available(macOS 26, iOS 26, *)
        @Test func repeatedConversionIsDeterministic() throws {
            let schema = JSONSchema.object(
                properties: [
                    "wrapper": .object(
                        properties: [
                            "child": .object(properties: ["value": .string()], required: ["value"]),
                        ],
                        required: ["child"]
                    ),
                    "rows": .array(items: .object(properties: ["cell": .integer()], required: ["cell"])),
                ],
                required: ["wrapper"]
            )
            let baseline = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
            for _ in 0 ..< 3 {
                let repeated = try EncodedSchemaGraph(schema: FMSchemaConverter.convert(schema))
                #expect(repeated.root == baseline.root)
                #expect(repeated.definitions == baseline.definitions)
            }
        }

        private static func nonLexicallyEnumeratedProperties() -> [String: JSONSchema]? {
            for family in 0 ..< 16 {
                var properties: [String: JSONSchema] = [:]
                for index in 0 ..< 8 {
                    properties["p\(family)_\(index)"] = .string()
                }
                if Array(properties.keys) != properties.keys.sorted() {
                    return properties
                }
            }
            return nil
        }
    }

#endif
