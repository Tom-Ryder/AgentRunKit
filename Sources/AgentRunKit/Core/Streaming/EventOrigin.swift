import Foundation

/// Provenance flag distinguishing live agent emission from replayed checkpoint events.
public enum EventOrigin: Sendable, Equatable {
    case live
    case replayed(from: CheckpointID)
}

extension EventOrigin: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case from
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "live":
            self = .live
        case "replayed":
            self = try .replayed(from: container.decode(CheckpointID.self, forKey: .from))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown EventOrigin type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .live:
            try container.encode("live", forKey: .type)
        case let .replayed(checkpointID):
            try container.encode("replayed", forKey: .type)
            try container.encode(checkpointID, forKey: .from)
        }
    }
}
