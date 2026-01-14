public protocol SchemaProviding: Sendable {
    static var jsonSchema: JSONSchema { get }
}

public extension SchemaProviding where Self: Decodable {
    static var jsonSchema: JSONSchema {
        do {
            return try SchemaDecoder.decode(Self.self)
        } catch {
            preconditionFailure("Failed to generate schema for \(Self.self): \(error)")
        }
    }
}
