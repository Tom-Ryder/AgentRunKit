import Foundation

/// File-based checkpointer storing one JSON file per checkpoint under `<directory>/checkpoints/`.
public actor FileCheckpointer: AgentCheckpointer {
    private let baseDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, fileManager: FileManager = .default) {
        baseDirectory = directory.appending(path: "checkpoints", directoryHint: .isDirectory)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func save(_ checkpoint: AgentCheckpoint) async throws {
        try ensureBaseDirectory()
        let url = fileURL(for: checkpoint.checkpointID)
        do {
            let data = try encoder.encode(checkpoint)
            try data.write(to: url, options: .atomic)
        } catch {
            throw AgentCheckpointError.fileSystem("Failed to write checkpoint: \(error)")
        }
    }

    public func load(_ id: CheckpointID) async throws -> AgentCheckpoint {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AgentCheckpointError.notFound(id)
        }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(AgentCheckpoint.self, from: data)
        } catch {
            throw AgentCheckpointError.fileSystem("Failed to load checkpoint \(id.rawValue.uuidString): \(error)")
        }
    }

    public func list(session: SessionID) async throws -> [CheckpointID] {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: baseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            throw AgentCheckpointError.fileSystem("Failed to enumerate checkpoint directory: \(error)")
        }
        var matched: [AgentCheckpoint] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let checkpoint = try? decoder.decode(AgentCheckpoint.self, from: data)
            else { continue }
            if checkpoint.sessionID == session { matched.append(checkpoint) }
        }
        return matched
            .sorted { lhs, rhs in
                if lhs.iteration != rhs.iteration { return lhs.iteration < rhs.iteration }
                return lhs.timestamp < rhs.timestamp
            }
            .map(\.checkpointID)
    }

    private func ensureBaseDirectory() throws {
        if fileManager.fileExists(atPath: baseDirectory.path) { return }
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            throw AgentCheckpointError.fileSystem("Failed to create checkpoint directory: \(error)")
        }
    }

    private func fileURL(for id: CheckpointID) -> URL {
        baseDirectory.appending(path: "\(id.rawValue.uuidString).json")
    }
}
