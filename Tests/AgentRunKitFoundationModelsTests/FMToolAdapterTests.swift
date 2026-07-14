#if canImport(FoundationModels)

    import AgentRunKit
    @testable import AgentRunKitFoundationModels
    import Foundation
    import FoundationModels
    import Testing

    private struct EchoTool: AnyTool {
        typealias Context = EmptyContext
        let name = "echo"
        let description = "Echoes the input"
        let parametersSchema = JSONSchema.object(
            properties: ["message": .string(description: "The message")],
            required: ["message"]
        )

        func execute(arguments: Data, context _: EmptyContext) async throws -> ToolResult {
            let decoded = try JSONDecoder().decode([String: String].self, from: arguments)
            return .success("Echo: \(decoded["message"] ?? "")")
        }
    }

    private struct BadSchemaTool: AnyTool {
        typealias Context = EmptyContext
        let name = "bad"
        let description = "Bad schema"
        let parametersSchema = JSONSchema.string()

        func execute(arguments _: Data, context _: EmptyContext) async throws -> ToolResult {
            .success("")
        }
    }

    private struct RouteStart: Codable, Equatable {
        let street: String
        let houseNumber: Int
    }

    private struct RouteRating: Codable, Equatable {
        let score: Double
        let flagged: Bool
    }

    private struct RouteStop: Codable, Equatable {
        let label: String
    }

    private struct PlanRouteParams: Codable, SchemaProviding, Equatable {
        let start: RouteStart
        let rating: RouteRating
        let waypoints: [RouteStop]
        let note: String?
    }

    private struct PlannedRoute: Codable {
        let confirmation: String
    }

    private struct InventoryItem: Codable {
        let sku: String
    }

    private struct AuditParams: Codable, SchemaProviding {
        let item: InventoryItem
    }

    private struct AuditReport: Codable {
        let status: String
    }

    private enum AdapterFixture {
        case route
        case audit
    }

    private actor ConstructionGate {
        private let capacity: Int
        private var arrivals = 0
        private var pending: [CheckedContinuation<Void, Never>] = []

        init(capacity: Int) {
            self.capacity = capacity
        }

        func arrive() async {
            arrivals += 1
            if arrivals >= capacity {
                for continuation in pending {
                    continuation.resume()
                }
                pending.removeAll()
                return
            }
            await withCheckedContinuation { pending.append($0) }
        }
    }

    private func makeRouteTool(
        recorder: ParamsRecorder<PlanRouteParams>
    ) throws -> AgentRunKit.Tool<PlanRouteParams, PlannedRoute, EmptyContext> {
        try AgentRunKit.Tool(
            name: "plan_route",
            description: "Plans a scenic route between two points."
        ) { params, _ in
            await recorder.record(params)
            return PlannedRoute(confirmation: "route-ok")
        }
    }

    private func makeAuditTool() throws -> AgentRunKit.Tool<AuditParams, AuditReport, EmptyContext> {
        try AgentRunKit.Tool(
            name: "audit_item",
            description: "Audits one inventory item."
        ) { _, _ in
            AuditReport(status: "audited")
        }
    }

    @Suite(.serialized) struct FMToolAdapterTests {
        @available(macOS 26, iOS 26, *)
        @Test func adapterNameMatchesWrappedTool() throws {
            let adapter = try FMToolAdapter(wrapping: EchoTool(), context: EmptyContext())
            #expect(adapter.name == "echo")
            #expect(adapter.description == "Echoes the input")
        }

        @available(macOS 26, iOS 26, *)
        @Test func adapterWithUnsupportedSchemaThrows() {
            let error = #expect(throws: AgentError.self) {
                try FMToolAdapter(wrapping: BadSchemaTool(), context: EmptyContext())
            }
            guard case let .schemaInferenceFailed(type, _) = error else {
                Issue.record("Expected schemaInferenceFailed, got \(String(describing: error))")
                return
            }
            #expect(type == "Arguments")
        }

        @available(macOS 26, iOS 26, *)
        @Test func toJSONValueString() throws {
            let generated = try makeContent(json: #"{"value":"hello"}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["value"] == .string("hello"))
        }

        @available(macOS 26, iOS 26, *)
        @Test func toJSONValueInteger() throws {
            let generated = try makeContent(json: #"{"count":42}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["count"] == .int(42))
        }

        @available(macOS 26, iOS 26, *)
        @Test func toJSONValueDouble() throws {
            let generated = try makeContent(json: #"{"score":3.14}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["score"] == .double(3.14))
        }

        @available(macOS 26, iOS 26, *)
        @Test func toJSONValueBool() throws {
            let generated = try makeContent(json: #"{"flag":true}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["flag"] == .bool(true))
        }

        @available(macOS 26, iOS 26, *)
        @Test func toJSONValueArray() throws {
            let generated = try makeContent(json: #"{"items":["a","b"]}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["items"] == .array([.string("a"), .string("b")]))
        }

        @available(macOS 26, iOS 26, *)
        @Test func toJSONValueRoundTrip() throws {
            let generated = try makeContent(json: #"{"name":"test","count":5}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            let data = try JSONEncoder().encode(jsonValue)
            let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
            #expect(decoded["name"] == .string("test"))
            #expect(decoded["count"] == .int(5))
        }

        @available(macOS 26, iOS 26, *)
        @Test func toJSONValueNull() throws {
            let generated = try makeContent(json: #"{"missing":null}"#)
            let jsonValue = try FMToolAdapter<EmptyContext>.toJSONValue(generated)
            guard case let .object(dict) = jsonValue else {
                Issue.record("Expected object")
                return
            }
            #expect(dict["missing"] == .null)
        }
    }

    @Suite(.serialized) struct FMToolAdapterContractTests {
        @available(macOS 26, iOS 26, *)
        @Test func adapterSchemaMatchesWrappedToolContract() throws {
            let adapter = try FMToolAdapter(wrapping: EchoTool(), context: EmptyContext())
            let graph = try EncodedSchemaGraph(schema: adapter.parameters)
            #expect(graph.root.title == "Arguments")
            #expect(graph.root.required == ["message"])
            let message = try graph.scalar(at: ["message"])
            #expect(message.type == "string")
            #expect(message.description == "The message")
        }

        @available(macOS 26, iOS 26, *)
        @Test func inferredNestedContractIsAdvertisedLosslessly() throws {
            let tool = try makeRouteTool(recorder: ParamsRecorder())
            let adapter = try FMToolAdapter(wrapping: tool, context: EmptyContext())
            let graph = try EncodedSchemaGraph(schema: adapter.parameters)

            #expect(graph.root.title == "Arguments")
            #expect(graph.definitionNames == ["Object_1", "Object_2", "Object_3"])
            #expect(Set(graph.root.required) == ["rating", "start", "waypoints"])
            try graph.validateFiniteResolution()

            #expect(try graph.reference(at: ["rating"]).target == "Object_1")
            #expect(try graph.scalar(at: ["rating", "score"]).type == "number")
            #expect(try graph.scalar(at: ["rating", "flagged"]).type == "boolean")

            #expect(try graph.reference(at: ["start"]).target == "Object_2")
            #expect(try graph.scalar(at: ["start", "street"]).type == "string")
            #expect(try graph.scalar(at: ["start", "houseNumber"]).type == "integer")

            #expect(try graph.reference(at: ["waypoints", .items]).target == "Object_3")
            #expect(try graph.scalar(at: ["waypoints", .items, "label"]).type == "string")

            #expect(try graph.scalar(at: ["note"]).type == "string")
        }

        @available(macOS 26, iOS 26, *)
        @Test func validGeneratedContentReachesTypedExecutorExactly() async throws {
            let recorder = ParamsRecorder<PlanRouteParams>()
            let adapter = try FMToolAdapter(wrapping: makeRouteTool(recorder: recorder), context: EmptyContext())
            let content = try GeneratedContent(json: """
            {
              "start": {"street": "Via Roma", "houseNumber": 7},
              "rating": {"score": 4.5, "flagged": true},
              "waypoints": [{"label": "harbor"}, {"label": "castle"}],
              "note": "scenic"
            }
            """)

            let output = try await adapter.call(arguments: content)

            #expect(output == #"{"confirmation":"route-ok"}"#)
            let received = await recorder.received
            #expect(received == [PlanRouteParams(
                start: RouteStart(street: "Via Roma", houseNumber: 7),
                rating: RouteRating(score: 4.5, flagged: true),
                waypoints: [RouteStop(label: "harbor"), RouteStop(label: "castle")],
                note: "scenic"
            )])
        }

        @available(macOS 26, iOS 26, *)
        @Test func malformedGeneratedContentFailsWithTypedDecodingError() async throws {
            let recorder = ParamsRecorder<PlanRouteParams>()
            let adapter = try FMToolAdapter(wrapping: makeRouteTool(recorder: recorder), context: EmptyContext())
            let content = try GeneratedContent(json: """
            {
              "start": {"street": "Via Roma", "houseNumber": 7},
              "rating": {"flagged": true},
              "waypoints": []
            }
            """)

            let error = await #expect(throws: AgentError.self) {
                _ = try await adapter.call(arguments: content)
            }

            guard case let .toolDecodingFailed(toolName, _) = error else {
                Issue.record("Expected toolDecodingFailed, got \(String(describing: error))")
                return
            }
            #expect(toolName == "plan_route")
            let received = await recorder.received
            #expect(received.isEmpty)
        }

        @available(macOS 26, iOS 26, *)
        @Test func repeatedAndCrossToolConstructionIsSelfContained() throws {
            let routeTool = try makeRouteTool(recorder: ParamsRecorder())
            let auditTool = try makeAuditTool()
            let context = EmptyContext()
            let routeBaseline = try EncodedSchemaGraph(
                schema: FMToolAdapter(wrapping: routeTool, context: context).parameters
            )
            let auditBaseline = try EncodedSchemaGraph(
                schema: FMToolAdapter(wrapping: auditTool, context: context).parameters
            )

            #expect(routeBaseline.definitions["Object_1"]?.properties.keys.sorted() == ["flagged", "score"])
            #expect(auditBaseline.definitionNames == ["Object_1"])
            #expect(auditBaseline.definitions["Object_1"]?.properties.keys.sorted() == ["sku"])
            #expect(try auditBaseline.scalar(at: ["item", "sku"]).type == "string")

            for _ in 0 ..< 3 {
                let route = try EncodedSchemaGraph(
                    schema: FMToolAdapter(wrapping: routeTool, context: context).parameters
                )
                let audit = try EncodedSchemaGraph(
                    schema: FMToolAdapter(wrapping: auditTool, context: context).parameters
                )
                #expect(route.root == routeBaseline.root)
                #expect(route.definitions == routeBaseline.definitions)
                #expect(audit.root == auditBaseline.root)
                #expect(audit.definitions == auditBaseline.definitions)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func synchronizedConcurrentConstructionMatchesSequentialBaselines() async throws {
            let routeTool = try makeRouteTool(recorder: ParamsRecorder())
            let auditTool = try makeAuditTool()
            let context = EmptyContext()
            let routeBaseline = try EncodedSchemaGraph(
                schema: FMToolAdapter(wrapping: routeTool, context: context).parameters
            )
            let auditBaseline = try EncodedSchemaGraph(
                schema: FMToolAdapter(wrapping: auditTool, context: context).parameters
            )

            let taskCount = 8
            let gate = ConstructionGate(capacity: taskCount)
            let results = try await withThrowingTaskGroup(
                of: (fixture: AdapterFixture, graph: EncodedSchemaGraph).self
            ) { group in
                for index in 0 ..< taskCount {
                    let fixture: AdapterFixture = index.isMultiple(of: 2) ? .route : .audit
                    group.addTask {
                        await gate.arrive()
                        let adapter: FMToolAdapter<EmptyContext> = switch fixture {
                        case .route: try FMToolAdapter(wrapping: routeTool, context: context)
                        case .audit: try FMToolAdapter(wrapping: auditTool, context: context)
                        }
                        return try (fixture, EncodedSchemaGraph(schema: adapter.parameters))
                    }
                }
                var collected: [(fixture: AdapterFixture, graph: EncodedSchemaGraph)] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected
            }

            #expect(results.count == taskCount)
            for result in results {
                let baseline = switch result.fixture {
                case .route: routeBaseline
                case .audit: auditBaseline
                }
                #expect(result.graph.root == baseline.root)
                #expect(result.graph.definitions == baseline.definitions)
            }
        }
    }

    @available(macOS 26, iOS 26, *)
    private func makeContent(json: String) throws -> GeneratedContent {
        try GeneratedContent(json: json)
    }

#endif
