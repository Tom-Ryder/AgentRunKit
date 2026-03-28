import Foundation

public enum JSONRPCID: Hashable, Sendable, Codable {
    case string(String)
    case int(Int)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSONRPCID must be string, integer, or null"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct JSONRPCRequest: Sendable, Codable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let method: String
    public let params: JSONValue?

    public init(id: JSONRPCID, method: String, params: JSONValue? = nil) {
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A JSON-RPC 2.0 notification (no response expected).
public struct JSONRPCNotification: Sendable, Codable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

public struct JSONRPCErrorObject: Sendable, Codable, Equatable {
    public let code: Int
    public let message: String
    public let data: JSONValue?
}

public struct JSONRPCResponse: Sendable, Codable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let result: JSONValue?
    public let error: JSONRPCErrorObject?

    public init(jsonrpc: String = "2.0", id: JSONRPCID?, result: JSONValue?, error: JSONRPCErrorObject?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        // JSON-RPC 2.0 §5: parse error responses have "id": null.
        // decodeIfPresent would collapse JSON null into Swift nil,
        // losing the distinction between absent id and null id.
        if container.contains(.id) {
            id = try container.decode(JSONRPCID.self, forKey: .id)
        } else {
            id = nil
        }
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(JSONRPCErrorObject.self, forKey: .error)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

extension JSONRPCResponse {
    func decodeResult<T: Decodable>(as _: T.Type) throws -> T {
        guard let result else {
            throw MCPError.invalidResponse("Missing result in response")
        }
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public enum JSONRPCMessage: Sendable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)
}

extension JSONRPCMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, result, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasId = container.contains(.id)
        let hasMethod = container.contains(.method)

        if hasId, hasMethod {
            self = try .request(JSONRPCRequest(from: decoder))
        } else if hasMethod {
            self = try .notification(JSONRPCNotification(from: decoder))
        } else if hasId || container.contains(.result) || container.contains(.error) {
            self = try .response(JSONRPCResponse(from: decoder))
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Cannot determine JSON-RPC message type")
            )
        }
    }
}
