@testable import AgentRunKit
import Foundation

actor CountingApprovalHandler {
    private var decisions: [String: ToolApprovalDecision]
    private let defaultDecision: ToolApprovalDecision

    private(set) var requestCount = 0
    private(set) var requests: [ToolApprovalRequest] = []

    init(decisions: [String: ToolApprovalDecision] = [:], defaultDecision: ToolApprovalDecision = .approve) {
        self.decisions = decisions
        self.defaultDecision = defaultDecision
    }

    func handle(_ request: ToolApprovalRequest) -> ToolApprovalDecision {
        requests.append(request)
        requestCount += 1
        return decisions[request.toolName] ?? defaultDecision
    }

    nonisolated var handler: ToolApprovalHandler {
        { request in
            await self.handle(request)
        }
    }
}

actor BlockingApprovalHandler {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    private var requestedContinuation: CheckedContinuation<Void, Never>?
    private var wasRequested = false

    private(set) var requestCount = 0
    private(set) var requests: [ToolApprovalRequest] = []

    func handle(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        requests.append(request)
        requestCount += 1

        wasRequested = true
        requestedContinuation?.resume()
        requestedContinuation = nil

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        return .approve
    }

    func awaitRequested() async {
        guard !wasRequested else { return }
        precondition(requestedContinuation == nil, "awaitRequested supports a single waiter")
        await withCheckedContinuation { continuation in
            requestedContinuation = continuation
        }
    }

    func resume() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    nonisolated var handler: ToolApprovalHandler {
        { request in
            await self.handle(request)
        }
    }
}
