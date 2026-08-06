@testable import AgentRunKit

actor GatedCheckpointer: AgentCheckpointer {
    enum GatedOperation {
        case save
        case load
    }

    private let gating: GatedOperation
    private let loadResult: AgentCheckpoint?
    private let onGateEntered: (@Sendable () async -> Void)?

    private var gateEntered = false
    private var gateEnteredContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    private(set) var saved: [AgentCheckpoint] = []

    init(
        gating: GatedOperation,
        loadResult: AgentCheckpoint? = nil,
        onGateEntered: (@Sendable () async -> Void)? = nil
    ) {
        self.gating = gating
        self.loadResult = loadResult
        self.onGateEntered = onGateEntered
    }

    func save(_ checkpoint: AgentCheckpoint) async throws {
        saved.append(checkpoint)
        guard case .save = gating else { return }
        await enterGate()
    }

    func load(_: CheckpointID) async throws -> AgentCheckpoint {
        guard let loadResult else {
            preconditionFailure("GatedCheckpointer.load requires a configured loadResult")
        }
        if case .load = gating {
            await enterGate()
        }
        return loadResult
    }

    func list(session _: SessionID) async throws -> [CheckpointID] {
        var ids = saved.map(\.id)
        if let loadResult {
            ids.append(loadResult.id)
        }
        return ids
    }

    func awaitGateEntered() async {
        guard !gateEntered else { return }
        precondition(gateEnteredContinuation == nil, "awaitGateEntered supports a single waiter")
        await withCheckedContinuation { continuation in
            gateEnteredContinuation = continuation
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func enterGate() async {
        await onGateEntered?()
        gateEntered = true
        gateEnteredContinuation?.resume()
        gateEnteredContinuation = nil

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }
}
