#if canImport(FoundationModels)

    import AgentRunKit
    import Foundation
    import FoundationModels

    private struct SchemaProjectionError: Error, CustomStringConvertible {
        enum Layer {
            case sdkRepresentation
            case graphNavigation
        }

        let layer: Layer
        let path: String
        let reason: String
        let observed: JSONValue?

        static func sdkRepresentation(path: String, reason: String, observed: JSONValue) -> SchemaProjectionError {
            SchemaProjectionError(layer: .sdkRepresentation, path: path, reason: reason, observed: observed)
        }

        static func graphNavigation(path: String, reason: String) -> SchemaProjectionError {
            SchemaProjectionError(layer: .graphNavigation, path: path, reason: reason, observed: nil)
        }

        var description: String {
            var message = "Foundation Models encoded-representation projection failed at '\(path)': \(reason)."
            if case .sdkRepresentation = layer {
                message += " This indicates an SDK representation change, not a converter regression."
            }
            if let observed {
                message += " Observed: \(renderJSON(observed))"
            }
            return message
        }
    }

    private func renderJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    @available(macOS 26, iOS 26, *)
    struct EncodedSchemaGraph {
        // swiftformat:disable:next redundantSendable -- Sendable is not inferred across the Node/ObjectNode recursion
        indirect enum Node: Equatable, Sendable {
            case object(ObjectNode)
            case scalar(type: String, description: String?)
            case array(items: Node, description: String?)
            case reference(target: String, description: String?)

            var description: String? {
                switch self {
                case let .object(node): node.description
                case let .scalar(_, description): description
                case let .array(_, description): description
                case let .reference(_, description): description
                }
            }
        }

        struct ObjectNode: Equatable {
            let title: String?
            let description: String?
            let required: [String]
            let order: [String]
            let properties: [String: Node]
        }

        enum PathStep: ExpressibleByStringLiteral {
            case property(String)
            case items

            init(stringLiteral value: String) {
                self = .property(value)
            }
        }

        let root: ObjectNode
        let definitions: [String: ObjectNode]
        private let context: String

        var definitionNames: [String] {
            definitions.keys.sorted()
        }

        init(schema: GenerationSchema) throws {
            let data = try JSONEncoder().encode(schema)
            let encoded = try JSONDecoder().decode(JSONValue.self, from: data)
            try self.init(encodedSchema: encoded, context: "GenerationSchema")
        }

        init(encodedSchema: JSONValue, context: String) throws {
            guard let object = encodedSchema.objectValue else {
                throw SchemaProjectionError.sdkRepresentation(
                    path: context,
                    reason: "encoded schema is not a JSON object",
                    observed: encodedSchema
                )
            }
            var definitions: [String: ObjectNode] = [:]
            if let defsValue = object["$defs"] {
                guard let defs = defsValue.objectValue else {
                    throw SchemaProjectionError.sdkRepresentation(
                        path: "\(context).$defs",
                        reason: "'$defs' is not a JSON object",
                        observed: defsValue
                    )
                }
                for (name, value) in defs {
                    let path = "\(context).$defs.\(name)"
                    guard case let .object(node) = try Self.parseNode(value, at: path) else {
                        throw SchemaProjectionError.sdkRepresentation(
                            path: path,
                            reason: "definition is not an object schema",
                            observed: value
                        )
                    }
                    definitions[name] = node
                }
            }
            guard case let .object(rootNode) = try Self.parseNode(encodedSchema, at: context) else {
                throw SchemaProjectionError.sdkRepresentation(
                    path: context,
                    reason: "root is not an object schema",
                    observed: encodedSchema
                )
            }
            root = rootNode
            self.definitions = definitions
            self.context = context
        }

        func definition(_ name: String) throws -> ObjectNode {
            guard let definition = definitions[name] else {
                throw SchemaProjectionError.graphNavigation(
                    path: "\(context).$defs.\(name)",
                    reason: "unresolved reference to '\(name)'; known definitions: \(definitionNames)"
                )
            }
            return definition
        }

        func node(at path: [PathStep]) throws -> Node {
            var current = Node.object(root)
            var location = context
            for step in path {
                current = try resolvingReference(current)
                switch step {
                case let .property(name):
                    guard case let .object(objectNode) = current else {
                        throw SchemaProjectionError.graphNavigation(
                            path: location,
                            reason: "expected an object schema before '.\(name)'"
                        )
                    }
                    guard let child = objectNode.properties[name] else {
                        throw SchemaProjectionError.graphNavigation(
                            path: "\(location).\(name)",
                            reason: "missing property '\(name)'; available: \(objectNode.properties.keys.sorted())"
                        )
                    }
                    current = child
                    location += ".\(name)"
                case .items:
                    guard case let .array(items, _) = current else {
                        throw SchemaProjectionError.graphNavigation(
                            path: location,
                            reason: "expected an array schema before item traversal"
                        )
                    }
                    current = items
                    location += "[items]"
                }
            }
            return current
        }

        func resolvedObject(at path: [PathStep]) throws -> ObjectNode {
            let resolved = try resolvingReference(node(at: path))
            guard case let .object(objectNode) = resolved else {
                throw SchemaProjectionError.graphNavigation(
                    path: location(of: path),
                    reason: "expected an object schema"
                )
            }
            return objectNode
        }

        func scalar(at path: [PathStep]) throws -> (type: String, description: String?) {
            guard case let .scalar(type, description) = try node(at: path) else {
                throw SchemaProjectionError.graphNavigation(
                    path: location(of: path),
                    reason: "expected a scalar schema"
                )
            }
            return (type, description)
        }

        func reference(at path: [PathStep]) throws -> (target: String, description: String?) {
            guard case let .reference(target, description) = try node(at: path) else {
                throw SchemaProjectionError.graphNavigation(
                    path: location(of: path),
                    reason: "expected an explicit reference"
                )
            }
            return (target, description)
        }

        @discardableResult
        func validateFiniteResolution() throws -> Set<String> {
            var expanded = Set<String>()
            try validateFiniteResolution(from: .object(root), chain: [], expanded: &expanded)
            return expanded
        }

        private func validateFiniteResolution(
            from node: Node,
            chain: [String],
            expanded: inout Set<String>
        ) throws {
            switch node {
            case .scalar:
                return
            case let .array(items, _):
                try validateFiniteResolution(from: items, chain: chain, expanded: &expanded)
            case let .object(objectNode):
                for (_, child) in objectNode.properties.sorted(by: { $0.key < $1.key }) {
                    try validateFiniteResolution(from: child, chain: chain, expanded: &expanded)
                }
            case let .reference(target, _):
                if chain.contains(target) {
                    throw SchemaProjectionError.graphNavigation(
                        path: context,
                        reason: "reference cycle \((chain + [target]).joined(separator: " -> "))"
                    )
                }
                if expanded.contains(target) { return }
                expanded.insert(target)
                try validateFiniteResolution(
                    from: .object(definition(target)),
                    chain: chain + [target],
                    expanded: &expanded
                )
            }
        }

        private func resolvingReference(_ node: Node) throws -> Node {
            guard case let .reference(target, _) = node else { return node }
            return try .object(definition(target))
        }

        private func location(of path: [PathStep]) -> String {
            path.reduce(context) { partial, step in
                switch step {
                case let .property(name): partial + ".\(name)"
                case .items: partial + "[items]"
                }
            }
        }

        private static func parseNode(_ value: JSONValue, at path: String) throws -> Node {
            guard let object = value.objectValue else {
                throw SchemaProjectionError.sdkRepresentation(
                    path: path,
                    reason: "schema node is not a JSON object",
                    observed: value
                )
            }
            let description = object["description"]?.stringValue
            if let referenceValue = object["$ref"] {
                guard let reference = referenceValue.stringValue else {
                    throw SchemaProjectionError.sdkRepresentation(
                        path: "\(path).$ref",
                        reason: "'$ref' is not a string",
                        observed: referenceValue
                    )
                }
                let localPrefix = "#/$defs/"
                guard reference.hasPrefix(localPrefix) else {
                    throw SchemaProjectionError.sdkRepresentation(
                        path: "\(path).$ref",
                        reason: "reference does not use the local '\(localPrefix)' form",
                        observed: referenceValue
                    )
                }
                return .reference(target: String(reference.dropFirst(localPrefix.count)), description: description)
            }
            guard let typeName = object["type"]?.stringValue else {
                throw SchemaProjectionError.sdkRepresentation(
                    path: path,
                    reason: "schema node has no string 'type' and no '$ref'",
                    observed: value
                )
            }
            switch typeName {
            case "object":
                return try .object(parseObjectNode(object, at: path))
            case "array":
                guard let itemsValue = object["items"] else {
                    throw SchemaProjectionError.sdkRepresentation(
                        path: path,
                        reason: "array schema has no 'items'",
                        observed: value
                    )
                }
                return try .array(items: parseNode(itemsValue, at: "\(path).items"), description: description)
            default:
                return .scalar(type: typeName, description: description)
            }
        }

        private static func parseObjectNode(_ object: [String: JSONValue], at path: String) throws -> ObjectNode {
            var properties: [String: Node] = [:]
            if let propertiesValue = object["properties"] {
                guard let propertyEntries = propertiesValue.objectValue else {
                    throw SchemaProjectionError.sdkRepresentation(
                        path: "\(path).properties",
                        reason: "'properties' is not a JSON object",
                        observed: propertiesValue
                    )
                }
                for (name, value) in propertyEntries {
                    properties[name] = try parseNode(value, at: "\(path).\(name)")
                }
            }
            let order = try parseStringArray(object["x-order"], at: "\(path).x-order")
            if order == nil, !properties.isEmpty {
                throw SchemaProjectionError.sdkRepresentation(
                    path: "\(path).x-order",
                    reason: "'x-order' is absent for an object with properties",
                    observed: .object(object)
                )
            }
            return try ObjectNode(
                title: object["title"]?.stringValue,
                description: object["description"]?.stringValue,
                required: parseStringArray(object["required"], at: "\(path).required") ?? [],
                order: order ?? [],
                properties: properties
            )
        }

        private static func parseStringArray(_ value: JSONValue?, at path: String) throws -> [String]? {
            guard let value else { return nil }
            guard let array = value.arrayValue else {
                throw SchemaProjectionError.sdkRepresentation(
                    path: path,
                    reason: "expected an array of strings",
                    observed: value
                )
            }
            return try array.map { element in
                guard let string = element.stringValue else {
                    throw SchemaProjectionError.sdkRepresentation(
                        path: path,
                        reason: "expected an array of strings",
                        observed: value
                    )
                }
                return string
            }
        }
    }

    @available(macOS 26, iOS 26, *)
    func encodedToolParameters(in transcript: Transcript, toolName: String) throws -> JSONValue {
        let data = try JSONEncoder().encode(transcript)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let entriesValue = encoded.objectValue?["transcript"]?.objectValue?["entries"],
              let entries = entriesValue.arrayValue
        else {
            throw SchemaProjectionError.sdkRepresentation(
                path: "transcript.entries",
                reason: "encoded transcript wrapper does not contain an entry array",
                observed: encoded
            )
        }
        var registeredToolNames: [String] = []
        for entry in entries {
            guard let entryObject = entry.objectValue,
                  entryObject["role"]?.stringValue == "instructions",
                  let tools = entryObject["tools"]?.arrayValue
            else { continue }
            for tool in tools {
                guard let function = tool.objectValue?["function"]?.objectValue,
                      let name = function["name"]?.stringValue
                else {
                    throw SchemaProjectionError.sdkRepresentation(
                        path: "transcript.entries[].tools[].function",
                        reason: "tool entry does not carry a named function wrapper",
                        observed: tool
                    )
                }
                guard name == toolName else {
                    registeredToolNames.append(name)
                    continue
                }
                guard let parameters = function["parameters"] else {
                    throw SchemaProjectionError.sdkRepresentation(
                        path: "transcript.entries[].tools[].function.parameters",
                        reason: "tool '\(name)' has no parameters object",
                        observed: tool
                    )
                }
                return parameters
            }
        }
        throw SchemaProjectionError.graphNavigation(
            path: "transcript.entries[].tools[].function.name",
            reason: "no tool named '\(toolName)'; registered: \(registeredToolNames.sorted())"
        )
    }

    private extension JSONValue {
        var objectValue: [String: JSONValue]? {
            guard case let .object(value) = self else { return nil }
            return value
        }

        var arrayValue: [JSONValue]? {
            guard case let .array(value) = self else { return nil }
            return value
        }

        var stringValue: String? {
            guard case let .string(value) = self else { return nil }
            return value
        }
    }

#endif
