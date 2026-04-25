import Foundation

private enum IdentifierCoding {
    static func decodeUUID(from decoder: any Decoder, typeName: String) throws -> UUID {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid \(typeName) UUID string: \(string)"
            )
        }
        return uuid
    }

    static func encodeUUID(_ uuid: UUID, to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid.uuidString)
    }
}

/// Uniquely identifies a streamed event.
public struct EventID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder, typeName: "EventID")
    }

    public func encode(to encoder: any Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}

/// Uniquely identifies an agent session.
public struct SessionID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder, typeName: "SessionID")
    }

    public func encode(to encoder: any Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}

/// Uniquely identifies an agent run within a session.
public struct RunID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder, typeName: "RunID")
    }

    public func encode(to encoder: any Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}

/// Uniquely identifies a persisted checkpoint.
public struct CheckpointID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try IdentifierCoding.decodeUUID(from: decoder, typeName: "CheckpointID")
    }

    public func encode(to encoder: any Encoder) throws {
        try IdentifierCoding.encodeUUID(rawValue, to: encoder)
    }
}
