@testable import AgentRunKit
import Foundation
import Testing

private func makeCheckpoint(
    sessionID: SessionID = SessionID(),
    runID: RunID = RunID(),
    iteration: Int = 1,
    checkpointID: CheckpointID = CheckpointID(),
    historyWasRewrittenLocally: Bool = false,
    sessionAllowlist: Set<String> = [],
    mcpToolBindings: Set<MCPToolBinding> = [],
    terminalOutcome: AgentTerminalOutcome? = nil
) -> AgentCheckpoint {
    AgentCheckpoint(
        messages: [.user("Hello"), .assistant(AssistantMessage(content: "Hi"))],
        iteration: iteration,
        tokenUsage: makeTokenUsageTotals(TokenUsage(input: 5, output: 5)),
        iterationUsage: TokenUsage(input: 2, output: 3),
        contextBudgetState: ContextBudgetCheckpointState(
            config: ContextBudgetConfig(softThreshold: 0.5),
            windowSize: 1000,
            lastBudget: ContextBudget(windowSize: 1000, currentUsage: 100, softThreshold: 0.5),
            softAdvisoryArmed: false
        ),
        historyWasRewrittenLocally: historyWasRewrittenLocally,
        sessionAllowlist: sessionAllowlist,
        sessionID: sessionID,
        runID: runID,
        checkpointID: checkpointID,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        mcpToolBindings: mcpToolBindings,
        terminalOutcome: terminalOutcome
    )
}

