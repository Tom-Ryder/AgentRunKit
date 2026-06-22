import Foundation
import Synchronization

final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Suspension {
        let id: UInt64
        let deadline: Instant
        let continuation: AsyncThrowingStream<Never, any Error>.Continuation
    }

    private struct State {
        var now: Instant
        var suspensions: [Suspension] = []
        var nextID: UInt64 = 0
    }

    private let state: Mutex<State>

    let minimumResolution: Duration = .zero

    init(now: Instant = Instant(offset: .zero)) {
        state = Mutex(State(now: now))
    }

    var now: Instant {
        state.withLock { $0.now }
    }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            return state.nextID
        }
        let stream: AsyncThrowingStream<Never, any Error>? = state.withLock { state in
            guard deadline > state.now else { return nil }
            return AsyncThrowingStream { continuation in
                state.suspensions.append(Suspension(id: id, deadline: deadline, continuation: continuation))
            }
        }
        guard let stream else { return }
        do {
            for try await _ in stream {}
            try Task.checkCancellation()
        } catch {
            state.withLock { $0.suspensions.removeAll { $0.id == id } }
            throw error
        }
    }

    func advance(by duration: Duration) {
        let target = state.withLock { $0.now.advanced(by: duration) }
        while true {
            let woken: AsyncThrowingStream<Never, any Error>.Continuation? = state.withLock { state in
                guard state.now < target else { return nil }
                state.suspensions.sort { $0.deadline < $1.deadline }
                guard let next = state.suspensions.first, target >= next.deadline else {
                    state.now = target
                    return nil
                }
                state.now = next.deadline
                return state.suspensions.removeFirst().continuation
            }
            guard let woken else { return }
            woken.finish()
        }
    }

    func awaitSuspensions(atLeast count: Int) async {
        while state.withLock({ $0.suspensions.count < count }) {
            await Task.yield()
        }
    }
}
