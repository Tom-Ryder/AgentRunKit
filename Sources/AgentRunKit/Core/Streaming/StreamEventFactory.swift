import Foundation

struct StreamEventFactory {
    let sessionID: SessionID?
    let runID: RunID?
    let origin: EventOrigin

    func make(_ kind: StreamEvent.Kind) -> StreamEvent {
        StreamEvent(
            sessionID: sessionID,
            runID: runID,
            origin: origin,
            kind: kind
        )
    }
}

struct StreamEmitter {
    let factory: StreamEventFactory
    let continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation

    func yield(_ kind: StreamEvent.Kind) {
        continuation.yield(factory.make(kind))
    }
}
