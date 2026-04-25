import Foundation

/// Serializable snapshot of an agent's context-budget phase.
public struct ContextBudgetCheckpointState: Sendable, Codable, Equatable {
    public let config: ContextBudgetConfig
    public let windowSize: Int
    public let lastBudget: ContextBudget?
    public let softAdvisoryArmed: Bool

    public init(
        config: ContextBudgetConfig,
        windowSize: Int,
        lastBudget: ContextBudget?,
        softAdvisoryArmed: Bool
    ) {
        precondition(windowSize >= 1, "windowSize must be at least 1")
        self.config = config
        self.windowSize = windowSize
        self.lastBudget = lastBudget
        self.softAdvisoryArmed = softAdvisoryArmed
    }

    private enum CodingKeys: String, CodingKey {
        case config, windowSize, lastBudget, softAdvisoryArmed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let windowSize = try container.decode(Int.self, forKey: .windowSize)
        guard windowSize >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .windowSize, in: container,
                debugDescription: "windowSize must be >= 1, got \(windowSize)"
            )
        }
        try self.init(
            config: container.decode(ContextBudgetConfig.self, forKey: .config),
            windowSize: windowSize,
            lastBudget: container.decodeIfPresent(ContextBudget.self, forKey: .lastBudget),
            softAdvisoryArmed: container.decode(Bool.self, forKey: .softAdvisoryArmed)
        )
    }
}

/// Identifies a live MCP tool binding required to resume a checkpoint.
public struct MCPToolBinding: Sendable, Codable, Hashable {
    public let serverName: String
    public let toolName: String

    public init(serverName: String, toolName: String) {
        precondition(!serverName.isEmpty, "serverName must be non-empty")
        precondition(!toolName.isEmpty, "toolName must be non-empty")
        self.serverName = serverName
        self.toolName = toolName
    }

    private enum CodingKeys: String, CodingKey { case serverName, toolName }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let serverName = try container.decode(String.self, forKey: .serverName)
        let toolName = try container.decode(String.self, forKey: .toolName)
        guard !serverName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .serverName, in: container,
                debugDescription: "MCPToolBinding.serverName must be non-empty"
            )
        }
        guard !toolName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .toolName, in: container,
                debugDescription: "MCPToolBinding.toolName must be non-empty"
            )
        }
        self.init(serverName: serverName, toolName: toolName)
    }
}

/// Serializable snapshot of agent loop state captured at a full iteration boundary.
public struct AgentCheckpoint: Sendable, Codable, Identifiable {
    public let messages: [ChatMessage]
    public let iteration: Int
    public let tokenUsage: TokenUsage
    public let iterationUsage: TokenUsage?
    public let contextBudgetState: ContextBudgetCheckpointState?
    public let historyWasRewrittenLocally: Bool
    public let sessionAllowlist: Set<String>
    public let sessionID: SessionID
    public let runID: RunID
    public let checkpointID: CheckpointID
    public let timestamp: Date
    public let mcpToolBindings: Set<MCPToolBinding>

    public var id: CheckpointID {
        checkpointID
    }

    public init(
        messages: [ChatMessage],
        iteration: Int,
        tokenUsage: TokenUsage,
        iterationUsage: TokenUsage? = nil,
        contextBudgetState: ContextBudgetCheckpointState? = nil,
        historyWasRewrittenLocally: Bool = false,
        sessionAllowlist: Set<String> = [],
        sessionID: SessionID,
        runID: RunID,
        checkpointID: CheckpointID = CheckpointID(),
        timestamp: Date = Date(),
        mcpToolBindings: Set<MCPToolBinding> = []
    ) {
        precondition(iteration >= 0, "iteration must be non-negative")
        self.messages = messages
        self.iteration = iteration
        self.tokenUsage = tokenUsage
        self.iterationUsage = iterationUsage
        self.contextBudgetState = contextBudgetState
        self.historyWasRewrittenLocally = historyWasRewrittenLocally
        self.sessionAllowlist = sessionAllowlist
        self.sessionID = sessionID
        self.runID = runID
        self.checkpointID = checkpointID
        self.timestamp = timestamp
        self.mcpToolBindings = mcpToolBindings
    }

    private enum CodingKeys: String, CodingKey {
        case messages, iteration, tokenUsage, iterationUsage, contextBudgetState
        case historyWasRewrittenLocally, sessionAllowlist
        case sessionID, runID, checkpointID, timestamp, mcpToolBindings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let iteration = try container.decode(Int.self, forKey: .iteration)
        guard iteration >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .iteration, in: container,
                debugDescription: "AgentCheckpoint.iteration must be non-negative, got \(iteration)"
            )
        }
        try self.init(
            messages: container.decode([ChatMessage].self, forKey: .messages),
            iteration: iteration,
            tokenUsage: container.decode(TokenUsage.self, forKey: .tokenUsage),
            iterationUsage: container.decodeIfPresent(TokenUsage.self, forKey: .iterationUsage),
            contextBudgetState: container.decodeIfPresent(
                ContextBudgetCheckpointState.self, forKey: .contextBudgetState
            ),
            historyWasRewrittenLocally: container.decodeIfPresent(
                Bool.self, forKey: .historyWasRewrittenLocally
            ) ?? false,
            sessionAllowlist: Set(container.decodeIfPresent([String].self, forKey: .sessionAllowlist) ?? []),
            sessionID: container.decode(SessionID.self, forKey: .sessionID),
            runID: container.decode(RunID.self, forKey: .runID),
            checkpointID: container.decode(CheckpointID.self, forKey: .checkpointID),
            timestamp: container.decode(Date.self, forKey: .timestamp),
            mcpToolBindings: Set(container.decodeIfPresent(
                [MCPToolBinding].self, forKey: .mcpToolBindings
            ) ?? [])
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messages, forKey: .messages)
        try container.encode(iteration, forKey: .iteration)
        try container.encode(tokenUsage, forKey: .tokenUsage)
        try container.encodeIfPresent(iterationUsage, forKey: .iterationUsage)
        try container.encodeIfPresent(contextBudgetState, forKey: .contextBudgetState)
        if historyWasRewrittenLocally {
            try container.encode(historyWasRewrittenLocally, forKey: .historyWasRewrittenLocally)
        }
        if !sessionAllowlist.isEmpty {
            try container.encode(sessionAllowlist.sorted(), forKey: .sessionAllowlist)
        }
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(runID, forKey: .runID)
        try container.encode(checkpointID, forKey: .checkpointID)
        try container.encode(timestamp, forKey: .timestamp)
        if !mcpToolBindings.isEmpty {
            try container.encode(
                mcpToolBindings.sorted { ($0.serverName, $0.toolName) < ($1.serverName, $1.toolName) },
                forKey: .mcpToolBindings
            )
        }
    }
}

/// Errors thrown by `AgentCheckpointer` backends and `Agent.resume`.
public enum AgentCheckpointError: Error, Sendable, Equatable, LocalizedError {
    case notFound(CheckpointID)
    case fileSystem(String)
    case mcpBindingMismatch([MCPToolBinding])

    public var errorDescription: String? {
        switch self {
        case let .notFound(id):
            return "Checkpoint not found: \(id.rawValue.uuidString)"
        case let .fileSystem(reason):
            return "Checkpoint file system error: \(reason)"
        case let .mcpBindingMismatch(missing):
            let names = missing.map { "\($0.serverName)::\($0.toolName)" }.joined(separator: ", ")
            return "Missing MCP tool bindings on resume: \(names)"
        }
    }
}
