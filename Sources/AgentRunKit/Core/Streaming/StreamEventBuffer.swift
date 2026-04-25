import Foundation

/// Errors thrown when replaying from a `StreamEventBuffer` cursor.
public enum BufferReplayError: Error, Sendable, Equatable {
    case bufferDisabled
    case cursorInFuture(currentCursor: UInt64)
    case cursorTrimmed(oldestAvailable: UInt64)
}

/// In-process ring buffer of stream events with monotonic cursors and bounded retention.
public actor StreamEventBuffer {
    public let capacity: Int

    private struct Entry {
        let cursor: UInt64
        let event: StreamEvent
    }

    private var ring: [Entry?]
    private var head: Int = 0
    private var count: Int = 0
    private var nextCursor: UInt64 = 0

    public init(capacity: Int = 1024) {
        precondition(capacity >= 1, "StreamEventBuffer capacity must be at least 1")
        self.capacity = capacity
        ring = Array(repeating: nil, count: capacity)
    }

    @discardableResult
    public func record(_ event: StreamEvent) -> UInt64 {
        let cursor = nextCursor
        let writeIndex = (head + count) % capacity
        ring[writeIndex] = Entry(cursor: cursor, event: event)
        if count < capacity {
            count += 1
        } else {
            head = (head + 1) % capacity
        }
        nextCursor &+= 1
        return cursor
    }

    public func clear() {
        for index in ring.indices {
            ring[index] = nil
        }
        head = 0
        count = 0
        nextCursor = 0
    }

    public var cursor: UInt64 {
        nextCursor
    }

    public func replay(from cursor: UInt64) -> AsyncThrowingStream<StreamEvent, Error> {
        if cursor > nextCursor {
            let currentNext = nextCursor
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: BufferReplayError.cursorInFuture(currentCursor: currentNext))
            }
        }
        let snapshot = collectOrderedSlice()
        return AsyncThrowingStream { continuation in
            if let oldest = snapshot.first?.cursor, cursor < oldest {
                continuation.finish(throwing: BufferReplayError.cursorTrimmed(oldestAvailable: oldest))
                return
            }
            for entry in snapshot where entry.cursor >= cursor {
                continuation.yield(entry.event)
            }
            continuation.finish()
        }
    }

    private func collectOrderedSlice() -> [Entry] {
        var ordered: [Entry] = []
        ordered.reserveCapacity(count)
        for offset in 0 ..< count {
            guard let entry = ring[(head + offset) % capacity] else {
                preconditionFailure("StreamEventBuffer ring invariant: slot at offset \(offset) is unwritten")
            }
            ordered.append(entry)
        }
        return ordered
    }
}