struct AgentCheckpointCodableTests {
    @Test
    func roundTripPreservesAllFields() throws {
        let original = makeCheckpoint(
            historyWasRewrittenLocally: true,
            sessionAllowlist: ["echo"],
            mcpToolBindings: [
                MCPToolBinding(serverName: "alpha", toolName: "search"),
                MCPToolBinding(serverName: "beta", toolName: "fetch"),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AgentCheckpoint.self, from: data)

        #expect(decoded.checkpointID == original.checkpointID)
        #expect(decoded.sessionID == original.sessionID)
        #expect(decoded.runID == original.runID)
        #expect(decoded.iteration == original.iteration)
        #expect(decoded.tokenUsage == original.tokenUsage)
        #expect(decoded.iterationUsage == original.iterationUsage)
        #expect(decoded.historyWasRewrittenLocally == original.historyWasRewrittenLocally)
        #expect(decoded.sessionAllowlist == original.sessionAllowlist)
        #expect(decoded.mcpToolBindings == original.mcpToolBindings)
        #expect(decoded.contextBudgetState == original.contextBudgetState)
        #expect(decoded.messages == original.messages)
        #expect(decoded.timestamp == original.timestamp)
        #expect(decoded.terminalOutcome == nil)
    }

    @Test
    func roundTripPreservesTerminalOutcome() throws {
        let outcome = AgentTerminalOutcome(content: #"{"summary":"shipped"}"#, toolName: "finalize")
        let data = try JSONEncoder().encode(makeCheckpoint(terminalOutcome: outcome))
        let decoded = try JSONDecoder().decode(AgentCheckpoint.self, from: data)
        #expect(decoded.terminalOutcome == outcome)
    }

    @Test
    func nonTerminalCheckpointOmitsTheOutcomeKey() throws {
        let data = try JSONEncoder().encode(makeCheckpoint())
        let encoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(encoded["terminalOutcome"] == nil)
        #expect(encoded["messages"] != nil)
    }

    @Test
    func terminalOutcomeRejectsEmptyToolName() throws {
        let json = #"{"content": "shipped", "toolName": ""}"#
        do {
            _ = try JSONDecoder().decode(AgentTerminalOutcome.self, from: Data(json.utf8))
            Issue.record("Expected DecodingError")
        } catch is DecodingError {
        } catch {
            Issue.record("Expected DecodingError, got \(error)")
        }
    }

    @Test
    func encodingSortsBindingsForDeterminism() throws {
        let bindings: Set<MCPToolBinding> = [
            MCPToolBinding(serverName: "z", toolName: "a"),
            MCPToolBinding(serverName: "a", toolName: "z"),
            MCPToolBinding(serverName: "a", toolName: "a"),
        ]
        let checkpoint = makeCheckpoint(mcpToolBindings: bindings)
        let data = try JSONEncoder().encode(checkpoint)
        struct Envelope: Decodable {
            let mcpToolBindings: [MCPToolBinding]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        #expect(envelope.mcpToolBindings == [
            MCPToolBinding(serverName: "a", toolName: "a"),
            MCPToolBinding(serverName: "a", toolName: "z"),
            MCPToolBinding(serverName: "z", toolName: "a"),
        ])
    }

    @Test
    func decodeDefaultsOmittedAdditiveFields() throws {
        let json = """
        {
            "messages": [],
            "iteration": 0,
            "tokenUsage": { "input": 0, "output": 0, "reasoning": 0, "cacheRead": 0, "cacheWrite": 0 },
            "sessionID": "00000000-0000-0000-0000-000000000001",
            "runID": "00000000-0000-0000-0000-000000000002",
            "checkpointID": "00000000-0000-0000-0000-000000000003",
            "timestamp": "2024-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentCheckpoint.self, from: Data(json.utf8))
        #expect(decoded.iterationUsage == nil)
        #expect(decoded.tokenUsage.total == 0 && decoded.tokenUsage.coverage == .partial)
        #expect(decoded.tokenUsage.cacheRead == 0 && decoded.tokenUsage.cacheReadCoverage == .partial)
        #expect(decoded.tokenUsage.cacheWrite == 0 && decoded.tokenUsage.cacheWriteCoverage == .partial)
        #expect(decoded.contextBudgetState == nil)
        #expect(decoded.historyWasRewrittenLocally == false)
        #expect(decoded.sessionAllowlist.isEmpty)
        #expect(decoded.mcpToolBindings.isEmpty)
        #expect(decoded.terminalOutcome == nil)
    }

    @Test
    func contextBudgetCheckpointStateRejectsInvalidWindowSize() throws {
        let json = """
        {
            "config": {
                "enablePruneTool": false,
                "enableVisibility": false,
                "visibilityFormat": { "type": "standard" }
            },
            "windowSize": 0,
            "softAdvisoryArmed": true
        }
        """
        do {
            _ = try JSONDecoder().decode(ContextBudgetCheckpointState.self, from: Data(json.utf8))
            Issue.record("Expected DecodingError")
        } catch is DecodingError {
        } catch {
            Issue.record("Expected DecodingError, got \(error)")
        }
    }
}

struct AgentCheckpointAccountingWireTests {
    @Test
    func currentCheckpointEncodingIncludesAccounting() throws {
        let checkpoint = try AgentCheckpoint(
            messages: [.user("Hi")], iteration: 1,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 7, output: 3, cacheRead: 0), nil),
            sessionID: SessionID(rawValue: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))),
            runID: RunID(rawValue: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))),
            checkpointID: CheckpointID(rawValue: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))),
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let expected = [
            #"{"checkpointID":"00000000-0000-0000-0000-000000000003","iteration":1,"#,
            #""messages":[{"content":"Hi","role":"user"}],"#,
            #""runID":"00000000-0000-0000-0000-000000000002","#,
            #""sessionID":"00000000-0000-0000-0000-000000000001","timestamp":"1970-01-01T00:00:00Z","#,
            #""tokenUsage":{"accounting":{"cacheRead":"partial","cacheWrite":"unavailable","#,
            #""type":"observed","usage":"partial"},"cacheRead":0,"input":7,"output":3,"reasoning":0}}"#,
        ].joined()
        #expect(try encoder.encode(checkpoint) == Data(expected.utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentCheckpoint.self, from: Data(expected.utf8))
        #expect(decoded.tokenUsage.input == 7 && decoded.tokenUsage.output == 3)
        #expect(decoded.tokenUsage.coverage == .partial)
        #expect(decoded.tokenUsage.cacheRead == 0 && decoded.tokenUsage.cacheReadCoverage == .partial)
        #expect(decoded.tokenUsage.cacheWriteCoverage == .unavailable)
    }

    @Test(arguments: ["null", #"{"type":"unknown"}"#])
    func presentCorruptAccountingCannotDecodeAsLegacy(accounting: String) throws {
        let json = #"""
        {"messages":[],"iteration":1,
         "tokenUsage":{"input":0,"output":0,"reasoning":0,"accounting":\#(accounting)},
         "sessionID":"00000000-0000-0000-0000-000000000001",
         "runID":"00000000-0000-0000-0000-000000000002",
         "checkpointID":"00000000-0000-0000-0000-000000000003","timestamp":0}
        """#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentCheckpoint.self, from: Data(json.utf8))
        }
    }
}
