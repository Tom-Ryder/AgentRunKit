#if canImport(FoundationModels)

    import FoundationModels
    import Testing

    @available(macOS 26, iOS 26, *)
    private struct InertBoundaryTool: FoundationModels.Tool {
        typealias Arguments = GeneratedContent

        let name: String
        let description = "Inert schema boundary characterization tool; never invoked."
        let parameters: GenerationSchema

        func call(arguments _: GeneratedContent) async throws -> String {
            preconditionFailure("InertBoundaryTool must never be invoked")
        }
    }

    @Suite(.serialized) struct FMSchemaBoundaryTests {
        @available(macOS 26, iOS 26, *)
        @Test func explicitDependenciesPreserveDistinctFiniteGraph() throws {
            let first = DynamicGenerationSchema(
                name: "Object_1",
                description: "First definition",
                properties: [
                    .init(name: "street", description: "Street leaf", schema: .init(type: String.self)),
                ]
            )
            let second = DynamicGenerationSchema(
                name: "Object_2",
                description: "Second definition",
                properties: [
                    .init(name: "latitude", schema: .init(type: Double.self)),
                ]
            )
            let root = DynamicGenerationSchema(
                name: "Arguments",
                description: "Root description",
                properties: [
                    .init(name: "address", description: "Containing property", schema: .init(referenceTo: "Object_1")),
                    .init(name: "location", schema: .init(referenceTo: "Object_2"), isOptional: true),
                    .init(name: "stops", schema: .init(arrayOf: .init(referenceTo: "Object_1"))),
                ]
            )
            let schema = try GenerationSchema(root: root, dependencies: [first, second])
            let graph = try EncodedSchemaGraph(schema: schema)

            #expect(graph.definitionNames == ["Object_1", "Object_2"])
            #expect(graph.root.title == "Arguments")
            #expect(graph.root.description == "Root description")
            #expect(Set(graph.root.required) == ["address", "stops"])
            #expect(graph.root.order == ["address", "location", "stops"])

            let reachable = try graph.validateFiniteResolution()
            #expect(reachable == ["Object_1", "Object_2"])

            let address = try graph.reference(at: ["address"])
            #expect(address.target == "Object_1")
            #expect(address.description == "Containing property")

            let street = try graph.scalar(at: ["address", "street"])
            #expect(street.type == "string")
            #expect(street.description == "Street leaf")

            #expect(try graph.scalar(at: ["location", "latitude"]).type == "number")
            #expect(try graph.reference(at: ["stops", .items]).target == "Object_1")
            #expect(try graph.scalar(at: ["stops", .items, "street"]).type == "string")

            let firstDefinition = try graph.definition("Object_1")
            #expect(firstDefinition.title == "Object_1")
            #expect(firstDefinition.description == "First definition")
            #expect(firstDefinition.required == ["street"])
            #expect(firstDefinition.order == ["street"])

            let secondDefinition = try graph.definition("Object_2")
            #expect(secondDefinition.description == "Second definition")
            #expect(secondDefinition.properties.keys.sorted() == ["latitude"])
        }

        @available(macOS 26, iOS 26, *)
        @Test func duplicateDependencyIdentityFailsWithTypedError() {
            let first = DynamicGenerationSchema(
                name: "Object_1",
                properties: [.init(name: "code", schema: .init(type: String.self))]
            )
            let second = DynamicGenerationSchema(
                name: "Object_1",
                properties: [.init(name: "count", schema: .init(type: Int.self))]
            )
            let root = DynamicGenerationSchema(
                name: "Arguments",
                properties: [.init(name: "payload", schema: .init(referenceTo: "Object_1"))]
            )
            let error = #expect(throws: GenerationSchema.SchemaError.self) {
                try GenerationSchema(root: root, dependencies: [first, second])
            }
            guard case let .duplicateType(_, type, _) = error else {
                Issue.record("Expected duplicateType, got \(String(describing: error))")
                return
            }
            #expect(type == "Object_1")
        }

        @available(macOS 26, iOS 26, *)
        @Test func undefinedReferenceFailsWithTypedError() {
            let root = DynamicGenerationSchema(
                name: "Arguments",
                properties: [.init(name: "payload", schema: .init(referenceTo: "Object_1"))]
            )
            let error = #expect(throws: GenerationSchema.SchemaError.self) {
                try GenerationSchema(root: root, dependencies: [])
            }
            guard case let .undefinedReferences(_, references, _) = error else {
                Issue.record("Expected undefinedReferences, got \(String(describing: error))")
                return
            }
            #expect(references == ["Object_1"])
        }

        @available(macOS 26, iOS 26, *)
        @Test func coRegisteredToolsRetainSeparateSameNamedDefinitions() throws {
            let alpha = try InertBoundaryTool(
                name: "alpha_boundary",
                parameters: Self.payloadSchema(leaf: .init(name: "code", schema: .init(type: String.self)))
            )
            let beta = try InertBoundaryTool(
                name: "beta_boundary",
                parameters: Self.payloadSchema(leaf: .init(name: "count", schema: .init(type: Int.self)))
            )

            let registrationOrders: [[any FoundationModels.Tool]] = [[alpha, beta], [beta, alpha]]
            for order in registrationOrders {
                let session = LanguageModelSession(
                    tools: order,
                    instructions: "Inert schema boundary characterization."
                )

                let alphaGraph = try EncodedSchemaGraph(
                    encodedSchema: encodedToolParameters(in: session.transcript, toolName: "alpha_boundary"),
                    context: "alpha_boundary.parameters"
                )
                try alphaGraph.validateFiniteResolution()
                #expect(alphaGraph.definitionNames == ["Object_1"])
                #expect(try alphaGraph.resolvedObject(at: ["payload"]).properties.keys.sorted() == ["code"])
                #expect(try alphaGraph.scalar(at: ["payload", "code"]).type == "string")

                let betaGraph = try EncodedSchemaGraph(
                    encodedSchema: encodedToolParameters(in: session.transcript, toolName: "beta_boundary"),
                    context: "beta_boundary.parameters"
                )
                try betaGraph.validateFiniteResolution()
                #expect(betaGraph.definitionNames == ["Object_1"])
                #expect(try betaGraph.resolvedObject(at: ["payload"]).properties.keys.sorted() == ["count"])
                #expect(try betaGraph.scalar(at: ["payload", "count"]).type == "integer")
            }
        }

        @available(macOS 26, iOS 26, *)
        private static func payloadSchema(leaf: DynamicGenerationSchema.Property) throws -> GenerationSchema {
            let definition = DynamicGenerationSchema(name: "Object_1", properties: [leaf])
            let root = DynamicGenerationSchema(
                name: "Arguments",
                properties: [.init(name: "payload", schema: .init(referenceTo: "Object_1"))]
            )
            return try GenerationSchema(root: root, dependencies: [definition])
        }
    }

#endif
