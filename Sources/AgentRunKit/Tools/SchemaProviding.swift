public protocol SchemaProviding: Sendable {
    static var jsonSchema: JSONSchema { get }
    static func validateSchema() throws(AgentError)
}

public extension SchemaProviding {
    static func validateSchema() throws(AgentError) {}
}

public extension SchemaProviding where Self: Decodable {
    static var jsonSchema: JSONSchema {
        (try? SchemaDecoder.decode(Self.self)) ?? .string()
    }

    static func validateSchema() throws(AgentError) {
        do {
            _ = try SchemaDecoder.decode(Self.self)
        } catch {
            throw AgentError.schemaInferenceFailed(type: String(describing: Self.self), message: String(describing: error))
        }
    }
}
